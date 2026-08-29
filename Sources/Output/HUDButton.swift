import AppKit

/// 어두운 HUD 표면 위에 얹는 버튼. 아이콘 · 제목 · 키캡(단축키 칩)을 직접 그려
/// 마우스 없이도 쓸 수 있음을 알리고, 호버/누름 상태를 명확히 구분한다.
final class HUDButton: NSButton {
    enum Role {
        /// 브랜드 레드 채움. HUD당 하나(기본 동작).
        case primary
        /// 밝은 반투명 채움 + 테두리.
        case secondary
        /// 채움 없이 텍스트만. 호버 시에만 옅게 떠오른다(취소 등 조용한 동작).
        case tertiary
        case destructive
    }

    private let role: Role
    private var symbolImage: NSImage?
    private var hovering = false {
        didSet { needsDisplay = true }
    }

    /// 제목 오른쪽에 붙는 키캡(예: "⏎", "R", "Esc").
    var keyHint: String? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let iconPointSize: CGFloat = 13
    private let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private let keycapFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private let horizontalPadding: CGFloat = 14
    private let iconGap: CGFloat = 6
    private let keycapGap: CGFloat = 9
    private let keycapPadX: CGFloat = 5
    private let keycapHeight: CGFloat = 17

    init(title: String,
         role: Role = .secondary,
         symbol: String? = nil,
         keyHint: String? = nil,
         target: AnyObject? = nil,
         action: Selector? = nil) {
        self.role = role
        self.keyHint = keyHint
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = Brand.innerCornerRadius
        layer?.masksToBounds = true
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: iconPointSize, weight: .semibold)
            symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
        }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        self.role = .secondary
        super.init(coder: coder)
        isBordered = false
        wantsLayer = true
    }

    override var title: String {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// 채움·글자색을 지정한 그대로 그린다(재질과의 vibrancy 블렌딩 제외).
    override var allowsVibrancy: Bool { false }

    override var intrinsicContentSize: NSSize {
        var width = horizontalPadding * 2 + titleSize.width
        if symbolImage != nil { width += iconPointSize + 1 + iconGap }
        if let keycap = keycapSize { width += keycapGap + keycap.width }
        return NSSize(width: ceil(width), height: 36)
    }

    // MARK: 상태 추적

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: Brand.innerCornerRadius, yRadius: Brand.innerCornerRadius)

        if let fill = fillColor {
            fill.setFill()
            path.fill()
        }
        if let border = borderColor {
            border.setStroke()
            let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
            NSBezierPath(roundedRect: inset, xRadius: Brand.innerCornerRadius - 0.5, yRadius: Brand.innerCornerRadius - 0.5)
                .stroke()
        }

        // 내용은 가운데 정렬: [아이콘] [제목] [키캡]
        let contentWidth = intrinsicContentSize.width - horizontalPadding * 2
        var x = (bounds.width - contentWidth) / 2
        let textColor = foregroundColor

        if let symbolImage {
            let side = iconPointSize + 1
            let iconRect = CGRect(x: x, y: (bounds.height - side) / 2, width: side, height: side).integral
            let tinted = symbolImage.tinted(with: textColor)
            tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: true, hints: nil)
            x += side + iconGap
        }

        let titleAttributes: [NSAttributedString.Key: Any] = [.font: titleFont, .foregroundColor: textColor]
        let size = titleSize
        (title as NSString).draw(at: CGPoint(x: x, y: (bounds.height - size.height) / 2),
                                 withAttributes: titleAttributes)
        x += size.width

        if let keyHint, let keycap = keycapSize {
            x += keycapGap
            let chip = CGRect(x: x, y: (bounds.height - keycapHeight) / 2, width: keycap.width, height: keycapHeight)
            keycapBackground.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 4.5, yRadius: 4.5).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: keycapFont,
                .foregroundColor: textColor.withAlphaComponent(0.92)
            ]
            let textSize = (keyHint as NSString).size(withAttributes: attributes)
            (keyHint as NSString).draw(at: CGPoint(x: chip.midX - textSize.width / 2,
                                                   y: chip.midY - textSize.height / 2),
                                       withAttributes: attributes)
        }
    }

    private var titleSize: NSSize {
        (title as NSString).size(withAttributes: [.font: titleFont])
    }

    private var keycapSize: NSSize? {
        guard let keyHint, !keyHint.isEmpty else { return nil }
        let text = (keyHint as NSString).size(withAttributes: [.font: keycapFont])
        return NSSize(width: max(keycapHeight, ceil(text.width) + keycapPadX * 2), height: keycapHeight)
    }

    private var foregroundColor: NSColor {
        guard isEnabled else { return NSColor.white.withAlphaComponent(0.4) }
        switch role {
        case .primary, .destructive: return .white
        case .secondary: return .white
        case .tertiary: return NSColor.white.withAlphaComponent(hovering || isHighlighted ? 1 : 0.78)
        }
    }

    private var fillColor: NSColor? {
        let pressed = isHighlighted
        switch role {
        case .primary:
            let base = Brand.red
            if !isEnabled { return base.withAlphaComponent(0.35) }
            if pressed { return base.blended(withFraction: 0.18, of: .black) ?? base }
            if hovering { return base.blended(withFraction: 0.10, of: .white) ?? base }
            return base
        case .destructive:
            let base = NSColor(srgbRed: 0.72, green: 0.15, blue: 0.14, alpha: 1)
            if pressed { return base.blended(withFraction: 0.18, of: .black) ?? base }
            if hovering { return base.blended(withFraction: 0.10, of: .white) ?? base }
            return base
        case .secondary:
            if !isEnabled { return NSColor.white.withAlphaComponent(0.05) }
            if pressed { return NSColor.white.withAlphaComponent(0.22) }
            if hovering { return NSColor.white.withAlphaComponent(0.17) }
            return NSColor.white.withAlphaComponent(0.11)
        case .tertiary:
            if pressed { return NSColor.white.withAlphaComponent(0.14) }
            if hovering { return NSColor.white.withAlphaComponent(0.08) }
            return nil
        }
    }

    private var borderColor: NSColor? {
        switch role {
        case .primary, .destructive:
            return NSColor.white.withAlphaComponent(hovering ? 0.30 : 0.18)
        case .secondary:
            return NSColor.white.withAlphaComponent(hovering ? 0.28 : 0.16)
        case .tertiary:
            return nil
        }
    }

    private var keycapBackground: NSColor {
        switch role {
        case .primary, .destructive: return NSColor.black.withAlphaComponent(0.26)
        case .secondary, .tertiary: return NSColor.white.withAlphaComponent(0.14)
        }
    }
}

private extension NSImage {
    /// 템플릿 심볼을 지정 색으로 채운 사본.
    func tinted(with color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
