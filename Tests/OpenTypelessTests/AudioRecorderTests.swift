import XCTest
@testable import OpenTypeless

final class AudioRecorderTests: XCTestCase {
    func testSilentRecordingThresholdRejectsNearZeroPeak() {
        XCTAssertTrue(AudioRecorder.isSilentRecording(peakLevel: 0.01))
        XCTAssertTrue(AudioRecorder.isSilentRecording(peakLevel: 0.079))
    }

    func testSilentRecordingThresholdAllowsAudiblePeak() {
        XCTAssertFalse(AudioRecorder.isSilentRecording(peakLevel: 0.08))
        XCTAssertFalse(AudioRecorder.isSilentRecording(peakLevel: 0.2))
    }

    func testStopWithoutStartThrows() {
        let recorder = AudioRecorder()
        XCTAssertThrowsError(try recorder.stopRecording()) { error in
            XCTAssertTrue(error is AudioRecorderError)
        }
    }

    func testCancelWithoutStartDoesNotCrash() {
        let recorder = AudioRecorder()
        recorder.cancel()
    }

    func testCleanUpNonexistentFile() {
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent.wav")
        AudioRecorder.cleanUp(url: fakeURL)
    }

    func testSilenceRangeDetectorKeepsOnlySustainedQuietRanges() {
        var detector = SilenceRangeDetector(
            quietThreshold: 0.12,
            minimumQuietDuration: 0.35
        )

        detector.record(time: 1.0, level: 0.05)
        detector.record(time: 1.2, level: 0.04)
        detector.record(time: 1.5, level: 0.2)
        detector.record(time: 2.0, level: 0.05)
        detector.record(time: 2.1, level: 0.2)

        XCTAssertEqual(
            detector.ranges,
            [AudioSilenceRange(start: 1.0, end: 1.5)]
        )
    }

    func testSilenceRangeDetectorClosesTrailingRange() {
        var detector = SilenceRangeDetector(
            quietThreshold: 0.12,
            minimumQuietDuration: 0.35
        )

        detector.record(time: 4.0, level: 0.05)
        detector.finish(at: 4.5)

        XCTAssertEqual(
            detector.ranges,
            [AudioSilenceRange(start: 4.0, end: 4.5)]
        )
    }
}
