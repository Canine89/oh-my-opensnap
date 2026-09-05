import AVFoundation

enum VideoWriterFinalizer {
    /// 호출자는 프레임 큐를 정지시킨 뒤 호출한다. 완료 콜백 자체가 성공을 뜻하지 않는다.
    static func finish(writer: AVAssetWriter, input: AVAssetWriterInput, hasFrames: Bool,
                       failure: Error? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        guard hasFrames else {
            writer.cancelWriting()
            completion(.failure(failure ?? RecordingError.noFrames))
            return
        }
        guard writer.status == .writing else {
            completion(.failure(failure ?? writer.error ?? RecordingError.writeFailed))
            return
        }
        input.markAsFinished()
        writer.finishWriting {
            if let failure { completion(.failure(failure)) }
            else if writer.status == .completed { completion(.success(())) }
            else { completion(.failure(writer.error ?? RecordingError.writeFailed)) }
        }
    }
}
