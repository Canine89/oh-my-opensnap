import AppKit

/// 기능과 분리된 앱 공통 시각 언어.
/// 단일 강조색, 12pt 표면, 시스템 재질을 사용해 창과 HUD의 결을 맞춘다.
enum AppAppearance {
    static func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
    }

    static func title(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .labelColor
        return label
    }

    static func sectionTitle(_ string: String) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    static func secondaryText(_ string: String, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        return label
    }

    static func makeSection(title: String, subtitle: String? = nil, views: [NSView]) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = Brand.cornerRadius
        card.layer?.masksToBounds = true
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        card.layer?.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 15, bottom: 14, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(sectionTitle(title))
        if let subtitle {
            let label = secondaryText(subtitle)
            stack.addArrangedSubview(label)
        }
        views.forEach(stack.addArrangedSubview)
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    static func accentButton(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .regular
        if #available(macOS 11.0, *) { button.bezelColor = Brand.red }
    }
}
