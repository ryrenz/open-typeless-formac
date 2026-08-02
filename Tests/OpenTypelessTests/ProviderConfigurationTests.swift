import XCTest
@testable import OpenTypeless

final class ProviderConfigurationTests: XCTestCase {
    func testGroqPresetUsesOpenAICompatibleTranscriptionEndpoint() {
        let preset = APIProvider.groq.providerPreset
        let endpoint = DataProcessingEndpoint.current(provider: .groq)

        XCTAssertEqual(preset.displayName, "Groq")
        XCTAssertEqual(preset.defaultHost, "api.groq.com")
        XCTAssertEqual(preset.defaultBasePath, "/openai/v1")
        XCTAssertEqual(preset.defaultModel, "whisper-large-v3-turbo")
        XCTAssertEqual(preset.formattingModel, "openai/gpt-oss-20b")
        XCTAssertEqual(
            preset.formattingTokenLimitPolicy,
            .maxCompletionTokens
        )
        XCTAssertEqual(
            preset.transcriptionPromptPolicy,
            .limited(maxCharacters: 200)
        )
        XCTAssertEqual(endpoint.displayAddress, "https://api.groq.com/openai/v1")
        XCTAssertTrue(endpoint.isValid)
    }

    func testMistralPresetUsesVoxtralTranscriptionEndpoint() {
        let preset = APIProvider.mistral.providerPreset
        let endpoint = DataProcessingEndpoint.current(provider: .mistral)

        XCTAssertEqual(preset.displayName, "Mistral")
        XCTAssertEqual(preset.defaultHost, "api.mistral.ai")
        XCTAssertEqual(preset.defaultBasePath, "/v1")
        XCTAssertEqual(preset.defaultModel, "voxtral-mini-latest")
        XCTAssertEqual(preset.formattingModel, "mistral-small-latest")
        XCTAssertEqual(preset.formattingTokenLimitPolicy, .maxTokens)
        XCTAssertEqual(preset.transcriptionPromptPolicy, .unsupported)
        XCTAssertEqual(endpoint.displayAddress, "https://api.mistral.ai/v1")
        XCTAssertTrue(endpoint.isValid)
    }

    func testCustomPresetKeepsEditableEndpointAndModel() {
        let preset = APIProvider.custom.providerPreset

        XCTAssertTrue(preset.allowsCustomEndpoint)
        XCTAssertTrue(preset.allowsCustomModel)
        XCTAssertEqual(
            preset.defaultModel,
            StoredTranscriptionConfiguration.defaultModel
        )
        XCTAssertEqual(
            preset.normalizedModel(" custom-transcribe "),
            "custom-transcribe"
        )

        let endpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: " HTTPS://Example.COM/ ",
            customBasePath: "backend/v1/"
        )
        XCTAssertEqual(endpoint.displayAddress, "https://example.com/backend/v1")
        XCTAssertTrue(endpoint.isValid)
    }

    func testOpenAIPresetRetainsExistingModelAndFormatterDefaults() {
        let preset = APIProvider.openAI.providerPreset

        XCTAssertEqual(preset.defaultModel, "gpt-4o-mini-transcribe")
        XCTAssertEqual(
            preset.formattingModel,
            StoredTranscriptionConfiguration.defaultFormattingModel
        )
        XCTAssertEqual(
            DataProcessingEndpoint.current(provider: .openAI).displayAddress,
            "https://api.openai.com/v1"
        )
        XCTAssertEqual(
            preset.normalizedModel("whisper-1"),
            "whisper-1"
        )
        XCTAssertEqual(
            preset.normalizedModel("unknown-model"),
            preset.defaultModel
        )
    }
}
