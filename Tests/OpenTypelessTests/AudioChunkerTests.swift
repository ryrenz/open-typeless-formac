import AVFoundation
import XCTest
@testable import OpenTypeless

final class AudioChunkerTests: XCTestCase {
    func testShortRecordingDoesNotRequireChunking() {
        XCTAssertFalse(
            AudioChunker.requiresChunking(
                duration: 120,
                fileSize: 2 * 1024 * 1024
            )
        )
    }

    func testDurationOrFileSizeCanRequireChunking() {
        XCTAssertTrue(
            AudioChunker.requiresChunking(
                duration: AudioChunker.defaultMaximumDuration + 1,
                fileSize: 2 * 1024 * 1024
            )
        )
        XCTAssertTrue(
            AudioChunker.requiresChunking(
                duration: 120,
                fileSize: AudioChunker.maximumSingleRequestBytes + 1
            )
        )
    }

    func testPlansPreferSilenceBeforeHardBoundary() {
        let plans = AudioChunker.makePlans(
            duration: 500,
            silenceRanges: [
                AudioSilenceRange(start: 225, end: 227),
                AudioSilenceRange(start: 470, end: 472),
            ],
            maximumDuration: 240
        )

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(plans[0].duration, 226, accuracy: 0.001)
        XCTAssertFalse(plans[0].overlapsPrevious)
        XCTAssertEqual(plans[1].start, 226, accuracy: 0.001)
        XCTAssertEqual(plans[1].duration, 240, accuracy: 0.001)
        XCTAssertFalse(plans[1].overlapsPrevious)
    }

    func testHardSplitAddsOverlap() {
        let plans = AudioChunker.makePlans(
            duration: 500,
            silenceRanges: [],
            maximumDuration: 240,
            hardSplitOverlap: 0.75
        )

        XCTAssertEqual(plans.count, 3)
        XCTAssertEqual(plans[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(plans[0].duration, 240, accuracy: 0.001)
        XCTAssertEqual(plans[1].start, 239.25, accuracy: 0.001)
        XCTAssertTrue(plans[1].overlapsPrevious)
        XCTAssertEqual(plans[2].start, 478.5, accuracy: 0.001)
        XCTAssertTrue(plans[2].overlapsPrevious)
    }

    func testHardSplitWithShortMaximumDoesNotSkipAudio() throws {
        let plans = AudioChunker.makePlans(
            duration: 40,
            silenceRanges: [],
            maximumDuration: 15,
            hardSplitOverlap: 0.75
        )

        XCTAssertEqual(plans.count, 3)
        for index in 1..<plans.count {
            let previousEnd = plans[index - 1].start + plans[index - 1].duration
            XCTAssertLessThanOrEqual(plans[index].start, previousEnd)
        }
        let lastPlan = try XCTUnwrap(plans.last)
        let finalEnd = lastPlan.start + lastPlan.duration
        XCTAssertEqual(finalEnd, 40, accuracy: 0.001)
    }

    func testOversizedPlanSplitCoversFullRangeWithBoundedOverlap() {
        let original = AudioChunkPlan(
            start: 10,
            duration: 40,
            overlapsPrevious: false
        )

        let children = AudioChunker.splitOversizedPlan(original)

        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(children[0].start, 10, accuracy: 0.001)
        XCTAssertEqual(
            children[1].start + children[1].duration,
            50,
            accuracy: 0.001
        )
        XCTAssertFalse(children[0].overlapsPrevious)
        XCTAssertTrue(children[1].overlapsPrevious)

        let overlap = children[0].start + children[0].duration - children[1].start
        XCTAssertEqual(overlap, AudioChunker.hardSplitOverlap, accuracy: 0.001)
    }

    func testMakeChunksExportsReadableM4AAndCleansUp() async throws {
        let sourceURL = try makeSilentM4A(duration: 65)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let chunker = AudioChunker(maximumDuration: 31)
        let batch = try await chunker.makeChunks(
            for: sourceURL,
            silenceRanges: []
        )
        let temporaryDirectory = try XCTUnwrap(batch.temporaryDirectory)

        XCTAssertEqual(batch.chunks.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryDirectory.path))
        for chunk in batch.chunks {
            let duration = try await AVURLAsset(url: chunk.url).load(.duration)
            XCTAssertGreaterThan(CMTimeGetSeconds(duration), 0)
        }

        batch.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryDirectory.path))
    }

    func testImpossibleByteLimitTerminatesAndCleansUp() async throws {
        let sourceURL = try makeSilentM4A(duration: 12)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let directoriesBefore = try chunkTemporaryDirectories()
        let chunker = AudioChunker(
            maximumDuration: 1_000,
            maximumSingleRequestBytes: 1
        )

        do {
            _ = try await chunker.makeChunks(
                for: sourceURL,
                silenceRanges: []
            )
            XCTFail("Expected an oversized chunk error")
        } catch AudioChunkerError.exportedChunkTooLarge {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(try chunkTemporaryDirectories(), directoriesBefore)
    }

    private func chunkTemporaryDirectories() throws -> Set<String> {
        let urls = try FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        return Set(
            urls
                .map(\.lastPathComponent)
                .filter { $0.hasPrefix("OpenTypeless-Chunks-") }
        )
    }

    private func makeSilentM4A(duration: TimeInterval) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioChunkerTests-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        )
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            )
        )
        buffer.frameLength = frameCount
        buffer.floatChannelData?[0].initialize(
            repeating: 0,
            count: Int(frameCount)
        )
        try file.write(from: buffer)
        return url
    }
}
