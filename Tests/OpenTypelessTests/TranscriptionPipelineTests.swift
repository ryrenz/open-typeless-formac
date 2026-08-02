import Foundation
import XCTest
@testable import OpenTypeless

final class TranscriptionPipelineTests: XCTestCase {
    func testSegmentedTranscriptionPreservesOrderAndRemovesOverlap() async throws {
        let urls = try makeAudioFiles(count: 2)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [.success("Hello world"), .success("world again")]
        )
        let service = makeService(
            urls: urls,
            overlappingChunkIndices: [1],
            transport: transport
        )

        let result = try await service.transcribe(
            audioURL: urls[0],
            prompt: "Prefer names"
        )

        XCTAssertEqual(result, "Hello world\n\nagain")
        let prompts = await transport.prompts
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[0], "Prefer names")
        XCTAssertTrue(prompts[1]?.contains("Hello world") == true)
    }

    func testNonOverlappingSegmentsKeepIntentionalRepeatedText() async throws {
        let urls = try makeAudioFiles(count: 2)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [.success("Please keep this"), .success("this is intentional")]
        )
        let service = makeService(urls: urls, transport: transport)

        let result = try await service.transcribe(audioURL: urls[0])

        XCTAssertEqual(result, "Please keep this\n\nthis is intentional")
    }

    func testTransientFailureRetriesThenSucceeds() async throws {
        let urls = try makeAudioFiles(count: 1)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [
                .failure(URLError(.timedOut)),
                .success("Recovered"),
            ]
        )
        let service = makeService(
            urls: urls,
            transport: transport,
            retryDelaysNanoseconds: [0]
        )

        let result = try await service.transcribe(audioURL: urls[0])

        XCTAssertEqual(result, "Recovered")
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testEndpointSnapshotIsUsedForConsentAndTransport() async throws {
        let urls = try makeAudioFiles(count: 1)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let consentedEndpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "consented.example.com",
            customBasePath: "/v1"
        )
        let changedEndpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: "changed.example.com",
            customBasePath: "/v1"
        )
        let transport = FakeTranscriptionTransport(results: [.success("Snapshot")])
        var endpointReadCount = 0
        var modelReadCount = 0
        var consentEndpoint: DataProcessingEndpoint?
        var transportEndpoint: DataProcessingEndpoint?
        let service = TranscriptionService(
            chunker: FakeAudioChunker(urls: urls, overlappingChunkIndices: []),
            apiKeyProvider: { "test-key" },
            modelProvider: {
                defer { modelReadCount += 1 }
                return modelReadCount == 0 ? "snapshot-model" : "changed-model"
            },
            dataProcessingEndpointProvider: {
                defer { endpointReadCount += 1 }
                return endpointReadCount == 0 ? consentedEndpoint : changedEndpoint
            },
            dataProcessingConsentProvider: {
                consentEndpoint = $0
                return $0 == consentedEndpoint
            },
            transportFactory: { _, endpoint in
                transportEndpoint = endpoint
                return transport
            },
            retryDelaysNanoseconds: [],
            sleep: { _ in }
        )

        let result = try await service.transcribe(audioURL: urls[0])
        let models = await transport.models

        XCTAssertEqual(result, "Snapshot")
        XCTAssertEqual(endpointReadCount, 1)
        XCTAssertEqual(modelReadCount, 1)
        XCTAssertEqual(consentEndpoint, consentedEndpoint)
        XCTAssertEqual(transportEndpoint, consentedEndpoint)
        XCTAssertEqual(models, ["snapshot-model"])
    }

    func testRevokedConsentStopsPreparedConfigurationBeforeNetworkRequest() async throws {
        let urls = try makeAudioFiles(count: 1)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let transport = FakeTranscriptionTransport(results: [.success("Should not run")])
        var hasConsent = true
        let service = TranscriptionService(
            chunker: FakeAudioChunker(urls: urls, overlappingChunkIndices: []),
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in hasConsent },
            transportFactory: { _, _ in transport },
            retryDelaysNanoseconds: [],
            sleep: { _ in }
        )
        let configuration = try service.prepareRequestConfiguration()
        hasConsent = false

        do {
            _ = try await service.transcribe(
                audioURL: urls[0],
                configuration: configuration
            )
            XCTFail("Expected consent to be required")
        } catch TranscriptionError.dataProcessingConsentRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testRevokedConsentStopsRetryBeforeSecondNetworkRequest() async throws {
        let urls = try makeAudioFiles(count: 1)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let transport = FakeTranscriptionTransport(
            results: [
                .failure(URLError(.timedOut)),
                .success("Should not run"),
            ]
        )
        var hasConsent = true
        let service = TranscriptionService(
            chunker: FakeAudioChunker(urls: urls, overlappingChunkIndices: []),
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in hasConsent },
            transportFactory: { _, _ in transport },
            retryDelaysNanoseconds: [0],
            sleep: { _ in hasConsent = false }
        )

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected consent to be required")
        } catch TranscriptionError.dataProcessingConsentRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testRegrantDoesNotRevivePreparedConfigurationForRetry() async throws {
        let urls = try makeAudioFiles(count: 1)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let suiteName = "TranscriptionPipelineConsent-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let consentStore = DataProcessingConsentStore(defaults: defaults)
        let endpoint = DataProcessingEndpoint.current(provider: .openAI)
        consentStore.grantConsent(for: endpoint)
        let transport = FakeTranscriptionTransport(
            results: [
                .failure(URLError(.timedOut)),
                .success("Should not run"),
            ]
        )
        let service = TranscriptionService(
            chunker: FakeAudioChunker(urls: urls, overlappingChunkIndices: []),
            apiKeyProvider: { "test-key" },
            dataProcessingEndpointProvider: { endpoint },
            dataProcessingConsentStore: consentStore,
            transportFactory: { _, _ in transport },
            retryDelaysNanoseconds: [0],
            sleep: { _ in
                consentStore.revokeConsent(for: endpoint)
                consentStore.grantConsent(for: endpoint)
            }
        )

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected the prepared consent token to remain revoked")
        } catch TranscriptionError.dataProcessingConsentRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    func testPermanentFailureReturnsCompletedPartialText() async throws {
        let urls = try makeAudioFiles(count: 2)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [
                .success("First segment"),
                .failure(PipelineTestError.permanent),
            ]
        )
        let service = makeService(urls: urls, transport: transport)

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected a partial result")
        } catch let TranscriptionError.partialResult(
            text,
            completedSegments,
            totalSegments,
            underlying
        ) {
            XCTAssertEqual(text, "First segment")
            XCTAssertEqual(completedSegments, 1)
            XCTAssertEqual(totalSegments, 2)
            XCTAssertTrue(underlying is PipelineTestError)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptySegmentsReturnNoResult() async throws {
        let urls = try makeAudioFiles(count: 2)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [.success(""), .success("   ")]
        )
        let service = makeService(urls: urls, transport: transport)

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected no result")
        } catch TranscriptionError.noResult {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPartialProgressCountsUsableSegments() async throws {
        let urls = try makeAudioFiles(count: 3)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [
                .success(""),
                .success("Recovered segment"),
                .failure(PipelineTestError.permanent),
            ]
        )
        let service = makeService(urls: urls, transport: transport)

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected a partial result")
        } catch let TranscriptionError.partialResult(
            text,
            completedSegments,
            totalSegments,
            _
        ) {
            XCTAssertEqual(text, "Recovered segment")
            XCTAssertEqual(completedSegments, 1)
            XCTAssertEqual(totalSegments, 3)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testInvalidMiddleSegmentReturnsPartialWithoutNonAdjacentDeduplication() async throws {
        let urls = try makeAudioFiles(count: 3)
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }

        let transport = FakeTranscriptionTransport(
            results: [
                .success("Please keep this"),
                .success(""),
                .success("this is intentional"),
            ]
        )
        let service = makeService(
            urls: urls,
            overlappingChunkIndices: [2],
            transport: transport
        )

        do {
            _ = try await service.transcribe(audioURL: urls[0])
            XCTFail("Expected a partial result")
        } catch let TranscriptionError.partialResult(
            text,
            completedSegments,
            totalSegments,
            underlying
        ) {
            XCTAssertEqual(
                text,
                "Please keep this\n\nthis is intentional"
            )
            XCTAssertEqual(completedSegments, 2)
            XCTAssertEqual(totalSegments, 3)
            guard case TranscriptionSegmentError.invalidResult(segment: 2) = underlying else {
                return XCTFail("Unexpected underlying error: \(underlying)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPromptContextUsesOnlyRecentTranscriptSuffix() {
        let previous = String(repeating: "a", count: 900)

        let prompt = TranscriptionService.makeSegmentPrompt(
            basePrompt: "Names",
            previousTranscript: previous
        )

        XCTAssertTrue(prompt?.hasPrefix("Names\n") == true)
        XCTAssertTrue(prompt?.hasSuffix(String(repeating: "a", count: 800)) == true)
        XCTAssertFalse(prompt?.hasSuffix(String(repeating: "a", count: 801)) == true)
    }

    func testProviderPromptPoliciesMatchProviderCapabilities() {
        let previous = String(repeating: "a", count: 900)

        let groqPrompt = TranscriptionService.makeSegmentPrompt(
            basePrompt: "Names",
            previousTranscript: previous,
            policy: .limited(maxCharacters: 200)
        )
        XCTAssertEqual(groqPrompt?.count, 200)
        XCTAssertTrue(groqPrompt?.hasPrefix("Names\n") == true)

        let longBasePrompt = TranscriptionService.makeSegmentPrompt(
            basePrompt: String(repeating: "b", count: 300),
            previousTranscript: "",
            policy: .limited(maxCharacters: 200)
        )
        XCTAssertEqual(longBasePrompt?.count, 200)

        let mistralPrompt = TranscriptionService.makeSegmentPrompt(
            basePrompt: "Names",
            previousTranscript: previous,
            policy: .unsupported
        )
        XCTAssertNil(mistralPrompt)
    }

    func testFailureClassifierRecognizesRetryableErrors() {
        XCTAssertTrue(
            TranscriptionFailureClassifier.isTransient(URLError(.networkConnectionLost))
        )
        XCTAssertTrue(
            TranscriptionFailureClassifier.isTransient(URLError(.secureConnectionFailed))
        )
        XCTAssertFalse(
            TranscriptionFailureClassifier.isTransient(PipelineTestError.permanent)
        )
        XCTAssertFalse(
            TranscriptionFailureClassifier.isTransient(URLError(.serverCertificateUntrusted))
        )
    }

    private func makeService(
        urls: [URL],
        overlappingChunkIndices: Set<Int> = [],
        transport: FakeTranscriptionTransport,
        retryDelaysNanoseconds: [UInt64] = []
    ) -> TranscriptionService {
        TranscriptionService(
            chunker: FakeAudioChunker(
                urls: urls,
                overlappingChunkIndices: overlappingChunkIndices
            ),
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in true },
            transportFactory: { _, _ in transport },
            retryDelaysNanoseconds: retryDelaysNanoseconds,
            sleep: { _ in }
        )
    }

    private func makeAudioFiles(count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptionPipelineTests-\(UUID().uuidString)-\(index)")
                .appendingPathExtension("m4a")
            try Data([UInt8(index)]).write(to: url)
            return url
        }
    }
}

