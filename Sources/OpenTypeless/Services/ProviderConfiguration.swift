import Foundation

struct APIModelOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum TranscriptionPromptPolicy: Equatable {
    case unsupported
    case limited(maxCharacters: Int)
    case standard

    func applying(to prompt: String?) -> String? {
        guard let prompt else { return nil }
        switch self {
        case .unsupported:
            return nil
        case let .limited(maxCharacters):
            return String(prompt.prefix(maxCharacters))
        case .standard:
            return prompt
        }
    }
}

enum FormattingTokenLimitPolicy: Equatable {
    case maxCompletionTokens
    case maxTokens
}

struct APIProviderPreset: Equatable {
    let displayName: String
    let defaultHost: String
    let defaultBasePath: String
    let modelOptions: [APIModelOption]
    let defaultModel: String
    let formattingModel: String?
    let transcriptionPromptPolicy: TranscriptionPromptPolicy
    let formattingTokenLimitPolicy: FormattingTokenLimitPolicy
    let allowsCustomEndpoint: Bool

    var allowsCustomModel: Bool {
        modelOptions.isEmpty
    }

    func normalizedModel(_ model: String) -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if allowsCustomModel {
            return trimmedModel.isEmpty ? defaultModel : trimmedModel
        }
        return modelOptions.contains(where: { $0.id == trimmedModel })
            ? trimmedModel
            : defaultModel
    }
}

extension APIProvider {
    var providerPreset: APIProviderPreset {
        switch self {
        case .openAI:
            return APIProviderPreset(
                displayName: "OpenAI",
                defaultHost: "api.openai.com",
                defaultBasePath: "/v1",
                modelOptions: [
                    APIModelOption(
                        id: "gpt-4o-mini-transcribe",
                        displayName: "gpt-4o-mini-transcribe ($0.003/min)"
                    ),
                    APIModelOption(
                        id: "gpt-4o-transcribe",
                        displayName: "gpt-4o-transcribe ($0.006/min)"
                    ),
                    APIModelOption(
                        id: "whisper-1",
                        displayName: "whisper-1 ($0.006/min)"
                    ),
                ],
                defaultModel: "gpt-4o-mini-transcribe",
                formattingModel: StoredTranscriptionConfiguration.defaultFormattingModel,
                transcriptionPromptPolicy: .standard,
                formattingTokenLimitPolicy: .maxCompletionTokens,
                allowsCustomEndpoint: false
            )
        case .groq:
            return APIProviderPreset(
                displayName: "Groq",
                defaultHost: "api.groq.com",
                defaultBasePath: "/openai/v1",
                modelOptions: [
                    APIModelOption(
                        id: "whisper-large-v3",
                        displayName: "whisper-large-v3 (~$0.0019/min; recommended)"
                    ),
                    APIModelOption(
                        id: "whisper-large-v3-turbo",
                        displayName: "whisper-large-v3-turbo (~$0.0007/min; faster)"
                    ),
                ],
                defaultModel: "whisper-large-v3",
                formattingModel: "openai/gpt-oss-20b",
                transcriptionPromptPolicy: .limited(maxCharacters: 200),
                formattingTokenLimitPolicy: .maxCompletionTokens,
                allowsCustomEndpoint: false
            )
        case .mistral:
            return APIProviderPreset(
                displayName: "Mistral",
                defaultHost: "api.mistral.ai",
                defaultBasePath: "/v1",
                modelOptions: [
                    APIModelOption(
                        id: "voxtral-mini-latest",
                        displayName: "voxtral-mini-latest ($0.003/min)"
                    ),
                ],
                defaultModel: "voxtral-mini-latest",
                formattingModel: "mistral-small-latest",
                transcriptionPromptPolicy: .unsupported,
                formattingTokenLimitPolicy: .maxTokens,
                allowsCustomEndpoint: false
            )
        case .custom:
            return APIProviderPreset(
                displayName: "Custom (OpenAI-compatible)",
                defaultHost: StoredTranscriptionConfiguration.defaultCustomHost,
                defaultBasePath: StoredTranscriptionConfiguration.defaultCustomBasePath,
                modelOptions: [],
                defaultModel: StoredTranscriptionConfiguration.defaultModel,
                formattingModel: StoredTranscriptionConfiguration.defaultFormattingModel,
                transcriptionPromptPolicy: .standard,
                formattingTokenLimitPolicy: .maxCompletionTokens,
                allowsCustomEndpoint: true
            )
        }
    }
}
