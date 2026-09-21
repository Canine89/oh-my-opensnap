import CoreGraphics

/// 생성하는 호출 스택에서 바로 화면 확보를 요청한다. Task 스케줄링이나
/// 창 목록 조회를 기다리는 사이 메뉴의 강조가 바뀌는 시간을 줄인다.
struct DisplaySnapshotRequest {
    private let result: AsyncThrowingStream<DisplaySnapshot, Error>

    init(scale: CGFloat,
         capture: (@escaping @Sendable (CGImage?, Error?) -> Void) -> Void) {
        let pair = AsyncThrowingStream<DisplaySnapshot, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        result = pair.stream
        capture { image, error in
            if let error {
                pair.continuation.finish(throwing: error)
            } else if let image {
                pair.continuation.yield(DisplaySnapshot(image: image, scale: scale))
                pair.continuation.finish()
            } else {
                pair.continuation.finish(throwing: SnapshotError.noImage)
            }
        }
    }

    func value() async throws -> DisplaySnapshot {
        for try await snapshot in result { return snapshot }
        throw SnapshotError.noImage
    }

    private enum SnapshotError: Error { case noImage }
}
