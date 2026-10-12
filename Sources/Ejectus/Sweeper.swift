import Foundation

struct SweepResult {
    var removed = 0
    var bytes: Int64 = 0
    var failed = 0
    var timedOut = false
    var spotlightLeft = false
    var errors: [String] = []  // first few failures, for the log
    var unreadable = false     // couldn't even list the drive

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var s = removed == 0 ? "Already clean" : "Removed \(removed) junk item\(removed == 1 ? "" : "s") (\(size))"
        if failed > 0 { s += ", \(failed) couldn't be removed" }
        if timedOut { s += ", stopped early (time limit)" }
        if spotlightLeft {
            s += SpotlightHelper.isReady ? ". Spotlight folder couldn't be removed (see log)"
                                         : ". Spotlight folder needs the helper (see menu)"
        }
        if unreadable { s = "Couldn't read the drive — see ~/Library/Logs/Ejectus.log" }
        return s
    }
}

enum Sweeper {
    /// Folders/files removed only when they sit at the top of the volume.
    /// (.Spotlight-V100 is locked by macOS; SpotlightHelper removes it as root.)
    static let rootJunk: Set<String> = [
        ".fseventsd", ".Trashes", ".TemporaryItems",
        ".DocumentRevisions-V100", ".apdisk",
    ]

    /// Files removed anywhere on the volume.
    static func isJunkFile(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    /// Uses fts + unlink rather than FileManager: Foundation hides "._" files from every
    /// listing, so it can neither find them nor empty a folder that contains them.
    ///
    /// Every entry is judged on its own path — no "currently deleting" state. (An earlier
    /// version tracked state and, when a junk folder couldn't be read, never left
    /// delete mode and wiped the rest of the drive.)
    static func clean(volume root: URL, deadline: Date = .distantFuture, emptyTrash: Bool = true) -> SweepResult {
        var result = SweepResult()
        let rootPath = root.standardizedFileURL.path
        let junkRoots = rootJunk.subtracting(emptyTrash ? [] : [".Trashes"]).map { (rootPath as NSString).appendingPathComponent($0) }

        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
        defer { free(argv[0]) }
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return result }
        defer { fts_close(fts) }

        func noteError(_ path: String, _ code: Int32) {
            if result.errors.count < 20 { result.errors.append("\(path): \(String(cString: strerror(code)))") }
        }

        while let entry = fts_read(fts) {
            if Date() > deadline { result.timedOut = true; break }
            let e = entry.pointee
            let info = Int32(e.fts_info)
            let path = String(cString: e.fts_path)
            let isTopLevel = e.fts_level == 1
            let size = Int64(e.fts_statp?.pointee.st_blocks ?? 0) * 512

            // The volume itself unreadable (e.g. macOS privacy block): nothing else will be visited.
            if e.fts_level == 0, info == FTS_DNR || info == FTS_ERR {
                noteError(path, e.fts_errno)
                result.failed += 1
                result.unreadable = true
                continue
            }

            // Left alone entirely: Spotlight (the helper handles it) and, if kept, the drive's Trash.
            if isTopLevel, info == FTS_D,
               path.hasSuffix("/.Spotlight-V100") || (!emptyTrash && path.hasSuffix("/.Trashes")) {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }

            if junkRoots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                switch info {
                case FTS_D:
                    break  // handled on the post-order (FTS_DP) visit, once emptied
                case FTS_DP:
                    let ok = rmdir(path) == 0
                    let gone = !ok && errno == ENOENT  // already removed by someone else: not a failure
                    if !ok, !gone, isTopLevel { noteError(path, errno) }
                    if isTopLevel, !gone { if ok { result.removed += 1 } else { result.failed += 1 } }
                case FTS_DNR, FTS_ERR, FTS_NS:
                    if isTopLevel { noteError(path, e.fts_errno); result.failed += 1 }
                default:
                    let ok = unlink(path) == 0
                    if ok { result.bytes += size } else if errno != ENOENT { noteError(path, errno) }
                    if isTopLevel { if ok { result.removed += 1 } else { result.failed += 1 } }
                }
            } else if info == FTS_F, isJunkFile((path as NSString).lastPathComponent) {
                if unlink(path) == 0 {
                    result.removed += 1
                    result.bytes += size
                } else if errno != ENOENT {  // ENOENT: "._x" already went away with its partner file
                    noteError(path, errno)
                    result.failed += 1
                }
            }
        }
        return result
    }
}
