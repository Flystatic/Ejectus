import Foundation

/// macOS locks `.Spotlight-V100`; only root can remove it (via `mdutil -X`).
/// A copy of this binary is installed once (admin password) as a classic launchd daemon in
/// /Library/PrivilegedHelperTools and run with `--helper`. Its only ability: run `mdutil -X` on a
/// verified external volume. It never deletes files itself. Being a separate copy, app updates
/// don't break it (SMAppService daemons stop launching when a non-Developer-ID app is updated).
@objc protocol SpotlightHelperProtocol {
    func removeSpotlightIndex(atPath path: String, reply: @escaping (Bool, String) -> Void)
}

enum SpotlightHelper {
    static let label = "local.ejectus.privhelper"
    static let installedBinary = "/Library/PrivilegedHelperTools/\(label)"
    static let installedPlist = "/Library/LaunchDaemons/\(label).plist"

    static var isReady: Bool {
        FileManager.default.fileExists(atPath: installedBinary) && FileManager.default.fileExists(atPath: installedPlist)
    }

    /// Set when an installed helper didn't answer. The menu then offers to repair it.
    static var lastCallFailed = false

    // MARK: Client (app side)

    /// Removes the volume's Spotlight folder via the helper. Returns nil if there was nothing
    /// to remove, otherwise success plus a reason for the log when it failed.
    static func removeIndex(on volume: URL, timeout: TimeInterval = 30) -> (ok: Bool, detail: String)? {  // big drives can take a while
        let spotlight = volume.appendingPathComponent(".Spotlight-V100").path
        guard FileManager.default.fileExists(atPath: spotlight) else { return nil }
        guard isReady else { return (false, "helper not installed") }

        var (ok, detail) = call(path: volume.standardizedFileURL.path, timeout: timeout)
        let gone = !FileManager.default.fileExists(atPath: spotlight)
        if ok, !gone { detail = "helper ran (\(detail)) but the folder is still there" }
        return (ok && gone, detail)
    }

    /// Checks the helper answers at all (a refused path gets an instant reply). Run at launch.
    static func ping() {
        guard isReady else { return }
        _ = call(path: "/Volumes/.ejectus-ping", timeout: 5)
    }

    private static func call(path: String, timeout: TimeInterval) -> (ok: Bool, detail: String) {
        let connection = NSXPCConnection(machServiceName: label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SpotlightHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let done = DispatchSemaphore(value: 0)
        var ok = false
        var detail = "no reply from helper"
        var answered = false
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            detail = "helper connection failed: \(error.localizedDescription)"
            done.signal()
        }
        (proxy as? SpotlightHelperProtocol)?.removeSpotlightIndex(atPath: path) { success, message in
            ok = success
            detail = message
            answered = true
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut { detail = "helper timed out" }
        lastCallFailed = !answered
        return (ok, detail)
    }

    // MARK: Server (root daemon side)

    static func runDaemon() -> Never {
        let listener = NSXPCListener(machServiceName: label)
        let server = Server()
        listener.delegate = server
        listener.resume()
        server.scheduleIdleExit()
        RunLoop.main.run()
        exit(0)
    }

    /// Strict check the root side applies before acting: the path must be exactly the mount
    /// point of a local, writable, non-root volume under /Volumes that the app would clean.
    static func isSafeMountPoint(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), !path.contains("/../"), !path.hasSuffix("/..") else { return false }
        var st = statfs()
        guard statfs(path, &st) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &st.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let flags = UInt32(st.f_flags)
        guard mountedOn == path,
              flags & UInt32(MNT_LOCAL) != 0,
              flags & UInt32(MNT_ROOTFS) == 0,
              flags & UInt32(MNT_RDONLY) == 0
        else { return false }
        return Volumes.isEligible(URL(fileURLWithPath: path))
    }

    private final class Server: NSObject, NSXPCListenerDelegate, SpotlightHelperProtocol {
        /// Quit after 60 s with no requests. launchd relaunches on demand, so after an app
        /// update the next request runs the new binary instead of a stale copy.
        private var idleTimer: Timer?

        func scheduleIdleExit() {
            DispatchQueue.main.async {
                self.idleTimer?.invalidate()
                self.idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in exit(0) }
            }
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
            c.setCodeSigningRequirement("identifier \"local.ejectus\"")
            c.exportedInterface = NSXPCInterface(with: SpotlightHelperProtocol.self)
            c.exportedObject = self
            c.resume()
            return true
        }

        func removeSpotlightIndex(atPath path: String, reply: @escaping (Bool, String) -> Void) {
            scheduleIdleExit()  // don't time out mid-request
            defer { scheduleIdleExit() }
            guard SpotlightHelper.isSafeMountPoint(path) else { return reply(false, "Refused: \(path)") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
            p.arguments = ["-X", path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
                reply(p.terminationStatus == 0, "mdutil exit \(p.terminationStatus)")
            } catch {
                reply(false, "\(error)")
            }
        }
    }
}

extension Sweeper {
    /// Everything: Spotlight folder via the helper, then the normal sweep.
    static func fullClean(volume: URL, deadline: Date = .distantFuture, emptyTrash: Bool = true) -> SweepResult {
        var result = clean(volume: volume, deadline: deadline, emptyTrash: emptyTrash)
        if let (ok, detail) = SpotlightHelper.removeIndex(on: volume) {
            if ok {
                result.removed += 1
            } else {
                result.spotlightLeft = true
                result.errors.append("\(volume.path)/.Spotlight-V100: \(detail)")
            }
        }
        return result
    }
}