private enum PipelineTestError: Error {
    case permanent
}

private final class FakeAudioChunker: AudioChunking {
    let urls: [URL]
    let overlappingChunkIndices: Set<Int>

    init(urls: [URL], overlappingChunkIndices: Set<Int>) {
        self.urls = urls
        self.overlappingChunkIndices = overlappingChunkIndices
    }

    func makeChunks(
        for audioURL: URL,
        silenceRanges: [AudioSilenceRange]
    ) async throws -> AudioChunkBatch {
        AudioChunkBatch(
            chunks: urls.enumerated().map { index, url in
                AudioChunk(
                    url: url,
                    duration: 60,
                    overlapsPrevious: overlappingChunkIndices.contains(index)
                )
            },
            temporaryDirectory: nil
        )
    }
}

private actor FakeTranscriptionTransport: TranscriptionTransport {
    private var results: [Result<String, Error>]
    private(set) var prompts: [String?] = []
    private(set) var models: [String] = []
    private(set) var requestCount = 0

    init(results: [Result<String, Error>]) {
        self.results = results
    }

    func transcribe(
        audioData: Data,
        audioFormat: TranscriptionAudioFormat,
        model: String,
        prompt: String?
    ) async throws -> String {
        requestCount += 1
        prompts.append(prompt)
        models.append(model)
        guard !results.isEmpty else { throw PipelineTestError.permanent }
        return try results.removeFirst().get()
    }

    func format(_ text: String) async -> String {
        text
    }
}
