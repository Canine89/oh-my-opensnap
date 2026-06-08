import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum VideoExportService {
    static func croppedMP4(source: URL, crop: CGRect, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destination = uniqueSiblingURL(source: source, suffix: "crop", extension: "mp4")
                try? FileManager.default.removeItem(at: destination)

                let asset = AVURLAsset(url: source)
                guard let track = asset.tracks(withMediaType: .video).first else {
                    throw ExportError.missingVideoTrack
                }

                let reader = try AVAssetReader(asset: asset)
                let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
                readerOutput.alwaysCopiesSampleData = false
                guard reader.canAdd(readerOutput) else { throw ExportError.readerOutputRejected }
                reader.add(readerOutput)

                let sourceSize = naturalSize(for: track)
                let cropRect = pixelCropRect(normalized: crop, sourceSize: sourceSize)
                let outputWidth = max(2, Int(cropRect.width).roundedDownToEven)
                let outputHeight = max(2, Int(cropRect.height).roundedDownToEven)

                let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
                let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: outputWidth,
                    AVVideoHeightKey: outputHeight
                ])
                writerInput.expectsMediaDataInRealTime = false
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: outputWidth,
                    kCVPixelBufferHeightKey as String: outputHeight
                ])
                guard writer.canAdd(writerInput) else { throw ExportError.writerInputRejected }
                writer.add(writerInput)

                guard reader.startReading() else { throw reader.error ?? ExportError.readerStartFailed }
                guard writer.startWriting() else { throw writer.error ?? ExportError.writerStartFailed }

                let context = CIContext(options: nil)
                var didStartSession = false

                while reader.status == .reading, let sample = readerOutput.copyNextSampleBuffer() {
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return }
                        let time = CMSampleBufferGetPresentationTimeStamp(sample)
                        if !didStartSession {
                            writer.startSession(atSourceTime: time)
                            didStartSession = true
                        }

                        while !writerInput.isReadyForMoreMediaData {
                            Thread.sleep(forTimeInterval: 0.004)
                        }

                        guard let pool = adaptor.pixelBufferPool else { return }
                        var outputBuffer: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                        guard let outputBuffer else { return }

                        let image = CIImage(cvPixelBuffer: imageBuffer)
                        let sourceExtent = image.extent
                        let rect = CGRect(x: sourceExtent.minX + cropRect.minX,
                                          y: sourceExtent.minY + cropRect.minY,
                                          width: CGFloat(outputWidth),
                                          height: CGFloat(outputHeight))
                        let cropped = image.cropped(to: rect)
                            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
                        context.render(cropped, to: outputBuffer)
                        adaptor.append(outputBuffer, withPresentationTime: time)
                    }
                }

                writerInput.markAsFinished()
                let result = finish(writer: writer)
                if reader.status == .failed { throw reader.error ?? ExportError.readerFailed }
                if case .failure(let error) = result { throw error }
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    static func gif(source: URL, crop: CGRect?, frameCount: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let destination = uniqueSiblingURL(source: source, suffix: "gif-\(frameCount)", extension: "gif")
                try? FileManager.default.removeItem(at: destination)

                let asset = AVURLAsset(url: source)
                let duration = max(asset.duration.seconds, 0.1)
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

                let delay = duration / Double(max(1, frameCount - 1))
                for index in 0..<frameCount {
                    let seconds = min(duration, Double(index) * delay)
                    let cgImage = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                            actualTime: nil)
                    let frame = crop.flatMap { cropImage(cgImage, normalized: $0) } ?? cgImage
                    CGImageDestinationAddImage(destinationRef, frame, [
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

    private static func finish(writer: AVAssetWriter) -> Result<Void, Error> {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error> = .success(())
        writer.finishWriting {
            if writer.status == .failed {
                result = .failure(writer.error ?? ExportError.writerFailed)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    private static func naturalSize(for track: AVAssetTrack) -> CGSize {
        let transformed = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    private static func pixelCropRect(normalized: CGRect, sourceSize: CGSize) -> CGRect {
        let clamped = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let x = clamped.minX * sourceSize.width
        let y = (1 - clamped.maxY) * sourceSize.height
        let width = clamped.width * sourceSize.width
        let height = clamped.height * sourceSize.height
        return CGRect(x: x.rounded(.down), y: y.rounded(.down),
                      width: width.rounded(.down), height: height.rounded(.down))
    }

    private static func cropImage(_ image: CGImage, normalized: CGRect) -> CGImage? {
        let clamped = normalized.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let rect = CGRect(x: clamped.minX * CGFloat(image.width),
                          y: (1 - clamped.maxY) * CGFloat(image.height),
                          width: clamped.width * CGFloat(image.width),
                          height: clamped.height * CGFloat(image.height)).integral
        return image.cropping(to: rect)
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
        case missingVideoTrack
        case readerOutputRejected
        case writerInputRejected
        case readerStartFailed
        case writerStartFailed
        case readerFailed
        case writerFailed
        case gifDestinationFailed
        case gifFinalizeFailed

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack: return "영상 트랙을 찾을 수 없습니다."
            case .readerOutputRejected: return "영상 읽기 출력을 만들 수 없습니다."
            case .writerInputRejected: return "영상 쓰기 입력을 만들 수 없습니다."
            case .readerStartFailed: return "영상 읽기를 시작할 수 없습니다."
            case .writerStartFailed: return "영상 쓰기를 시작할 수 없습니다."
            case .readerFailed: return "영상 읽기 중 오류가 발생했습니다."
            case .writerFailed: return "영상 저장 중 오류가 발생했습니다."
            case .gifDestinationFailed: return "GIF 파일을 만들 수 없습니다."
            case .gifFinalizeFailed: return "GIF 저장을 완료할 수 없습니다."
            }
        }
    }
}

private extension Int {
    var roundedDownToEven: Int {
        self - (self % 2)
    }
}
