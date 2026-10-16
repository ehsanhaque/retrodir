import AppKit

/// Copy / move / delete jobs running on a background thread with a progress dialog.
final class FileJob {
    enum Op { case copy, move, trash, delete }

    let op: Op
    let items: [URL]
    let dest: URL?
    unowned let app: Commander
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    // Progress (guarded by lock)
    private var curName = ""
    private var curTo = ""
    private var fileDone: Int64 = 0
    private var fileSize: Int64 = 0
    private var totalDone: Int64 = 0
    private var totalSize: Int64 = 0
    private var filesDone = 0
    private var filesTotal = 0
    private var scanning = false
    private let startTime = Date()

    private var overwriteAll: Bool?    // true = overwrite all, false = skip all
    private var skipAllErrors = false
    var errors: [String] = []
    var completed: [URL] = []          // top-level items fully processed
    var completion: ((FileJob) -> Void)?
    private var progress: ProgressLayer?

    init(app: Commander, op: Op, items: [URL], dest: URL?) {
        self.app = app
        self.op = op
        self.items = items
        self.dest = dest
    }

    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    func setFileDone(_ n: Int64) { lock.lock(); fileDone = n; lock.unlock() }

    private func update(_ f: () -> Void) { lock.lock(); f(); lock.unlock() }

    func start() {
        let title: String
        switch op {
        case .copy: title = "Copy"
        case .move: title = "Move"
        case .trash: title = "Move to Trash"
        case .delete: title = "Delete"
        }
        let p = ProgressLayer(app: app, title: title, provider: { [unowned self] in self.snapshot() }, onCancel: { [unowned self] in self.cancel() })
        progress = p
        app.push(p)
        app.activeJobs += 1
        Thread.detachNewThread { [self] in
            self.run()
            DispatchQueue.main.async {
                self.app.activeJobs -= 1
                if let p = self.progress { self.app.pop(p) }
                self.completion?(self)
                if !self.errors.isEmpty && !self.isCancelled {
                    self.app.message("Errors", self.errors.prefix(8).joined(separator: "\n") + (self.errors.count > 8 ? "\n… and \(self.errors.count - 8) more" : ""), error: true)
                }
            }
        }
    }

    private func snapshot() -> (lines: [String], file: Double?, total: Double?, footer: String) {
        lock.lock(); defer { lock.unlock() }
        let elapsed = max(0.1, Date().timeIntervalSince(startTime))
        switch op {
        case .copy, .move:
            if scanning { return (["Scanning…", curName], nil, nil, "\(filesTotal) files, \(humanSize(totalSize))") }
            let speed = Double(totalDone + fileDone) / elapsed
            let ff = fileSize > 0 ? Double(fileDone) / Double(fileSize) : 0
            let tf = totalSize > 0 ? Double(totalDone + fileDone) / Double(totalSize) : Double(filesDone) / Double(max(1, filesTotal))
            return ([op == .copy ? "Copying" : "Moving", curName, "to", curTo], ff, tf,
                    "\(filesDone) of \(filesTotal) files · \(humanSize(totalDone + fileDone)) of \(humanSize(totalSize)) · \(humanSize(Int64(speed)))/s")
        case .trash, .delete:
            return ([op == .trash ? "Moving to Trash" : "Deleting", curName], nil, Double(filesDone) / Double(max(1, filesTotal)),
                    "\(filesDone) of \(filesTotal) items")
        }
    }

    // MARK: - Interaction from the worker thread

    /// Shows a dialog on the main thread and blocks the worker until the user answers.
    func ask(_ title: String, _ text: String, _ buttons: [String], error: Bool = false) -> Int? {
        let sem = DispatchSemaphore(value: 0)
        var result: Int?
        DispatchQueue.main.async {
            self.app.message(title, text, error: error, buttons: buttons) { r in result = r; sem.signal() }
        }
        sem.wait()
        return result
    }

    /// Returns true to retry, false to skip; cancels the job when asked to.
    private func handleError(_ what: String, _ path: String, _ err: String) -> Bool {
        if skipAllErrors { errors.append("\(what) \(path): \(err)"); return false }
        let r = ask("Error", "\(what) failed:\n\(path)\n\n\(err)", ["Retry", "Skip", "Skip all", "Cancel"], error: true)
        switch r {
        case 0: return true
        case 1: errors.append("\(what) \(path): \(err)"); return false
        case 2: skipAllErrors = true; errors.append("\(what) \(path): \(err)"); return false
        default: cancel(); return false
        }
    }

