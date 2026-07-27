import Foundation
import OpenAI

enum TranscriptionError: Error, LocalizedError {
    case noAPIKey
    case noResult
    case partialResult(
        text: String,
        completedSegments: Int,
        totalSegments: Int,
        underlying: Error
    )
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "API key not configured"
        case .noResult:
            return "No transcription result"
        case .partialResult(_, let completed, let total, let underlying):
            return "Transcription completed \(completed) of \(total) segments: \(underlying.localizedDescription)"
        case .failed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        }
    }
}

enum TranscriptionSegmentError: Error, LocalizedError {
    case invalidResult(segment: Int)

    var errorDescription: String? {
        switch self {
        case .invalidResult(let segment):
            return "Segment \(segment) returned no usable transcription"
        }
    }
}

enum APIProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }
}

enum TranscriptionAudioFormat {
    case m4a
    case wav
}

protocol TranscriptionTransport {
    func transcribe(
        audioData: Data,
        audioFormat: TranscriptionAudioFormat,
        model: String,
        prompt: String?
    ) async throws -> String

    func format(_ text: String) async -> String
}

final class OpenAITranscriptionTransport: TranscriptionTransport {
    private let transcriptionClient: OpenAI
    private let formattingClient: OpenAI

    init(transcriptionClient: OpenAI, formattingClient: OpenAI) {
        self.transcriptionClient = transcriptionClient
        self.formattingClient = formattingClient
    }

    func transcribe(
        audioData: Data,
        audioFormat: TranscriptionAudioFormat,
        model: String,
        prompt: String?
    ) async throws -> String {
        let query = AudioTranscriptionQuery(
            file: audioData,
            fileType: Self.fileType(for: audioFormat),
            model: .init(model),
            prompt: prompt
        )
        let result = try await transcriptionClient.audioTranscriptions(query: query)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func format(_ text: String) async -> String {
        await TranscriptionFormatter.format(text, client: formattingClient)
    }

    private static func fileType(
        for audioFormat: TranscriptionAudioFormat
    ) -> AudioTranscriptionQuery.FileType {
        switch audioFormat {
        case .m4a:
            return .m4a
        case .wav:
            return .wav
        }
    }
}

enum TranscriptionFailureClassifier {
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }

        if case OpenAIError.statusError(_, let statusCode) = error {
            return statusCode == 408 || statusCode == 429 || statusCode >= 500
        }

        if let response = error as? APIErrorResponse {
            let code = response.error.code?.lowercased() ?? ""
            let type = response.error.type.lowercased()
            if code.contains("rate_limit")
                || type.contains("rate_limit")
                || type.contains("server_error") {
                return true
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("timed out")
            || message.contains("timeout")
            || message.contains("rate limit")
            || message.contains("too many requests")
            || message.contains("temporarily unavailable")
    }

    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .dnsLookupFailed,
        .notConnectedToInternet,
        .resourceUnavailable,
        .dataNotAllowed,
        .secureConnectionFailed,
    ]
}

final class TranscriptionService {
    private static let promptEchoPrefix = "Prefer these spellings when they match the audio:"
    private static let transcriptionTimeout: TimeInterval = 300
    private static let formattingTimeout: TimeInterval = 30
    private static let previousContextLimit = 800

