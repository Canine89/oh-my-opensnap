import CoreGraphics

/// 선택 영역이 바뀌면서 디밍의 유무가 달라진 부분만 반환한다.
/// 공통 내부 영역은 그대로이므로 다시 그릴 필요가 없다.
enum SelectionDamage {
    static func rectangles(from old: CGRect, to new: CGRect) -> [CGRect] {
        difference(old, subtracting: new) + difference(new, subtracting: old)
    }

    private static func difference(_ rect: CGRect, subtracting other: CGRect) -> [CGRect] {
        guard !rect.isEmpty else { return [] }
        let overlap = rect.intersection(other)
        guard !overlap.isEmpty else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height)
        ].filter { !$0.isEmpty }
    }
}
