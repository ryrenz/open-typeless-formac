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

    func preload() {
        // No-op for remote API
    }

    func transcribe(audioURL: URL) async throws -> String {
        let key = Self.apiKey
        guard !key.isEmpty else { throw TranscriptionError.noAPIKey }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL)
        } catch {
            throw TranscriptionError.failed(error)
        }

        let fileName = audioURL.lastPathComponent
        let client = buildClient(apiKey: key)

        let query = AudioTranscriptionQuery(
            file: audioData,
            fileType: fileName.hasSuffix(".m4a") ? .m4a : .wav,
            model: .init(Self.model)
        )

        // Wrap SDK call to catch any unexpected crashes
        let text: String
        do {
            let result = try await client.audioTranscriptions(query: query)
            text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            // SDK may throw various errors (auth, network, decoding)
            let message: String
            if let urlError = error as? URLError {
                message = "Network error: \(urlError.localizedDescription)"
            } else {
                message = "\(error)"
            }
            throw TranscriptionError.failed(
                NSError(domain: "TranscriptionService", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: message])
            )
        }

        guard !text.isEmpty else { throw TranscriptionError.noResult }
        return text
    }

    private func buildClient(apiKey: String) -> OpenAI {
        switch Self.provider {
        case .openAI:
            return OpenAI(apiToken: apiKey)
        case .custom:
            let config = OpenAI.Configuration(
                token: apiKey,
                host: Self.customHost,
                port: 443,
                scheme: "https",
                basePath: Self.customBasePath
            )
            return OpenAI(configuration: config)
        }
    }
}
