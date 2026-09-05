import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum VideoExportService {
    private static var tasks: [UUID: Task<Void, Never>] = [:]

    static func trimmedMP4(source: URL, timeRange: CMTimeRange, completion: @escaping (Result<URL, Error>) -> Void) {
        launch(operation: { try await exportMP4(source: source, timeRange: timeRange) }, completion: completion)
    }

    static func gif(source: URL, timeRange: CMTimeRange, frameCount: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        launch(operation: { try await exportGIF(source: source, timeRange: timeRange, frameCount: frameCount) }, completion: completion)
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

    nonisolated static func exportMP4(source: URL, timeRange: CMTimeRange) async throws -> URL {
        let access = Settings.shared.retainLibraryAccess(for: source)
        defer { withExtendedLifetime(access) {} }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.exportSessionFailed
        }
        exporter.timeRange = try clamped(timeRange: timeRange, duration: duration)
        exporter.shouldOptimizeForNetworkUse = true
        let destination = destinationURL(source: source, suffix: "trim", extension: "mp4")
        let staging = stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await exporter.export(to: staging, as: .mp4)
        try FileManager.default.moveItem(at: staging, to: destination)
        return destination
    }

    nonisolated static func exportGIF(source: URL, timeRange: CMTimeRange, frameCount: Int) async throws -> URL {
        guard frameCount > 0, frameCount <= 300 else { throw ExportError.invalidRange }
        let access = Settings.shared.retainLibraryAccess(for: source)
        defer { withExtendedLifetime(access) {} }
        let asset = AVURLAsset(url: source)
        let range = try clamped(timeRange: timeRange, duration: try await asset.load(.duration))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let destination = destinationURL(source: source, suffix: "gif-\(frameCount)", extension: "gif")
        let staging = stagingURL(for: destination)
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let output = CGImageDestinationCreateWithURL(staging as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw ExportError.gifDestinationFailed
        }
        CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = range.duration.seconds / Double(frameCount)
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