    /// Returns true if the destination should be overwritten.
    private func confirmOverwrite(_ src: String, _ dst: String) -> Bool {
        if let a = overwriteAll { return a }
        var s1 = stat(), s2 = stat()
        lstat(src, &s1); lstat(dst, &s2)
        let d1 = longFmt.string(from: Date(timeIntervalSince1970: TimeInterval(s1.st_mtimespec.tv_sec)))
        let d2 = longFmt.string(from: Date(timeIntervalSince1970: TimeInterval(s2.st_mtimespec.tv_sec)))
        let text = "File already exists:\n\(abbreviatePath(dst))\n\nNew:      \(grouped(Int64(s1.st_size))) bytes  \(d1)\nExisting: \(grouped(Int64(s2.st_size))) bytes  \(d2)"
        let r = ask("Warning", text, ["Overwrite", "All", "Skip", "Skip all", "Newer", "Cancel"], error: true)
        switch r {
        case 0: return true
        case 1: overwriteAll = true; return true
        case 2: return false
        case 3: overwriteAll = false; return false
        case 4: return s1.st_mtimespec.tv_sec > s2.st_mtimespec.tv_sec
        default: cancel(); return false
        }
    }

    // MARK: - Worker

    private func run() {
        switch op {
        case .trash, .delete: runDelete()
        case .copy, .move: runCopyMove()
        }
    }

    private func runDelete() {
        update { filesTotal = items.count }
        for u in items {
            if isCancelled { return }
            update { curName = abbreviatePath(u.path) }
            while true {
                do {
                    if op == .trash {
                        try FileManager.default.trashItem(at: u, resultingItemURL: nil)
                    } else {
                        try FileManager.default.removeItem(at: u)
                    }
                    completed.append(u)
                    break
                } catch {
                    if !handleError(op == .trash ? "Move to Trash" : "Delete", u.path, error.localizedDescription) { break }
                }
            }
            update { filesDone += 1 }
        }
    }

    private func targetFor(_ src: URL) -> URL {
        guard let d = dest else { return src }
        var isDir: ObjCBool = false
        if items.count == 1 && !(FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir) && isDir.boolValue) {
            return d   // explicit new name
        }
        return d.appendingPathComponent(src.lastPathComponent)
    }

    private func scan(_ url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            update { curName = abbreviatePath(url.path) }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for n in names { if isCancelled { return }; scan(url.appendingPathComponent(n)) }
        } else {
            update { filesTotal += 1; totalSize += Int64(st.st_size) }
        }
    }

    private func runCopyMove() {
        // Fast path for moves: rename within the same volume.
        var needCopy: [URL] = []
        if op == .move {
            update { filesTotal = items.count }
            for src in items {
                if isCancelled { return }
                let dst = targetFor(src)
                if dst.path == src.path { continue }
                if dst.path.hasPrefix(src.path + "/") {
                    errors.append("Cannot move \(src.lastPathComponent) into itself"); continue
                }
                update { curName = src.lastPathComponent; curTo = abbreviatePath(dst.deletingLastPathComponent().path) }
                var st = stat()
                let exists = lstat(dst.path, &st) == 0
                let caseRename = exists && src.path.lowercased() == dst.path.lowercased()
                if exists && !caseRename {
                    if (st.st_mode & S_IFMT) == S_IFDIR && isDirectory(src) {
                        needCopy.append(src); continue   // merge folders via copy+delete
                    }
                    if !confirmOverwrite(src.path, dst.path) { continue }
                    if isCancelled { return }
                    _ = unlink(dst.path)
                }
                if rename(src.path, dst.path) == 0 {
                    completed.append(src)
                    update { filesDone += 1 }
                } else if errno == EXDEV {
                    needCopy.append(src)
                } else {
                    errors.append("\(src.path): \(String(cString: strerror(errno)))")
                }
            }
            if needCopy.isEmpty { return }
            update { filesDone = 0; filesTotal = 0 }
        } else {
            needCopy = items
        }

        update { scanning = true }
        for u in needCopy { scan(u) }
        update { scanning = false }
        if isCancelled { return }

        for src in needCopy {
            if isCancelled { return }
            let dst = targetFor(src)
            if dst.path == src.path && op == .copy {
                errors.append("Cannot copy \(src.lastPathComponent) onto itself"); continue
            }
            if dst.path.hasPrefix(src.path + "/") {
                errors.append("Cannot copy \(src.lastPathComponent) into itself"); continue
            }
            let errBefore = errors.count
            let ok = copyTree(src.path, dst.path)
            if ok && !isCancelled && errors.count == errBefore {
                if op == .move {
                    do { try FileManager.default.removeItem(at: src) } catch { errors.append("Remove \(src.path): \(error.localizedDescription)") }
                }
                completed.append(src)
            }
        }
    }

    private func isDirectory(_ u: URL) -> Bool {
        var st = stat()
        return lstat(u.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Returns false if the item was skipped or failed.
    private func copyTree(_ src: String, _ dst: String) -> Bool {
        if isCancelled { return false }
        var st = stat()
        guard lstat(src, &st) == 0 else {
            errors.append("\(src): \(String(cString: strerror(errno)))"); return false
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            var dt = stat()
            if lstat(dst, &dt) == 0 {
                if (dt.st_mode & S_IFMT) != S_IFDIR {
                    if !confirmOverwrite(src, dst) { return false }
                    unlink(dst)
                    if mkdir(dst, 0o755) != 0 { errors.append("mkdir \(dst): \(String(cString: strerror(errno)))"); return false }
                }
            } else {
                while mkdir(dst, (st.st_mode & 0o7777) | 0o700) != 0 {
                    if !handleError("Create folder", dst, String(cString: strerror(errno))) { return false }
                }
            }
            var ok = true
            let names = (try? FileManager.default.contentsOfDirectory(atPath: src)) ?? []
            for n in names {
                if isCancelled { return false }
                if !copyTree(src + "/" + n, dst + "/" + n) { ok = false }
            }
            _ = copyfile(src, dst, nil, copyfile_flags_t(COPYFILE_METADATA))
            return ok
        }

        // File or symlink
        update { curName = (src as NSString).lastPathComponent; curTo = abbreviatePath((dst as NSString).deletingLastPathComponent); fileDone = 0; fileSize = Int64(st.st_size) }
        var dt = stat()
        if lstat(dst, &dt) == 0 {
            if !confirmOverwrite(src, dst) {
                update { totalDone += Int64(st.st_size); filesDone += 1 }
                return false
            }
            if isCancelled { return false }
            if (dt.st_mode & S_IFMT) == S_IFDIR {
                try? FileManager.default.removeItem(atPath: dst)
            } else {
                unlink(dst)
            }
        }
        var success = false
        while true {
            let r = copyWithProgress(src, dst)
            if r == 0 { success = true; break }
            if isCancelled { unlink(dst); return false }
            let err = String(cString: strerror(errno))
            unlink(dst)
            if !handleError("Copy", src, err) { break }
        }
        update { totalDone += Int64(st.st_size); fileDone = 0; filesDone += 1 }
        return success
    }

    private func copyWithProgress(_ src: String, _ dst: String) -> Int32 {
        guard let state = copyfile_state_alloc() else { return -1 }
        defer { copyfile_state_free(state) }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let cb: copyfile_callback_t = { what, stage, state, _, _, ctx in
            guard let ctx = ctx else { return Int32(COPYFILE_CONTINUE) }
            let job = Unmanaged<FileJob>.fromOpaque(ctx).takeUnretainedValue()
            if what == Int32(COPYFILE_COPY_DATA) && stage == Int32(COPYFILE_PROGRESS) {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                job.setFileDone(Int64(copied))
            }
            return job.isCancelled ? Int32(COPYFILE_QUIT) : Int32(COPYFILE_CONTINUE)
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(cb, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), ctx)
        return copyfile(src, dst, state, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW_SRC | COPYFILE_CLONE))
    }
}

