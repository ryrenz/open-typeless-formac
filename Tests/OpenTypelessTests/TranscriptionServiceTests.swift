import Foundation
import XCTest
@testable import OpenTypeless

final class TranscriptionServiceTests: XCTestCase {
    func testAudioTranscriptionCompatibilityMiddlewareRemovesDefaultFalseStream() throws {
        let boundary = "test-boundary"
        let body = Data(
            (
                "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
                    + "whisper-large-v3-turbo\r\n"
                    + "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"stream\"\r\n\r\n"
                    + "false\r\n"
                    + "--\(boundary)--\r\n"
            ).utf8
        )
        var request = URLRequest(
            url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("999", forHTTPHeaderField: "Content-Length")
        request.httpBody = body

        let compatibleRequest = AudioTranscriptionCompatibilityMiddleware()
            .intercept(request: request)

        let compatibleBody = try XCTUnwrap(compatibleRequest.httpBody)
        let compatibleBodyText = try XCTUnwrap(
            String(data: compatibleBody, encoding: .utf8)
        )
        XCTAssertTrue(compatibleBodyText.contains("name=\"model\""))
        XCTAssertFalse(compatibleBodyText.contains("name=\"stream\""))
        XCTAssertNil(compatibleRequest.value(forHTTPHeaderField: "Content-Length"))
    }

    func testAudioTranscriptionCompatibilityMiddlewarePreservesStreamingRequests() throws {
        let boundary = "test-boundary"
        let body = Data(
            (
                "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"stream\"\r\n\r\n"
                    + "true\r\n"
                    + "--\(boundary)--\r\n"
            ).utf8
        )
        var request = URLRequest(
            url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let compatibleRequest = AudioTranscriptionCompatibilityMiddleware()
            .intercept(request: request)

        XCTAssertEqual(compatibleRequest.httpBody, body)
    }

    func testAudioTranscriptionCompatibilityMiddlewareIgnoresNonAudioRequests() throws {
        let boundary = "test-boundary"
        let body = Data(
            (
                "--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"stream\"\r\n\r\n"
                    + "false\r\n"
                    + "--\(boundary)--\r\n"
            ).utf8
        )
        var request = URLRequest(
            url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body

        let compatibleRequest = AudioTranscriptionCompatibilityMiddleware()
            .intercept(request: request)

        XCTAssertEqual(compatibleRequest.httpBody, body)
    }

    func testLooksLikePromptEchoMatchesExactPrompt() {
        let prompt = "Prefer these spellings when they match the audio: Claude Code, ClaudeCode, skill, 读取."

        XCTAssertTrue(TranscriptionService.looksLikePromptEcho(prompt, prompt: prompt))
    }

    func testLooksLikePromptEchoMatchesPrefixEcho() {
        let prompt = "Prefer these spellings when they match the audio: Claude Code, Cursor."
        let echoed = "Prefer these spellings when they match the audio: Claude Code, Cursor"

        XCTAssertTrue(TranscriptionService.looksLikePromptEcho(echoed, prompt: prompt))
    }

    func testLooksLikePromptEchoIgnoresNormalTranscript() {
        let prompt = "Prefer these spellings when they match the audio: Claude Code, Cursor."

        XCTAssertFalse(
            TranscriptionService.looksLikePromptEcho("Claude Code fixed the issue", prompt: prompt)
        )
    }

    func testTranscribeWithoutAPIKeyThrows() async {
        let service = TranscriptionService(apiKeyProvider: { "" })
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("fake.m4a")
        FileManager.default.createFile(atPath: fakeURL.path, contents: Data(), attributes: nil)
        defer { try? FileManager.default.removeItem(at: fakeURL) }

        do {
            _ = try await service.transcribe(audioURL: fakeURL)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }

    func testDefaultModel() {
        XCTAssertEqual(
            StoredTranscriptionConfiguration.defaultModel,
            "gpt-4o-mini-transcribe"
        )
    }

    func testTranscribeWithoutDataProcessingConsentThrowsBeforeReadingAudio() async {
        let service = TranscriptionService(
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in false }
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        do {
            _ = try await service.transcribe(audioURL: missingURL)
            XCTFail("Should have thrown")
        } catch TranscriptionError.dataProcessingConsentRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCredentialStoreFailureIsNotReportedAsMissingKey() async {
        let service = TranscriptionService(
            apiKeyProvider: { throw CredentialTestError.unavailable }
        )
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).m4a")

        do {
            _ = try await service.transcribe(audioURL: missingURL)
            XCTFail("Should have thrown")
        } catch TranscriptionError.credentialStoreFailure(let underlying) {
            XCTAssertTrue(underlying is CredentialTestError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPrepareRequestConfigurationRejectsInvalidEndpoint() {
        let service = TranscriptionService(
            apiKeyProvider: { "test-key" },
            dataProcessingEndpointProvider: {
                DataProcessingEndpoint.current(
                    provider: .custom,
                    customHost: "example.com/path",
                    customBasePath: "/v1"
                )
            },
            dataProcessingConsentProvider: { _ in true }
        )

        XCTAssertThrowsError(try service.prepareRequestConfiguration()) { error in
            guard case TranscriptionError.invalidEndpoint = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPrepareRequestConfigurationFreezesProviderAndModel() throws {
        var endpoint = DataProcessingEndpoint.current(provider: .openAI)
        var model = "gpt-4o-mini-transcribe"
        let service = TranscriptionService(
            apiKeyProvider: { "test-key" },
            modelProvider: { model },
            dataProcessingEndpointProvider: { endpoint },
            dataProcessingConsentProvider: { _ in true }
        )

        let configuration = try service.prepareRequestConfiguration()
        endpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v1"
        )
        model = "whisper-1"

        XCTAssertEqual(configuration.endpoint.provider, .openAI)
        XCTAssertEqual(configuration.endpoint.displayAddress, "https://api.openai.com/v1")
        XCTAssertEqual(configuration.model, "gpt-4o-mini-transcribe")
    }

    func testConfigurationPreparationWaitsForAtomicSaveTransaction() async throws {
        var key = "key-a"
        var endpoint = DataProcessingEndpoint.current(provider: .openAI)
        var model = "model-a"
        let endpointB = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "api.example.com",
            customBasePath: "/v1"
        )
        let transactionReachedMidpoint = expectation(
            description: "Configuration transaction reached midpoint"
        )
        let releaseTransaction = DispatchSemaphore(value: 0)
        let service = TranscriptionService(
            apiKeyProvider: { key },
            modelProvider: { model },
            dataProcessingEndpointProvider: { endpoint },
            dataProcessingConsentProvider: { _ in true }
        )

        let writer = Task.detached {
            TranscriptionConfigurationTransaction.perform {
                key = "key-b"
                transactionReachedMidpoint.fulfill()
                releaseTransaction.wait()
                endpoint = endpointB
                model = "model-b"
            }
        }
        await fulfillment(of: [transactionReachedMidpoint], timeout: 1)
        let reader = Task.detached {
            try service.prepareRequestConfiguration()
        }

        releaseTransaction.signal()
        await writer.value
        let configuration = try await reader.value

        XCTAssertEqual(configuration.apiKey, "key-b")
        XCTAssertEqual(configuration.endpoint, endpointB)
        XCTAssertEqual(configuration.model, "model-b")
    }
}

private enum CredentialTestError: Error {
    case unavailable
}
