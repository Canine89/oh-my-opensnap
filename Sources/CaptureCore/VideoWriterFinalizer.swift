import AVFoundation

enum VideoWriterFinalizer {
    /// 호출자는 프레임 큐를 정지시킨 뒤 호출한다. 완료 콜백 자체가 성공을 뜻하지 않는다.
    /// `failure`는 파일을 완성하지 못했을 때 알릴 원인이다. 시스템이 스트림을 끊어도(공유 중단·디스플레이 분리)
    /// 프레임이 담긴 파일이 완성되면 성공이다. 완성하지 못한 파일은 보관함에 깨진 항목으로 남지 않게 지운다.
    /// `endTime`은 마지막 프레임을 붙잡아 둘 끝 시각이다. 없으면 영상이 마지막 프레임 PTS에서 끝난다.
    static func finish(writer: AVAssetWriter, input: AVAssetWriterInput, hasFrames: Bool,
                       endTime: CMTime? = nil, failure: Error? = nil,
                       completion: @escaping (Result<Void, Error>) -> Void) {
        guard hasFrames else {
            discard(writer)
            completion(.failure(failure ?? RecordingError.noFrames))
            return
        }
        guard writer.status == .writing else {
            let error = failure ?? writer.error ?? RecordingError.writeFailed
            discard(writer)
            completion(.failure(error))
            return
        }
        input.markAsFinished()
        if let endTime, endTime.isNumeric { writer.endSession(atSourceTime: endTime) }
        writer.finishWriting {
            if writer.status == .completed {
                completion(.success(()))
            } else {
                let error = writer.error ?? failure ?? RecordingError.writeFailed
                discard(writer)
                completion(.failure(error))
            }
        }
    }

    private static func discard(_ writer: AVAssetWriter) {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: writer.outputURL)
    }
}
