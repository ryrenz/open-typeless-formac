import AVFoundation
import Foundation

enum AudioRecorderError: Error, LocalizedError {
    case engineSetupFailed
    case noAudioData
    case wavWriteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .engineSetupFailed: return "Failed to set up audio recorder"
        case .noAudioData: return "No audio data recorded"
        case .wavWriteFailed(let error): return "Failed to write WAV: \(error.localizedDescription)"
        }
    }
}

final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private static let silenceThreshold: Float = 0.08

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var isRecording = false
    private var peakObservedLevel: Float = 0
    private var silenceRangeDetector = SilenceRangeDetector()

    func startRecording() throws {
        guard !isRecording else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // Record as M4A (AAC) — macOS handles format negotiation automatically
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let rec: AVAudioRecorder
        do {
            rec = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            print("[AudioRecorder] Failed to create recorder: \(error)")
            throw AudioRecorderError.engineSetupFailed
        }

        rec.delegate = self
        rec.isMeteringEnabled = true
        if !rec.prepareToRecord() {
            print("[AudioRecorder] prepareToRecord failed")
            throw AudioRecorderError.engineSetupFailed
        }

        if !rec.record() {
            print("[AudioRecorder] record() returned false")
            throw AudioRecorderError.engineSetupFailed
        }

        recorder = rec
        recordingURL = url
        isRecording = true
        peakObservedLevel = 0
        silenceRangeDetector.reset()
        print("[AudioRecorder] Recording started: \(url.lastPathComponent)")
    }

    func stopRecording() throws -> URL {
        guard isRecording, let rec = recorder, let url = recordingURL else {
            throw AudioRecorderError.noAudioData
        }

        let recordedDuration = rec.currentTime
        rec.stop()
        silenceRangeDetector.finish(at: recordedDuration)
        recorder = nil
        isRecording = false

        // Verify file exists and has data
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 44 else {
            throw AudioRecorderError.noAudioData
        }

        print("[AudioRecorder] Recording stopped, size: \(size) bytes")
        return url
    }

    func cancel() {
        if isRecording, let rec = recorder {
            rec.stop()
            rec.deleteRecording()
        }
        recorder = nil
        recordingURL = nil
        isRecording = false
        peakObservedLevel = 0
        silenceRangeDetector.reset()
    }

    /// Get current audio level (0.0 - 1.0). Call periodically during recording.
    func currentLevel() -> Float {
        guard let rec = recorder, isRecording, rec.isRecording else { return 0 }
        rec.updateMeters()
        let dB = rec.averagePower(forChannel: 0) // -160 to 0
        let normalized = max(0, (dB + 50) / 50) // map -50...0 dB to 0...1
        let level = min(normalized, 1.0)
        peakObservedLevel = max(peakObservedLevel, level)
        silenceRangeDetector.record(time: rec.currentTime, level: level)
        return level
    }

    func shouldSkipTranscriptionForSilence() -> Bool {
        Self.isSilentRecording(peakLevel: peakObservedLevel)
    }

    func observedPeakLevel() -> Float {
        peakObservedLevel
    }

    func observedSilenceRanges() -> [AudioSilenceRange] {
        silenceRangeDetector.ranges
    }

    static func isSilentRecording(peakLevel: Float) -> Bool {
        peakLevel < silenceThreshold
    }

    static func cleanUp(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
