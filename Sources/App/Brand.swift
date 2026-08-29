import AppKit

/// Open Capture Record 브랜드 상수.
enum Brand {
    static let name = "Open Capture Record"
    static let tagline = "빠르고 정밀한 화면 캡처"

    /// 브랜드 레드. 캡처 프레임과 주요 동작에만 쓰는 단일 강조색이다.
    static let red = NSColor(srgbRed: 0.88, green: 0.20, blue: 0.18, alpha: 1)
    static let darkSurface = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.12, alpha: 1)
    static let darkRaisedSurface = NSColor(srgbRed: 0.17, green: 0.18, blue: 0.20, alpha: 1)

    /// 모든 커스텀 표면이 공유하는 모서리 규칙.
    static let cornerRadius: CGFloat = 12

    /// 저장 폴더 이름 (Application Support 또는 레거시 바탕화면 하위).
    static let folderName = "oh-my-opensnap"
}
