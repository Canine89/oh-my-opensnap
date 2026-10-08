import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum VideoExportService {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    /// 배속 내보내기 단계. 1×는 원래 속도(자르기만).
    static let speedSteps: [Double] = [1, 1.5, 2, 4, 8, 16]

    static func trimmedMP4(source: URL, timeRange: CMTimeRange, speed: Double = 1,
                           completion: @escaping (Result<URL, Error>) -> Void) {
        launch(operation: { try await exportMP4(source: source, timeRange: timeRange, speed: speed) }, completion: completion)
    }

    static func gif(source: URL, timeRange: CMTimeRange, frameCount: Int, speed: Double = 1,
                    completion: @escaping (Result<URL, Error>) -> Void) {
        launch(operation: { try await exportGIF(source: source, timeRange: timeRange, frameCount: frameCount, speed: speed) },
               completion: completion)
    }

    nonisolated static func speedLabel(_ speed: Double) -> String {
        speed.rounded() == speed ? "\(Int(speed))×" : String(format: "%.1f×", speed)
    }

    static func flush() async {
        for task in Array(tasks.values) { await task.value }
    }

    private static func launch(operation: @escaping @Sendable () async throws -> URL,
                               completion: @escaping (Result<URL, Error>) -> Void) {
        let id = UUID()
        tasks[id] = Task {
            defer { tasks[id] = nil }
            do { completion(.success(try await operation())) }
            catch { completion(.failure(error)) }
        }
    }

    nonisolated static func exportMP4(source: URL, timeRange: CMTimeRange, speed: Double = 1) async throws -> URL {
        let asset = AVURLAsset(url: source)
        let range = try clamped(timeRange: timeRange, duration: try await asset.load(.duration))
        let exporter: AVAssetExportSession
        if speed > 1 {
            let (composition, videoComposition) = try await speedComposition(asset: asset, range: range, speed: speed)
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.exportSessionFailed
            }
            session.videoComposition = videoComposition
            session.audioTimePitchAlgorithm = .spectral
            exporter = session
        } else {
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw ExportError.exportSessionFailed
            }
            session.timeRange = range
            exporter = session
        }
        exporter.shouldOptimizeForNetworkUse = true
        let suffix = speed > 1 ? "trim-\(speedFileTag(speed))" : "trim"
        let destination = destinationURL(source: source, suffix: suffix, extension: "mp4")
        let staging = stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await exporter.export(to: staging, as: .mp4)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated static func exportGIF(source: URL, timeRange: CMTimeRange, frameCount: Int, speed: Double = 1) async throws -> URL {
        guard frameCount > 0, frameCount <= 300, speed >= 1 else { throw ExportError.invalidRange }
        let asset = AVURLAsset(url: source)
        let range = try clamped(timeRange: timeRange, duration: try await asset.load(.duration))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let suffix = speed > 1 ? "gif-\(frameCount)-\(speedFileTag(speed))" : "gif-\(frameCount)"
        let destination = destinationURL(source: source, suffix: suffix, extension: "gif")
        let staging = stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let output = CGImageDestinationCreateWithURL(staging as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.gifDestinationFailed
        }
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // 배속은 같은 프레임을 더 짧게 보여 주는 것. 브라우저는 0.02초 미만 지연을 0.1초로 늘려 버리므로 그 아래로는 내리지 않는다.
        let delay = max(range.duration.seconds / Double(frameCount) / speed, 0.02)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            // 영상 끝은 배타적이다. 마지막 프레임도 end보다 앞에서 요청한다.
            let time = CMTimeAdd(range.start, CMTimeMultiplyByFloat64(range.duration, multiplier: Double(index) / Double(frameCount)))
            let frame = try await generator.image(at: time)
            CGImageDestinationAddImage(output, frame.image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(output) else { throw ExportError.gifFinalizeFailed }
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    /// 선택 구간만 담은 컴포지션을 1/speed 길이로 압축한다. 출력 프레임레이트는 원본(최대 60fps)으로 다시 샘플링해
    /// 16배속에서 960fps 같은 비정상 영상이 나오지 않게 한다.
    nonisolated private static func speedComposition(asset: AVURLAsset, range: CMTimeRange,
                                                     speed: Double) async throws -> (AVMutableComposition, AVVideoComposition) {
        let composition = AVMutableComposition()
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportSessionFailed
        }
        try await insert(range, of: sourceVideo, into: videoTrack)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
        for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
            guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try await insert(range, of: sourceAudio, into: audioTrack)
        }
        let original = composition.duration
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: original),
                                   toDuration: CMTimeMultiplyByFloat64(original, multiplier: 1 / speed))

        var configuration = try await AVVideoComposition.Configuration(for: composition)
        let nominal = Double(try await sourceVideo.load(.nominalFrameRate))
        let fps = nominal.isFinite && nominal >= 1 ? min(nominal.rounded(), 60) : 60
        configuration.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // 원본 트랙 타이밍을 따르면 frameDuration이 무시되어 배속만큼 프레임레이트가 올라간다.
        configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return (composition, AVVideoComposition(configuration: configuration))
    }

    /// 트랙이 선택 구간보다 짧을 수 있으니 겹치는 부분만, 구간 시작 기준 위치에 넣는다.
    nonisolated private static func insert(_ range: CMTimeRange, of source: AVAssetTrack,
                                           into track: AVMutableCompositionTrack) async throws {
        let overlap = range.intersection(try await source.load(.timeRange))
        guard overlap.duration > .zero else { return }
        try track.insertTimeRange(overlap, of: source, at: CMTimeSubtract(overlap.start, range.start))
    }

    nonisolated private static func speedFileTag(_ speed: Double) -> String {
        speed.rounded() == speed ? "\(Int(speed))x" : String(format: "%.1fx", speed).replacingOccurrences(of: ".", with: "_")
    }

    nonisolated private static func clamped(timeRange: CMTimeRange, duration: CMTime) throws -> CMTimeRange {
        guard duration.seconds.isFinite, duration.seconds > 0,
              timeRange.start.seconds.isFinite, timeRange.end.seconds.isFinite else { throw ExportError.invalidRange }
        let start = min(max(timeRange.start.seconds, 0), duration.seconds)
        let end = min(max(timeRange.end.seconds, start), duration.seconds)
        guard end > start else { throw ExportError.invalidRange }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: end, preferredTimescale: 600))
    }

    nonisolated private static func destinationURL(source: URL, suffix: String, extension ext: String) -> URL {
        source.deletingLastPathComponent().appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(suffix)-\(UUID().uuidString).\(ext)")
    }

    nonisolated private static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".export-" + UUID().uuidString + "." + destination.pathExtension)
    }

    enum ExportError: LocalizedError {
        case invalidRange
        case exportSessionFailed
        case writerFailed
        case gifDestinationFailed
        case gifFinalizeFailed

        var errorDescription: String? {
            switch self {
            case .invalidRange: return loc("Select a non-empty video range.", "길이가 있는 영상 구간을 선택하세요.")
            case .exportSessionFailed: return loc("Could not create the video export session.", "영상 내보내기 세션을 만들 수 없습니다.")
            case .writerFailed: return loc("An error occurred while saving the video.", "영상 저장 중 오류가 발생했습니다.")
            case .gifDestinationFailed: return loc("Could not create the GIF file.", "GIF 파일을 만들 수 없습니다.")
            case .gifFinalizeFailed: return loc("Could not finish saving the GIF.", "GIF 저장을 완료할 수 없습니다.")
            }
        }
    }
}