// MARK: - Background shell tasks with a spinner (pack / unpack / dir sizes)

final class BackgroundTask {
    unowned let app: Commander
    let title: String
    var status = "Working…"
    private var process: Process?
    private var cancelled = false
    private let started = Date()

    init(app: Commander, title: String) {
        self.app = app
        self.title = title
    }

    /// Run a process; calls completion on the main thread with (exitCode, output).
    func runProcess(_ exe: String, _ args: [String], cwd: URL, completion: @escaping (Int32, String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        process = p
        let layer = ProgressLayer(app: app, title: title, provider: { [unowned self] in
            let spin = ["|", "/", "-", "\\"][Int(Date().timeIntervalSince(self.started) * 8) % 4]
            return ([self.status], nil, nil, "\(spin) \(Int(Date().timeIntervalSince(self.started)))s elapsed")
        }, onCancel: { [unowned self] in self.cancelled = true; self.process?.terminate() })
        app.push(layer)
        app.activeJobs += 1
        DispatchQueue.global().async {
            var out = Data()
            do {
                try p.run()
                while true {
                    let d = pipe.fileHandleForReading.availableData
                    if d.isEmpty { break }
                    if out.count < 256 * 1024 { out.append(d) }
                }
                p.waitUntilExit()
            } catch {
                out = Data(error.localizedDescription.utf8)
            }
            DispatchQueue.main.async {
                self.app.activeJobs -= 1
                self.app.pop(layer)
                completion(self.cancelled ? -1 : (p.isRunning ? -1 : p.terminationStatus), String(decoding: out, as: UTF8.self))
            }
        }
    }

    func runBlock(_ work: @escaping (BackgroundTask) -> Void, isCancelled: @escaping () -> Bool = { false }, completion: @escaping () -> Void) {
        let layer = ProgressLayer(app: app, title: title, provider: { [unowned self] in
            let spin = ["|", "/", "-", "\\"][Int(Date().timeIntervalSince(self.started) * 8) % 4]
            return ([self.status], nil, nil, "\(spin) \(Int(Date().timeIntervalSince(self.started)))s elapsed")
        }, onCancel: { [unowned self] in self.cancelled = true })
        app.push(layer)
        app.activeJobs += 1
        DispatchQueue.global().async {
            work(self)
            DispatchQueue.main.async {
                self.app.activeJobs -= 1
                self.app.pop(layer)
                completion()
            }
        }
    }

    var isCancelled: Bool { cancelled }
}
