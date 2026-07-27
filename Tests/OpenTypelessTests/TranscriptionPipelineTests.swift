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
            transportFactory: { _ in transport },
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
        guard !results.isEmpty else { throw PipelineTestError.permanent }
        return try results.removeFirst().get()
    }

    func format(_ text: String) async -> String {
        text
    }
}
