import AVFoundation
import Foundation

private final class AudioExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession

    init(_ session: AVAssetExportSession) {
        self.session = session
    }
}

struct AudioSilenceRange: Equatable {
    let start: TimeInterval
    let end: TimeInterval

    var midpoint: TimeInterval {
        start + (end - start) / 2
    }
}

struct SilenceRangeDetector {
    private let quietThreshold: Float
    private let minimumQuietDuration: TimeInterval
    private var quietStart: TimeInterval?
    private(set) var ranges: [AudioSilenceRange] = []

    init(
        quietThreshold: Float = 0.12,
        minimumQuietDuration: TimeInterval = 0.35
    ) {
        self.quietThreshold = quietThreshold
        self.minimumQuietDuration = minimumQuietDuration
    }

    mutating func record(time: TimeInterval, level: Float) {
        if level <= quietThreshold {
            if quietStart == nil {
                quietStart = time
            }
            return
        }

        closeQuietRange(at: time)
    }

    mutating func finish(at time: TimeInterval) {
        closeQuietRange(at: time)
    }

    mutating func reset() {
        quietStart = nil
        ranges = []
    }

    private mutating func closeQuietRange(at end: TimeInterval) {
        guard let start = quietStart else { return }
        quietStart = nil

        guard end - start >= minimumQuietDuration else { return }
        ranges.append(AudioSilenceRange(start: start, end: end))
    }
}

struct AudioChunkPlan: Equatable {
    let start: TimeInterval
    let duration: TimeInterval
    let overlapsPrevious: Bool
}

struct AudioChunk {
    let url: URL
    let duration: TimeInterval
    let overlapsPrevious: Bool
}

struct AudioChunkBatch {
    let chunks: [AudioChunk]
    let temporaryDirectory: URL?

    func cleanUp(fileManager: FileManager = .default) {
        guard let temporaryDirectory else { return }
        try? fileManager.removeItem(at: temporaryDirectory)
    }
}

protocol AudioChunking {
    func makeChunks(
        for audioURL: URL,
        silenceRanges: [AudioSilenceRange]
    ) async throws -> AudioChunkBatch
}

enum AudioChunkerError: Error, LocalizedError {
    case invalidDuration
    case exportSessionUnavailable
    case exportFailed(Error?)
    case exportedChunkTooLarge(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "Unable to determine the recording duration"
        case .exportSessionUnavailable:
            return "Unable to create an audio export session"
        case .exportFailed(let error):
            return "Audio chunk export failed: \(error?.localizedDescription ?? "Unknown error")"
        case .exportedChunkTooLarge(let bytes):
            return "Exported audio chunk is still too large (\(bytes) bytes)"
        }
    }
}

final class AudioChunker: AudioChunking {
    static let defaultMaximumDuration: TimeInterval = 240
    static let maximumSingleRequestBytes = 20 * 1024 * 1024
    static let hardSplitOverlap: TimeInterval = 0.75

    private static let byteBudgetSafetyFactor = 0.85
    private static let minimumRetryChunkDuration: TimeInterval = 5

    private let fileManager: FileManager
    private let maximumDuration: TimeInterval
    private let maximumSingleRequestBytes: Int

    init(
        fileManager: FileManager = .default,
        maximumDuration: TimeInterval = AudioChunker.defaultMaximumDuration,
        maximumSingleRequestBytes: Int = AudioChunker.maximumSingleRequestBytes
    ) {
        self.fileManager = fileManager
        self.maximumDuration = maximumDuration
        self.maximumSingleRequestBytes = maximumSingleRequestBytes
    }