    private let chunker: any AudioChunking
    private let apiKeyProvider: () -> String
    private let transportFactory: ((String) -> any TranscriptionTransport)?
    private let retryDelaysNanoseconds: [UInt64]
    private let sleep: (UInt64) async throws -> Void

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: "apiKey")
            ?? ProcessInfo.processInfo.environment["AI_BUILDER_TOKEN"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "apiKey") }
    }

    static var provider: APIProvider {
        get {
            let raw = UserDefaults.standard.string(forKey: "apiProvider") ?? "openai"
            return APIProvider(rawValue: raw) ?? .openAI
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "apiProvider") }
    }

    static var customHost: String {
        get { UserDefaults.standard.string(forKey: "customHost") ?? "space.ai-builders.com" }
        set { UserDefaults.standard.set(newValue, forKey: "customHost") }
    }

    static var customBasePath: String {
        get { UserDefaults.standard.string(forKey: "customBasePath") ?? "/backend/v1" }
        set { UserDefaults.standard.set(newValue, forKey: "customBasePath") }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: "transcriptionModel") ?? "gpt-4o-mini-transcribe" }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptionModel") }
    }

    init(
        chunker: any AudioChunking = AudioChunker(),
        apiKeyProvider: @escaping () -> String = { TranscriptionService.apiKey },
        transportFactory: ((String) -> any TranscriptionTransport)? = nil,
        retryDelaysNanoseconds: [UInt64] = [800_000_000, 2_000_000_000],
        sleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.chunker = chunker
        self.apiKeyProvider = apiKeyProvider
        self.transportFactory = transportFactory
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.sleep = sleep
    }

    func preload() {
        // No-op for remote API
    }

    func transcribe(
        audioURL: URL,
        prompt: String? = nil,
        silenceRanges: [AudioSilenceRange] = [],
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> String {
        let key = apiKeyProvider()
        guard !key.isEmpty else { throw TranscriptionError.noAPIKey }

        let batch: AudioChunkBatch
        do {
            batch = try await chunker.makeChunks(
                for: audioURL,
                silenceRanges: silenceRanges
            )
        } catch {
            throw TranscriptionError.failed(error)
        }
        defer { batch.cleanUp() }

        let transport = transportFactory?(key) ?? buildTransport(apiKey: key)
        var rawTranscript = ""
        var previousChunkRawText: String?
        var formattedSegments: [String] = []
        var completedSegmentCount = 0
        var firstInvalidSegmentError: Error?

        for (index, chunk) in batch.chunks.enumerated() {
            await onProgress?(index + 1, batch.chunks.count)
            let segmentPrompt = Self.makeSegmentPrompt(
                basePrompt: prompt,
                previousTranscript: rawTranscript
            )

            do {
                let audioData = try Data(contentsOf: chunk.url)
                let rawText = try await transcribeWithRetry(
                    audioData: audioData,
                    audioFormat: Self.audioFormat(for: chunk.url),
                    prompt: segmentPrompt,
                    transport: transport
                )
                let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

                if trimmed.isEmpty || Self.looksLikePromptEcho(trimmed, prompt: segmentPrompt) {
                    previousChunkRawText = nil
                    if firstInvalidSegmentError == nil {
                        firstInvalidSegmentError = TranscriptionSegmentError.invalidResult(
                            segment: index + 1
                        )
                    }
                    continue
                }

                let deduplicated = chunk.overlapsPrevious && previousChunkRawText != nil
                    ? TranscriptionTextMerger.removingOverlap(
                        previous: previousChunkRawText ?? "",
                        next: trimmed
                    )
                    : trimmed
                previousChunkRawText = trimmed
                completedSegmentCount += 1
                guard !deduplicated.isEmpty else { continue }

                rawTranscript = rawTranscript.isEmpty
                    ? deduplicated
                    : "\(rawTranscript) \(deduplicated)"
                formattedSegments.append(await transport.format(deduplicated))
            } catch {
                if error is CancellationError {
                    throw error
                }
                if !formattedSegments.isEmpty {
                    throw TranscriptionError.partialResult(
                        text: formattedSegments.joined(separator: "\n\n"),
                        completedSegments: completedSegmentCount,
                        totalSegments: batch.chunks.count,
                        underlying: error
                    )
                }
                throw TranscriptionError.failed(error)
            }
        }

        guard !formattedSegments.isEmpty else {
            throw TranscriptionError.noResult
        }
        if let firstInvalidSegmentError {
            throw TranscriptionError.partialResult(
                text: formattedSegments.joined(separator: "\n\n"),
                completedSegments: completedSegmentCount,
                totalSegments: batch.chunks.count,
                underlying: firstInvalidSegmentError
            )
        }
        return formattedSegments.joined(separator: "\n\n")
    }

    static func looksLikePromptEcho(_ text: String, prompt: String?) -> Bool {
        let normalizedText = normalizeForPromptEchoCheck(text)
        guard !normalizedText.isEmpty else { return false }

        guard let prompt else { return false }
        let normalizedPrompt = normalizeForPromptEchoCheck(prompt)
        guard !normalizedPrompt.isEmpty else { return false }

        if normalizedText == normalizedPrompt {
            return true
        }

        return normalizedText.hasPrefix(normalizeForPromptEchoCheck(promptEchoPrefix))
    }

    static func makeSegmentPrompt(
        basePrompt: String?,
        previousTranscript: String
    ) -> String? {
        let base = basePrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = previousTranscript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .suffix(previousContextLimit)

        if previous.isEmpty {
            return base.isEmpty ? nil : base
        }

        let context = "Continue from this preceding transcript context: \(previous)"
        return base.isEmpty ? context : "\(base)\n\(context)"
    }

    private func transcribeWithRetry(
        audioData: Data,
        audioFormat: TranscriptionAudioFormat,
        prompt: String?,
        transport: any TranscriptionTransport
    ) async throws -> String {
        var lastError: Error?

        for attempt in 0...retryDelaysNanoseconds.count {
            try Task.checkCancellation()
            do {
                return try await transport.transcribe(
                    audioData: audioData,
                    audioFormat: audioFormat,
                    model: Self.model,
                    prompt: prompt
                )
            } catch {
                lastError = error
                guard attempt < retryDelaysNanoseconds.count,
                      TranscriptionFailureClassifier.isTransient(error)
                else {
                    throw error
                }
                try await sleep(retryDelaysNanoseconds[attempt])
            }
        }

        throw lastError ?? TranscriptionError.noResult
    }

    private func buildTransport(apiKey: String) -> any TranscriptionTransport {
        OpenAITranscriptionTransport(
            transcriptionClient: buildClient(
                apiKey: apiKey,
                timeoutInterval: Self.transcriptionTimeout
            ),
            formattingClient: buildClient(
                apiKey: apiKey,
                timeoutInterval: Self.formattingTimeout
            )
        )
    }

    private func buildClient(apiKey: String, timeoutInterval: TimeInterval) -> OpenAI {
        let config: OpenAI.Configuration
        switch Self.provider {
        case .openAI:
            config = OpenAI.Configuration(
                token: apiKey,
                timeoutInterval: timeoutInterval
            )
        case .custom:
            config = OpenAI.Configuration(
                token: apiKey,
                host: Self.customHost,
                port: 443,
                scheme: "https",
                basePath: Self.customBasePath,
                timeoutInterval: timeoutInterval
            )
        }
        return OpenAI(configuration: config)
    }

    private static func audioFormat(for url: URL) -> TranscriptionAudioFormat {
        url.pathExtension.lowercased() == "m4a" ? .m4a : .wav
    }

    private static func normalizeForPromptEchoCheck(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r.,;:!?"))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
