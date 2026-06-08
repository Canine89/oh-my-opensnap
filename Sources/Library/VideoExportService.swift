import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoExportService {
    static func trimmedMP4(source: URL, timeRange: CMTimeRange, completion: @escaping (Result<URL, Error>) -> Void) {
        let destination = uniqueSiblingURL(source: source, suffix: "trim", extension: "mp4")
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(ExportError.exportSessionFailed))
            return
        }

        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.timeRange = clamped(timeRange: timeRange, duration: asset.duration)
        exporter.shouldOptimizeForNetworkUse = true
        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    completion(.success(destination))
                case .failed, .cancelled:
                    completion(.failure(exporter.error ?? ExportError.writerFailed))
                default:
                    completion(.failure(ExportError.writerFailed))
                }
            }
        }
    }

    static func gif(source: URL, timeRange: CMTimeRange, frameCount: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destination = uniqueSiblingURL(source: source, suffix: "gif-\(frameCount)", extension: "gif")
                try? FileManager.default.removeItem(at: destination)

                let asset = AVURLAsset(url: source)
                let range = clamped(timeRange: timeRange, duration: asset.duration)
                let duration = max(range.duration.seconds, 0.1)
                let startSeconds = max(range.start.seconds, 0)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero

                guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL,
                                                                           UTType.gif.identifier as CFString,
                                                                           frameCount,
                                                                           nil) else {
                    throw ExportError.gifDestinationFailed
                }

                CGImageDestinationSetProperties(destinationRef, [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFLoopCount: 0
                    ]
                ] as CFDictionary)

                let delay = duration / Double(max(1, frameCount))
                for index in 0..<frameCount {
                    let offset = duration * Double(index) / Double(max(1, frameCount - 1))
                    let seconds = min(startSeconds + duration, startSeconds + offset)
                    let cgImage = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                            actualTime: nil)
                    CGImageDestinationAddImage(destinationRef, cgImage, [
                        kCGImagePropertyGIFDictionary: [
                            kCGImagePropertyGIFDelayTime: delay
                        ]
                    ] as CFDictionary)
                }

                guard CGImageDestinationFinalize(destinationRef) else {
                    throw ExportError.gifFinalizeFailed
                }
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func clamped(timeRange: CMTimeRange, duration: CMTime) -> CMTimeRange {
        let total = max(duration.seconds.isFinite ? duration.seconds : 0, 0)
        let start = min(max(timeRange.start.seconds, 0), total)
        let end = min(max(timeRange.end.seconds, start), total)
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                           end: CMTime(seconds: end, preferredTimescale: 600))
    }

    private static func uniqueSiblingURL(source: URL, suffix: String, extension pathExtension: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var url = directory.appendingPathComponent("\(base)-\(suffix).\(pathExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix)-\(index).\(pathExtension)")
            index += 1
        }
        return url
    }

    enum ExportError: LocalizedError {
        case exportSessionFailed
        case writerFailed
        case gifDestinationFailed
        case gifFinalizeFailed

        var errorDescription: String? {
            switch self {
            case .exportSessionFailed: return "영상 내보내기 세션을 만들 수 없습니다."
            case .writerFailed: return "영상 저장 중 오류가 발생했습니다."
            case .gifDestinationFailed: return "GIF 파일을 만들 수 없습니다."
            case .gifFinalizeFailed: return "GIF 저장을 완료할 수 없습니다."
            }
        }
    }
}
