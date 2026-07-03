import AppKit

/// Shared chrome for the floating HUD family (control strips, toasts, QAO
/// cards) — one radius, material and border so every overlay reads as the
/// same app.
@MainActor
enum HUDStyle {
    static let cornerRadius: CGFloat = 12
    static let borderColour = NSColor.white.withAlphaComponent(0.12)

    /// The Sentry accent (brand/tokens.css): one warm amber does "live /
    /// selected / now" across our custom-drawn chrome. Native controls
    /// (buttons, checkboxes) keep the system accent — brand rides the custom
    /// surfaces, not the AppKit ones.
    static let accent = NSColor(
        srgbRed: 0xE8 / 255, green: 0xA9 / 255, blue: 0x6A / 255, alpha: 1)   // --accent-bright
    static let accentDeep = NSColor(
        srgbRed: 0x8A / 255, green: 0x5A / 255, blue: 0x2A / 255, alpha: 1)   // --accent (fills)
    static let accentSoft = NSColor(
        srgbRed: 0xE8 / 255, green: 0xA9 / 255, blue: 0x6A / 255, alpha: 0.14)

    /// Editor chrome surface (matches sentry-finder's Theme): warm near-black
    /// tint washed over a behind-window blur; hairlines are white at 6%.
    static let editorTint = NSColor(
        srgbRed: 0x0D / 255, green: 0x0D / 255, blue: 0x10 / 255, alpha: 1)
    static let hairline = NSColor.white.withAlphaComponent(0.06)

    /// The sentry-finder chrome base: behind-window blur + editorTint wash.
    /// Native controls placed over it (under .darkAqua) pick up the dark
    /// translucent look without any custom drawing.
    static func tintedBlurCanvas(tintAlpha: CGFloat = 0.72) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = editorTint.withAlphaComponent(tintAlpha).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(tint)
        NSLayoutConstraint.activate([
            tint.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            tint.topAnchor.constraint(equalTo: effect.topAnchor),
            tint.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    static func card(appearance: NSAppearance.Name? = nil) -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.material = .hudWindow
        card.state = .active
        if let appearance { card.appearance = NSAppearance(named: appearance) }
        card.wantsLayer = true
        card.layer?.cornerRadius = cornerRadius
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = borderColour.cgColor
        return card
    }
}

/// Small transient pill HUD ("Text copied", errors). Non-activating, floats
/// over everything, fades out on its own.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var dismissTask: Task<Void, Never>?

    static func show(_ text: String, symbol: String? = nil, duration: TimeInterval = 1.6) {
        dismissTask?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.contentTintColor = .white
            stack.addArrangedSubview(icon)
        }
        stack.addArrangedSubview(label)

        let container = HUDStyle.card()
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor

        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let size = stack.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.12
        )

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = container
        p.alphaValue = 0
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 1
        }

        panel = p
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    p.orderOut(nil)
                    if panel === p { panel = nil }
                }
            })
        }
    }
}
