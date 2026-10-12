import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var watcher: DiskWatcher!
    private let defaults = UserDefaults.standard
    private let work = DispatchQueue(label: "Ejectus.work")

    private var cleanOnEject: Bool {
        get { defaults.object(forKey: "cleanOnEject") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanOnEject") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "externaldrive.badge.checkmark",
                                           accessibilityDescription: "Ejectus")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        watcher = DiskWatcher(
            isEnabled: { [weak self] in self?.cleanOnEject ?? false },
            onCleaned: { [weak self] name, result in
                Self.log("eject", name, result)
                if result.removed > 0 || result.failed > 0 || result.spotlightLeft { self?.notify(name, result) }
            })

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        work.async { SpotlightHelper.ping() }

        if !defaults.bool(forKey: "didSetUpLoginItem") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "didSetUpLoginItem")
        }
    }

    // MARK: Services menu — Finder → right-click drive → Services → Clean Junk Files

    @objc func cleanJunk(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self],
                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let volumes = Set(urls.compactMap(Volumes.volume(containing:)))
        for volume in volumes {
            guard Volumes.isEligible(volume) else {
                notify(Volumes.name(of: volume), text: "Skipped — not an external drive")
                continue
            }
            guard !defaults.isSkipped(volume) else {
                notify(Volumes.name(of: volume), text: "Skipped — this drive is set to be skipped")
                continue
            }
            clean(volume, thenEject: false)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let drives = Volumes.eligible()
        if drives.isEmpty {
            menu.addItem(withTitle: "No external drives", action: nil, keyEquivalent: "")
        }
        for drive in drives {
            let header = menu.addItem(withTitle: Volumes.name(of: drive), action: nil, keyEquivalent: "")
            header.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
            let skipped = defaults.isSkipped(drive)
            // No plain "Clean": macOS rebuilds Spotlight/fseventsd while a drive stays mounted.
            let item = menu.addItem(withTitle: skipped ? "Eject" : "Clean & Eject",
                                    action: #selector(menuCleanAndEject(_:)), keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.representedObject = drive
            let skip = menu.addItem(withTitle: "Skip This Drive", action: #selector(toggleSkip(_:)), keyEquivalent: "")
            skip.target = self
            skip.indentationLevel = 1
            skip.representedObject = drive
            skip.state = skipped ? .on : .off
        }
        menu.addItem(.separator())

        let eject = menu.addItem(withTitle: "Clean When Ejecting", action: #selector(toggleCleanOnEject), keyEquivalent: "")
        eject.target = self
        eject.state = cleanOnEject ? .on : .off

        let trash = menu.addItem(withTitle: "Empty Drive Trash", action: #selector(toggleEmptyTrash), keyEquivalent: "")
        trash.target = self
        trash.state = defaults.emptyDriveTrash ? .on : .off

        if SpotlightHelper.isReady, !SpotlightHelper.lastCallFailed {
            menu.addItem(withTitle: "Spotlight Helper: On", action: nil, keyEquivalent: "")
        } else {
            let title = SpotlightHelper.isReady ? "Repair Spotlight Helper…" : "Set Up Spotlight Helper…"
            let helper = menu.addItem(withTitle: title, action: #selector(setUpHelper), keyEquivalent: "")
            helper.target = self
        }

        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Ejectus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func menuCleanAndEject(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? URL else { return }
        if defaults.isSkipped(drive) {
            let name = Volumes.name(of: drive)
            work.async { [self] in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: drive) }
                catch { notify(name, text: "Couldn't eject — is a file still open?") }
            }
        } else {
            clean(drive, thenEject: true)
        }
    }

    @objc private func toggleSkip(_ sender: NSMenuItem) {
        guard let drive = sender.representedObject as? URL else { return }
        defaults.setSkipped(drive, !defaults.isSkipped(drive))
    }

    @objc private func toggleCleanOnEject() { cleanOnEject.toggle() }

    @objc private func toggleEmptyTrash() { defaults.emptyDriveTrash.toggle() }

    /// Registers the root helper; macOS then needs the user to switch it on in Login Items.
    @objc private func setUpHelper() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            return notify("Ejectus", text: "Move Ejectus to Applications first, then set up the helper.")
        }
        guard let script = Bundle.main.path(forResource: "install-helper", ofType: "sh") else { return }
        work.async { [self] in
            // macOS shows its own password dialog for "with administrator privileges".
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/bin/sh \" & quoted form of \"\(script)\" with administrator privileges"]
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { return Self.log("helper", "install failed to start: \(error)") }
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                Self.log("helper", "install failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
                return
            }
            SpotlightHelper.ping()
            Self.log("helper", SpotlightHelper.lastCallFailed ? "installed but not answering" : "installed and answering")
            notify("Ejectus", text: SpotlightHelper.lastCallFailed ? "Spotlight helper installed but not answering — see log"
                                                                   : "Spotlight helper is on")
        }
    }

    @objc private func toggleLogin() {
        let app = SMAppService.mainApp
        if app.status == .enabled {
            try? app.unregister()
        } else {
            do { try app.register() } catch { Self.log("login", "register failed: \(error)") }
            // Switched off by the user in System Settings: only they can turn it back on there.
            if app.status != .enabled { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    // MARK: Work

    private func clean(_ volume: URL, thenEject: Bool) {
        let name = Volumes.name(of: volume)
        work.async { [self] in
            let result = Sweeper.fullClean(volume: volume, emptyTrash: defaults.emptyDriveTrash)
            Self.log(thenEject ? "clean & eject" : "clean", name, result)
            guard thenEject else { return notify(name, result) }
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
                notify(name, text: "\(result.summary). Ejected.")
            } catch {
                notify(name, text: "\(result.summary). Couldn't eject — is a file still open?")
            }
        }
    }

    /// Appends one entry per clean to ~/Library/Logs/Ejectus.log (kept under ~200 KB).
    private static func log(_ trigger: String, _ name: String, _ result: SweepResult) {
        var entry = "\(Date()) [\(trigger)] \(name): \(result.summary)\n"
        for error in result.errors { entry += "    \(error)\n" }
        log(entry)
    }

    private static func log(_ trigger: String, _ message: String) {
        log("\(Date()) [\(trigger)] \(message)\n")
    }

    private static func log(_ entry: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ejectus.log")
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 200_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
    }

    private func notify(_ name: String, _ result: SweepResult) {
        notify(name, text: result.summary)
    }

    private func notify(_ name: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

extension UserDefaults {
    /// Whether cleaning empties the drive's own Trash (.Trashes). On by default.
    var emptyDriveTrash: Bool {
        get { object(forKey: "emptyDriveTrash") as? Bool ?? true }
        set { set(newValue, forKey: "emptyDriveTrash") }
    }

    /// Drives the user chose never to clean (by volume UUID).
    func isSkipped(_ volume: URL) -> Bool {
        (stringArray(forKey: "skippedDrives") ?? []).contains(Volumes.id(of: volume))
    }

    func setSkipped(_ volume: URL, _ skip: Bool) {
        var ids = Set(stringArray(forKey: "skippedDrives") ?? [])
        if skip { ids.insert(Volumes.id(of: volume)) } else { ids.remove(Volumes.id(of: volume)) }
        set(Array(ids), forKey: "skippedDrives")
    }
}
