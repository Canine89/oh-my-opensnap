import AppKit

/// 어두운 HUD 표면 위에 얹는 알약형 버튼. 아이콘·키 힌트를 함께 그려 마우스 없이도 쓸 수 있음을 알린다.
final class HUDButton: NSButton {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    private let role: Role
    /// 제목 오른쪽에 흐리게 붙는 키 힌트(예: "⏎", "R").
    var keyHint: String? {
        didSet { updateTitle() }
    }

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
        wantsLayer = true
        layer?.cornerRadius = Brand.innerCornerRadius
        layer?.masksToBounds = true
        if let symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            imagePosition = .imageLeading
            imageHugsTitle = true
            contentTintColor = .white
        }
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        self.role = .secondary
        super.init(coder: coder)
        isBordered = false
        wantsLayer = true
        updateAppearance()
    }

    override var title: String {
        didSet { updateTitle() }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private func updateAppearance() {
        let base = color
        let alpha: CGFloat
        if !isEnabled {
            alpha = 0.28
        } else if isHighlighted {
            alpha = 0.72
        } else {
            alpha = 1
        }
        layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isHighlighted ? 0.30 : 0.18).cgColor
        layer?.borderWidth = 1
        contentTintColor = isEnabled ? .white : NSColor.white.withAlphaComponent(0.55)
        updateTitle()
    }

    private func updateTitle() {
        let textColor = isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.55)
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: textColor
        ])
        if let keyHint, !keyHint.isEmpty {
            text.append(NSAttributedString(string: "  \(keyHint)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: textColor.withAlphaComponent(0.62)
            ]))
        }
        attributedTitle = text
    }

    private var color: NSColor {
        switch role {
        case .primary:
            return Brand.red
        case .secondary:
            return Brand.darkRaisedSurface
        case .destructive:
            return NSColor(srgbRed: 0.72, green: 0.15, blue: 0.14, alpha: 1)
        }
    }
}