    func makeChunks(
        for audioURL: URL,
        silenceRanges: [AudioSilenceRange]
    ) async throws -> AudioChunkBatch {
        let asset = AVURLAsset(url: audioURL)
        let assetDuration = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(assetDuration)
        guard duration.isFinite, duration > 0 else {
            throw AudioChunkerError.invalidDuration
        }

        let fileSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let requiresChunking = Self.requiresChunking(
            duration: duration,
            fileSize: fileSize,
            maximumDuration: maximumDuration,
            maximumBytes: maximumSingleRequestBytes
        )
        guard requiresChunking else {
            return AudioChunkBatch(
                chunks: [
                    AudioChunk(
                        url: audioURL,
                        duration: duration,
                        overlapsPrevious: false
                    ),
                ],
                temporaryDirectory: nil
            )
        }

        var effectiveMaximumDuration = maximumDuration
        if fileSize > maximumSingleRequestBytes {
            let proportionalDuration = duration
                * Double(maximumSingleRequestBytes)
                / Double(fileSize)
                * Self.byteBudgetSafetyFactor
            effectiveMaximumDuration = min(
                maximumDuration,
                max(15, proportionalDuration)
            )
        }

        let plans = Self.makePlans(
            duration: duration,
            silenceRanges: silenceRanges,
            maximumDuration: effectiveMaximumDuration
        )
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenTypeless-Chunks-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var chunks: [AudioChunk] = []
            for plan in plans {
                chunks.append(
                    contentsOf: try await exportValidatedChunks(
                        asset: asset,
                        plan: plan,
                        temporaryDirectory: temporaryDirectory
                    )
                )
            }

            return AudioChunkBatch(chunks: chunks, temporaryDirectory: temporaryDirectory)
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    static func requiresChunking(
        duration: TimeInterval,
        fileSize: Int,
        maximumDuration: TimeInterval = defaultMaximumDuration,
        maximumBytes: Int = maximumSingleRequestBytes
    ) -> Bool {
        duration > maximumDuration || fileSize > maximumBytes
    }

    static func makePlans(
        duration: TimeInterval,
        silenceRanges: [AudioSilenceRange],
        maximumDuration: TimeInterval = defaultMaximumDuration,
        minimumSegmentDuration: TimeInterval = 30,
        silenceSearchWindow: TimeInterval = 30,
        hardSplitOverlap: TimeInterval = hardSplitOverlap
    ) -> [AudioChunkPlan] {
        guard duration > 0 else { return [] }
        guard duration > maximumDuration else {
            return [AudioChunkPlan(start: 0, duration: duration, overlapsPrevious: false)]
        }

        var plans: [AudioChunkPlan] = []
        var start: TimeInterval = 0
        var overlapsPrevious = false

        while start < duration {
            let hardEnd = min(start + maximumDuration, duration)
            if hardEnd >= duration {
                plans.append(
                    AudioChunkPlan(
                        start: start,
                        duration: duration - start,
                        overlapsPrevious: overlapsPrevious
                    )
                )
                break
            }

            let earliestSilence = max(
                start + minimumSegmentDuration,
                hardEnd - silenceSearchWindow
            )
            let silenceBoundary = silenceRanges
                .map(\.midpoint)
                .filter { $0 >= earliestSilence && $0 <= hardEnd }
                .max()

            let end = silenceBoundary ?? hardEnd
            plans.append(
                AudioChunkPlan(
                    start: start,
                    duration: end - start,
                    overlapsPrevious: overlapsPrevious
                )
            )

            if silenceBoundary == nil {
                let overlap = min(
                    hardSplitOverlap,
                    max(0, (end - start) / 2)
                )
                start = end - overlap
                overlapsPrevious = true
            } else {
                start = end
                overlapsPrevious = false
            }
        }

        return plans
    }

    private func exportValidatedChunks(
        asset: AVAsset,
        plan: AudioChunkPlan,
        temporaryDirectory: URL
    ) async throws -> [AudioChunk] {
        let outputURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try await export(
            asset: asset,
            plan: plan,
            outputURL: outputURL
        )

        let fileSize = try outputURL
            .resourceValues(forKeys: [.fileSizeKey])
            .fileSize ?? Int.max
        guard fileSize > maximumSingleRequestBytes else {
            return [
                AudioChunk(
                    url: outputURL,
                    duration: plan.duration,
                    overlapsPrevious: plan.overlapsPrevious
                ),
            ]
        }

        try? fileManager.removeItem(at: outputURL)
        guard plan.duration > Self.minimumRetryChunkDuration * 2 else {
            throw AudioChunkerError.exportedChunkTooLarge(bytes: fileSize)
        }

        var chunks: [AudioChunk] = []
        for childPlan in Self.splitOversizedPlan(plan) {
            chunks.append(
                contentsOf: try await exportValidatedChunks(
                    asset: asset,
                    plan: childPlan,
                    temporaryDirectory: temporaryDirectory
                )
            )
        }
        return chunks
    }

    static func splitOversizedPlan(_ plan: AudioChunkPlan) -> [AudioChunkPlan] {
        let midpoint = plan.start + plan.duration / 2
        let overlap = min(hardSplitOverlap, plan.duration / 4)
        let firstEnd = midpoint + overlap / 2
        let secondStart = midpoint - overlap / 2
        let planEnd = plan.start + plan.duration

        return [
            AudioChunkPlan(
                start: plan.start,
                duration: firstEnd - plan.start,
                overlapsPrevious: plan.overlapsPrevious
            ),
            AudioChunkPlan(
                start: secondStart,
                duration: planEnd - secondStart,
                overlapsPrevious: true
            ),
        ]
    }

    private func export(
        asset: AVAsset,
        plan: AudioChunkPlan,
        outputURL: URL
    ) async throws {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioChunkerError.exportSessionUnavailable
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a
        session.shouldOptimizeForNetworkUse = true
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: plan.start, preferredTimescale: 600),
            duration: CMTime(seconds: plan.duration, preferredTimescale: 600)
        )

        let sessionBox = AudioExportSessionBox(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sessionBox.session.exportAsynchronously {
                    let session = sessionBox.session
                    switch session.status {
                    case .completed:
                        continuation.resume()
                    case .failed, .cancelled:
                        continuation.resume(
                            throwing: AudioChunkerError.exportFailed(session.error)
                        )
                    default:
                        continuation.resume(
                            throwing: AudioChunkerError.exportFailed(session.error)
                        )
                    }
                }
            }
        } onCancel: {
            sessionBox.session.cancelExport()
        }
    }
}
