import AppKit

final class HUDButton: NSButton {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    private let role: Role

    init(title: String, role: Role = .secondary, target: AnyObject? = nil, action: Selector? = nil) {
        self.role = role
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
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
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1
        updateTitle()
    }

    private func updateTitle() {
        let textColor = isEnabled ? NSColor.white : NSColor.white.withAlphaComponent(0.55)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: textColor
        ])
    }

    private var color: NSColor {
        switch role {
        case .primary:
            return .systemBlue
        case .secondary:
            return NSColor(calibratedWhite: 0.22, alpha: 1)
        case .destructive:
            return .systemRed
        }
    }
}
