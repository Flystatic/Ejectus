import AppKit
import ServiceManagement

/// Checklist of the three things macOS makes the user approve. Ticks update live while the
/// window is open, since the user flips switches over in System Settings.
final class SetupWindowController: NSWindowController, NSWindowDelegate {
    private struct Step {
        let title: String
        let detail: String
        let buttonTitle: String
        let isDone: () -> Bool
        let action: () -> Void
    }

    private var steps: [Step] = []
    private var rows: [(icon: NSImageView, button: NSButton)] = []
    private var timer: Timer?
    var onClose: (() -> Void)?

    /// Full Disk Access can't be queried directly; reading a file only it unlocks is the usual test.
    static var hasFullDiskAccess: Bool {
        for path in ["/Library/Application Support/com.apple.TCC/TCC.db",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari").path] {
            let fd = open(path, O_RDONLY)
            if fd >= 0 { Darwin.close(fd); return true }
        }
        return false
    }

    static var helperReady: Bool { SpotlightHelper.isReady && !SpotlightHelper.lastCallFailed }
    static var startsAtLogin: Bool { SMAppService.mainApp.status == .enabled }
    static var isComplete: Bool { hasFullDiskAccess && helperReady && startsAtLogin }

    init(installHelper: @escaping () -> Void, turnOnLogin: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Set Up Ejectus"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        steps = [
            Step(title: "Full Disk Access",
                 detail: "Lets Ejectus remove the .Trashes and .TemporaryItems folders macOS locks. "
                     + "In Settings, click +, choose Ejectus in Applications, and switch it on.",
                 buttonTitle: "Open Settings",
                 isDone: { Self.hasFullDiskAccess },
                 action: {
                     NSWorkspace.shared.open(URL(string:
                         "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                 }),
            Step(title: "Spotlight helper",
                 detail: "Removes the locked .Spotlight-V100 folder. Asks for your password once.",
                 buttonTitle: "Install",
                 isDone: { Self.helperReady },
                 action: installHelper),
            Step(title: "Start at login",
                 detail: "Keeps Ejectus running, so drives get cleaned whenever you eject them.",
                 buttonTitle: "Turn On",
                 isDone: { Self.startsAtLogin },
                 action: turnOnLogin),
        ]
        buildLayout()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func present() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        onClose?()
    }

    private func buildLayout() {
        let intro = NSTextField(wrappingLabelWithString:
            "macOS needs you to approve three things. Click each button, then come back here. "
            + "The ticks update by themselves.")
        intro.preferredMaxLayoutWidth = 480

        let stack = NSStackView(views: [intro])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)

        for (index, step) in steps.enumerated() {
            let icon = NSImageView()
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            icon.setContentHuggingPriority(.required, for: .horizontal)

            let title = NSTextField(labelWithString: step.title)
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let detail = NSTextField(wrappingLabelWithString: step.detail)
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 320
            let text = NSStackView(views: [title, detail])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 2

            let button = NSButton(title: step.buttonTitle, target: self, action: #selector(stepButton(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView(views: [icon, text, NSView(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.widthAnchor.constraint(equalToConstant: 492).isActive = true
            stack.addArrangedSubview(row)
            rows.append((icon, button))
        }

        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), done])
        footer.widthAnchor.constraint(equalToConstant: 492).isActive = true
        stack.addArrangedSubview(footer)

        window?.contentView = stack
    }

    private func refresh() {
        for (step, row) in zip(steps, rows) {
            let done = step.isDone()
            row.icon.image = NSImage(systemSymbolName: done ? "checkmark.circle.fill" : "circle",
                                     accessibilityDescription: done ? "Done" : "To do")
            row.icon.contentTintColor = done ? .systemGreen : .tertiaryLabelColor
            row.button.isHidden = done
        }
    }

    @objc private func stepButton(_ sender: NSButton) {
        steps[sender.tag].action()
    }

    @objc private func closeWindow() { window?.close() }
}
