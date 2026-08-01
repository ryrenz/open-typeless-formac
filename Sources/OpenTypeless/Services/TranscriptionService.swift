import Foundation
import OpenAI

enum TranscriptionError: Error, LocalizedError {
    case noAPIKey
    case credentialStoreFailure(Error)
    case invalidEndpoint
    case dataProcessingConsentRequired
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
        case .credentialStoreFailure(let error):
            return "Unable to read the API key from Keychain: \(error.localizedDescription)"
        case .invalidEndpoint:
            return "The selected transcription endpoint is invalid"
        case .dataProcessingConsentRequired:
            return "Review and accept the data processing disclosure in Settings → API before transcribing"
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

enum APIProvider: String, CaseIterable, Identifiable, Codable {
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

    func format(_ text: String) async throws -> String
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

    func format(_ text: String) async throws -> String {
        try await TranscriptionFormatter.format(text, client: formattingClient)
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

enum AppSetupRequirement: Equatable {
    case apiKeyMissing
    case credentialStoreUnavailable(String)
    case invalidEndpoint
    case dataProcessingConsentRequired

    init?(error: Error) {
        switch error {
        case TranscriptionError.noAPIKey:
            self = .apiKeyMissing
        case TranscriptionError.credentialStoreFailure(let underlying):
            self = .credentialStoreUnavailable(underlying.localizedDescription)
        case TranscriptionError.invalidEndpoint:
            self = .invalidEndpoint
        case TranscriptionError.dataProcessingConsentRequired:
            self = .dataProcessingConsentRequired
        default:
            return nil
        }
    }
}

struct TranscriptionRequestConfiguration {
    let apiKey: String
    let model: String
    let endpoint: DataProcessingEndpoint
    let consentToken: DataProcessingConsentToken?
}

enum TranscriptionConfigurationTransaction {
    private static let lock = NSLock()

    static func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class TranscriptionService {
    private static let promptEchoPrefix = "Prefer these spellings when they match the audio:"
    private static let transcriptionTimeout: TimeInterval = 300
    private static let formattingTimeout: TimeInterval = 30
    private static let previousContextLimit = 800

    private let chunker: any AudioChunking
    private let apiKeyProvider: () throws -> String
    private let modelProvider: () throws -> String
    private let dataProcessingEndpointProvider: () throws -> DataProcessingEndpoint
    private let dataProcessingConsentProvider: ((DataProcessingEndpoint) -> Bool)?
    private let dataProcessingConsentStore: DataProcessingConsentStore?
    private let transportFactory: ((String, DataProcessingEndpoint) -> any TranscriptionTransport)?
    private let retryDelaysNanoseconds: [UInt64]
    private let sleep: (UInt64) async throws -> Void

    static var provider: APIProvider {
        (try? TranscriptionConfigurationStore.shared.loadOrMigrate().provider) ?? .openAI
    }

    static var customHost: String {
        (try? TranscriptionConfigurationStore.shared.loadOrMigrate().customHost)
            ?? "space.ai-builders.com"
    }

    static var customBasePath: String {
        (try? TranscriptionConfigurationStore.shared.loadOrMigrate().customBasePath)
            ?? "/backend/v1"
    }

    static var model: String {
        (try? TranscriptionConfigurationStore.shared.loadOrMigrate().model)
            ?? StoredTranscriptionConfiguration.defaultModel
    }

    convenience init() {
        self.init(
            apiKeyProvider: {
                try TranscriptionConfigurationStore.shared.loadOrMigrate().apiKey ?? ""
            },
            modelProvider: {
                try TranscriptionConfigurationStore.shared.loadOrMigrate().model
            },
            dataProcessingEndpointProvider: {
                try TranscriptionConfigurationStore.shared.loadOrMigrate().endpoint
            }
        )
    }

    init(
        chunker: any AudioChunking = AudioChunker(),
        apiKeyProvider: @escaping () throws -> String,
        modelProvider: @escaping () throws -> String = {
            StoredTranscriptionConfiguration.defaultModel
        },
        dataProcessingEndpointProvider: @escaping () throws -> DataProcessingEndpoint = {
            DataProcessingEndpoint.current(provider: .openAI)
        },
        dataProcessingConsentProvider: ((DataProcessingEndpoint) -> Bool)? = nil,
        dataProcessingConsentStore: DataProcessingConsentStore? = nil,
        transportFactory: ((String, DataProcessingEndpoint) -> any TranscriptionTransport)? = nil,
        retryDelaysNanoseconds: [UInt64] = [800_000_000, 2_000_000_000],
        sleep: @escaping (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.chunker = chunker
        self.apiKeyProvider = apiKeyProvider
        self.modelProvider = modelProvider
        self.dataProcessingEndpointProvider = dataProcessingEndpointProvider
        self.dataProcessingConsentProvider = dataProcessingConsentProvider
        self.dataProcessingConsentStore = dataProcessingConsentProvider == nil
            ? (dataProcessingConsentStore ?? .shared)
            : nil
        self.transportFactory = transportFactory
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.sleep = sleep
    }

    func preload() {
        // No-op for remote API
    }

    func prepareRequestConfiguration() throws -> TranscriptionRequestConfiguration {
        try TranscriptionConfigurationTransaction.perform {
            let key: String
            do {
                key = try apiKeyProvider()
            } catch {
                throw TranscriptionError.credentialStoreFailure(error)
            }
            guard !key.isEmpty else { throw TranscriptionError.noAPIKey }

            let endpoint: DataProcessingEndpoint
            let model: String
            do {
                endpoint = try dataProcessingEndpointProvider()
                model = try modelProvider()
            } catch {
                throw TranscriptionError.credentialStoreFailure(error)
            }
            guard endpoint.isValid else {
                throw TranscriptionError.invalidEndpoint
            }
            let consentToken: DataProcessingConsentToken?
            if let dataProcessingConsentStore {
                guard let token = dataProcessingConsentStore.consentToken(for: endpoint) else {
                    throw TranscriptionError.dataProcessingConsentRequired
                }
                consentToken = token
            } else {
                guard dataProcessingConsentProvider?(endpoint) == true else {
                    throw TranscriptionError.dataProcessingConsentRequired
                }
                consentToken = nil
            }
            return TranscriptionRequestConfiguration(
                apiKey: key,
                model: model,
                endpoint: endpoint,
                consentToken: consentToken
            )
        }
    }

    func validatePreparedConfiguration(
        _ configuration: TranscriptionRequestConfiguration
    ) throws {
        try validateConsent(for: configuration)
    }

    func transcribe(
        audioURL: URL,
        prompt: String? = nil,
        silenceRanges: [AudioSilenceRange] = [],
        configuration preparedConfiguration: TranscriptionRequestConfiguration? = nil,
        onProgress: (@MainActor (Int, Int) -> Void)? = nil
    ) async throws -> String {
        let configuration = try preparedConfiguration ?? prepareRequestConfiguration()
        try validateConsent(for: configuration)

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

        let transport = transportFactory?(configuration.apiKey, configuration.endpoint)
            ?? buildTransport(
                apiKey: configuration.apiKey,
                endpoint: configuration.endpoint
            )
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
                    model: configuration.model,
                    prompt: segmentPrompt,
                    transport: transport,
                    configuration: configuration
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
                do {
                    let formatted = try await performAuthorizedRequest(
                        configuration: configuration
                    ) {
                        try await transport.format(deduplicated)
                    }
                    formattedSegments.append(formatted)
                } catch {
                    formattedSegments.append(deduplicated)
                    throw error
                }
            } catch {
                if error is CancellationError {
                    throw error
                }
                if case TranscriptionError.dataProcessingConsentRequired = error,
                   formattedSegments.isEmpty {
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
        model: String,
        prompt: String?,
        transport: any TranscriptionTransport,
        configuration: TranscriptionRequestConfiguration
    ) async throws -> String {
        var lastError: Error?

        for attempt in 0...retryDelaysNanoseconds.count {
            try Task.checkCancellation()
            do {
                return try await performAuthorizedRequest(
                    configuration: configuration
                ) {
                    try await transport.transcribe(
                        audioData: audioData,
                        audioFormat: audioFormat,
                        model: model,
                        prompt: prompt
                    )
                }
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

    private func validateConsent(
        for configuration: TranscriptionRequestConfiguration
    ) throws {
        if let dataProcessingConsentStore {
            guard let token = configuration.consentToken,
                  dataProcessingConsentStore.isConsentValid(
                    token,
                    for: configuration.endpoint
                  )
            else {
                throw TranscriptionError.dataProcessingConsentRequired
            }
            return
        }
        guard dataProcessingConsentProvider?(configuration.endpoint) == true else {
            throw TranscriptionError.dataProcessingConsentRequired
        }
    }

    private func performAuthorizedRequest<T>(
        configuration: TranscriptionRequestConfiguration,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        if let dataProcessingConsentStore {
            guard let token = configuration.consentToken else {
                throw TranscriptionError.dataProcessingConsentRequired
            }
            do {
                return try await dataProcessingConsentStore.performAuthorizedRequest(
                    token: token,
                    endpoint: configuration.endpoint,
                    operation: operation
                )
            } catch DataProcessingConsentAuthorizationError.revoked {
                throw TranscriptionError.dataProcessingConsentRequired
            }
        }
        try validateConsent(for: configuration)
        return try await operation()
    }

    private func buildTransport(
        apiKey: String,
        endpoint: DataProcessingEndpoint
    ) -> any TranscriptionTransport {
        OpenAITranscriptionTransport(
            transcriptionClient: buildClient(
                apiKey: apiKey,
                endpoint: endpoint,
                timeoutInterval: Self.transcriptionTimeout
            ),
            formattingClient: buildClient(
                apiKey: apiKey,
                endpoint: endpoint,
                timeoutInterval: Self.formattingTimeout
            )
        )
    }

    private func buildClient(
        apiKey: String,
        endpoint: DataProcessingEndpoint,
        timeoutInterval: TimeInterval
    ) -> OpenAI {
        let config: OpenAI.Configuration
        switch endpoint.provider {
        case .openAI:
            config = OpenAI.Configuration(
                token: apiKey,
                timeoutInterval: timeoutInterval
            )
        case .custom:
            config = OpenAI.Configuration(
                token: apiKey,
                host: endpoint.host,
                port: 443,
                scheme: "https",
                basePath: endpoint.basePath,
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
