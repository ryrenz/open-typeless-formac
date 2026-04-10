import Foundation
import OpenAI

enum TranscriptionError: Error, LocalizedError {
    case noAPIKey
    case noResult
    case failed(Error)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API key not configured"
        case .noResult: return "No transcription result"
        case .failed(let error): return "Transcription failed: \(error.localizedDescription)"
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

final class TranscriptionService {
    static var apiKey = ProcessInfo.processInfo.environment["AI_BUILDER_TOKEN"]
        ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        ?? ""
    static var provider: APIProvider = .openAI
    static var customHost: String = "space.ai-builders.com"
    static var customBasePath: String = "/backend/v1"
    static var model: String = "gpt-4o-mini-transcribe"

    func preload() {
        // No-op for remote API
    }

    func transcribe(audioURL: URL) async throws -> String {
        let key = Self.apiKey
        guard !key.isEmpty else { throw TranscriptionError.noAPIKey }

        let client = buildClient(apiKey: key)
        let audioData = try Data(contentsOf: audioURL)
        let fileName = audioURL.lastPathComponent

        let query = AudioTranscriptionQuery(
            file: audioData,
            fileType: fileName.hasSuffix(".m4a") ? .m4a : .wav,
            model: .init(Self.model)
        )

        do {
            let result = try await client.audioTranscriptions(query: query)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TranscriptionError.noResult }
            return text
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.failed(error)
        }
    }

    private func buildClient(apiKey: String) -> OpenAI {
        switch Self.provider {
        case .openAI:
            return OpenAI(apiToken: apiKey)
        case .custom:
            let config = OpenAI.Configuration(
                token: apiKey,
                host: Self.customHost,
                basePath: Self.customBasePath,
                port: 443,
                scheme: "https"
            )
            return OpenAI(configuration: config)
        }
    }
}
