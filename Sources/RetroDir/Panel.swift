import AppKit

// MARK: - File entries

let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar",
                                "dmg", "pkg", "jar", "iso", "zst", "lz", "lzma", "cpio", "xar", "war", "apk"]
let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "ico",
                              "icns", "pdf", "svg"]

struct FileEntry {
    let name: String
    let display: String
    let url: URL
    let isDir: Bool
    let isSymlink: Bool
    let isHidden: Bool
    let isExec: Bool
    let isPackage: Bool
    let isUp: Bool
    let size: Int64
    let mtime: Date
    let mode: UInt16
    var ext: String { isDir ? "" : (name as NSString).pathExtension.lowercased() }
    var isArchive: Bool { !isDir && archiveExts.contains(ext) }

    static func up(_ url: URL) -> FileEntry {
        FileEntry(name: "..", display: "..", url: url, isDir: true, isSymlink: false, isHidden: false,
                  isExec: false, isPackage: false, isUp: true, size: 0, mtime: Date.distantPast, mode: 0)
    }

    static func make(dir: URL, name: String) -> FileEntry? {
        let url = dir.appendingPathComponent(name)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let fmt = st.st_mode & S_IFMT
        let isLink = fmt == S_IFLNK
        var isDir = fmt == S_IFDIR
        var size = Int64(st.st_size)
        var mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        if isLink {
            var t = stat()
            if stat(url.path, &t) == 0 {
                isDir = (t.st_mode & S_IFMT) == S_IFDIR
                if !isDir { size = Int64(t.st_size) }
                mtime = Date(timeIntervalSince1970: TimeInterval(t.st_mtimespec.tv_sec))
            }
        }
        let hidden = name.hasPrefix(".") || (st.st_flags & UInt32(UF_HIDDEN)) != 0
        let exec = !isDir && fmt == S_IFREG && (st.st_mode & 0o111) != 0
        var pkg = false
        if isDir && name.contains(".") {
            pkg = NSWorkspace.shared.isFilePackage(atPath: url.path)
        }
        return FileEntry(name: name, display: name.precomposedStringWithCanonicalMapping, url: url, isDir: isDir,
                         isSymlink: isLink, isHidden: hidden, isExec: exec, isPackage: pkg, isUp: false,
                         size: isDir ? 0 : size, mtime: mtime, mode: UInt16(st.st_mode))
    }
}

enum PanelMode: String { case brief, full, info, quickView }
enum SortMode: String, CaseIterable { case name, ext, time, size, unsorted }

func permString(_ mode: UInt16, isDir: Bool, isLink: Bool) -> String {
    let m = Int(mode)
    var s = isLink ? "l" : isDir ? "d" : "-"
    let bits: [(Int, Character)] = [(0o400, "r"), (0o200, "w"), (0o100, "x"), (0o40, "r"), (0o20, "w"),
                                     (0o10, "x"), (0o4, "r"), (0o2, "w"), (0o1, "x")]
    for (b, c) in bits { s.append(m & b != 0 ? c : "-") }
    return s
}

let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd-yy"; return f }()
let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
let longFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

/// Recursively computes the size of a directory (allocated logical sizes of regular files).
func directorySize(_ url: URL, cancel: (() -> Bool)? = nil) -> (bytes: Int64, files: Int, dirs: Int) {
    var total: Int64 = 0, files = 0, dirs = 0
    guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
                                                  options: [], errorHandler: { _, _ in true }) else { return (0, 0, 0) }
    for case let u as URL in en {
        if let c = cancel, files % 256 == 0, c() { break }
        let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
        if v?.isDirectory == true && v?.isSymbolicLink != true { dirs += 1 } else {
            files += 1; total += Int64(v?.fileSize ?? 0)
        }
    }
    return (total, files, dirs)
}

// MARK: - Panel

final class Panel {
    unowned let app: Commander
    private(set) var path: URL
    var entries: [FileEntry] = []
    var cursor = 0
    var top = 0
    var selected = Set<String>()
    var mode: PanelMode = .full
    var sort: SortMode = .name
    var reverse = false
    var filter = ""
    var dirSizes: [String: Int64] = [:]
    var history: [URL] = []
    var error: String?
    var freeSpace: Int64 = 0
    var volumeName = ""
    var volumeTotal: Int64 = 0

    // Layout from last render
    var listRows = 20
    var columns = 1
    var frame = (x: 0, y: 0, w: 40, h: 20)
    var listY = 0
    var colWidth = 40

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadPending = false
    private var previewCache: (key: String, lines: [String], image: NSImage?)?
    private var infoCache: (key: String, lines: [(String, String)])?

    init(app: Commander, path: URL) {
        self.app = app
        self.path = path
    }

    var current: FileEntry? { entries.indices.contains(cursor) ? entries[cursor] : nil }

    /// Entries an operation should act on: selection, or the entry under the cursor.
    var targets: [FileEntry] {
        if !selected.isEmpty { return entries.filter { selected.contains($0.name) } }
        if let c = current, !c.isUp { return [c] }
        return []
    }

    var pageSize: Int { max(1, listRows * columns) }

    // MARK: Loading

    func load(select: String? = nil, keepCursor: Bool = false) {
        let oldName = current?.name
        let oldCursor = cursor
        var list: [FileEntry] = []
        error = nil
        let p = path.path
        if p != "/" { list.append(.up(path.deletingLastPathComponent())) }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: p)
            for n in names {
                guard let e = FileEntry.make(dir: path, name: n) else { continue }
                if e.isHidden && !app.showHidden { continue }
                if !filter.isEmpty && !e.isDir && !matchesMask(e.display, filter) { continue }
                list.append(e)
            }
        } catch {
            self.error = (error as NSError).localizedDescription
        }
        entries = sorted(list)
        let names = Set(entries.map(\.name))
        selected = selected.intersection(names)
        dirSizes = dirSizes.filter { names.contains($0.key) }
        if let s = select ?? (keepCursor ? oldName : nil), let i = entries.firstIndex(where: { $0.name == s }) {
            cursor = i
        } else if keepCursor {
            cursor = min(oldCursor, max(0, entries.count - 1))
        } else {
            cursor = 0
        }
        if let v = try? path.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeNameKey, .volumeTotalCapacityKey]) {
            freeSpace = v.volumeAvailableCapacityForImportantUsage ?? 0
            volumeName = v.volumeName ?? ""
            volumeTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        clampTop()
        watch()
    }

    func reload() { load(keepCursor: true) }

    private func sorted(_ list: [FileEntry]) -> [FileEntry] {
        if sort == .unsorted { return list }
        let ups = list.filter(\.isUp)
        let dirs = list.filter { $0.isDir && !$0.isUp }
        let files = list.filter { !$0.isDir }
        func cmp(_ a: FileEntry, _ b: FileEntry) -> Bool {
            var r: ComparisonResult
            switch sort {
            case .name, .unsorted: r = a.name.localizedStandardCompare(b.name)
            case .ext:
                r = a.ext.localizedStandardCompare(b.ext)
                if r == .orderedSame { r = a.name.localizedStandardCompare(b.name) }
            case .time:
                r = a.mtime > b.mtime ? .orderedAscending : a.mtime < b.mtime ? .orderedDescending : a.name.localizedStandardCompare(b.name)
            case .size:
                let sa = a.isDir ? (dirSizes[a.name] ?? -1) : a.size, sb = b.isDir ? (dirSizes[b.name] ?? -1) : b.size
                r = sa > sb ? .orderedAscending : sa < sb ? .orderedDescending : a.name.localizedStandardCompare(b.name)
            }
            return reverse ? r == .orderedDescending : r == .orderedAscending
        }
        return ups + dirs.sorted(by: cmp) + files.sorted(by: cmp)
    }

    func resort() {
        let name = current?.name
        entries = sorted(entries)
        if let n = name, let i = entries.firstIndex(where: { $0.name == n }) { cursor = i }
        clampTop()
    }

    private func watch() {
        watcher?.cancel()
        watcher = nil
        let fd = open(path.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .link, .extend], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self, !self.reloadPending else { return }
            self.reloadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reloadPending = false
                if !FileManager.default.fileExists(atPath: self.path.path) {
                    self.goExistingAncestor()
                } else {
                    self.reload()
                }
                self.app.view?.refresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func goExistingAncestor() {
        var p = path
        while !FileManager.default.fileExists(atPath: p.path) && p.path != "/" { p = p.deletingLastPathComponent() }
        go(p)
    }

    // MARK: Navigation

    @discardableResult
    func go(_ url: URL, select: String? = nil, recordHistory: Bool = true) -> Bool {
        let u = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else {
            app.message("Error", "Cannot open folder:\n\(u.path)", error: true)
            return false
        }
        guard (try? FileManager.default.contentsOfDirectory(atPath: u.path)) != nil else {
            app.message("Error", "Permission denied:\n\(u.path)\n\nGrant access in System Settings › Privacy & Security › Files and Folders (or Full Disk Access).", error: true)
            return false
        }
        if recordHistory && u != path {
            history.removeAll { $0 == path }
            history.append(path)
            if history.count > 50 { history.removeFirst() }
        }
        if u != path { selected.removeAll(); filter = "" }
        path = u
        top = 0
        load(select: select)
        return true
    }

    func goUp() {
        guard path.path != "/" else { return }
        go(path.deletingLastPathComponent(), select: path.lastPathComponent)
    }

    func clampTop() {
        if entries.isEmpty { cursor = 0; top = 0; return }
        cursor = max(0, min(cursor, entries.count - 1))
        let rows = max(1, listRows)
        if columns <= 1 {
            if cursor < top { top = cursor }
            if cursor >= top + rows { top = cursor - rows + 1 }
            top = max(0, min(top, max(0, entries.count - rows)))
        } else {
            if cursor < top { top = (cursor / rows) * rows }
            if cursor >= top + rows * columns { top = (cursor / rows - columns + 1) * rows }
            top = max(0, top)
        }
    }

    func move(_ delta: Int) {
        cursor = max(0, min(entries.count - 1, cursor + delta))
        clampTop()
    }

    func moveTo(_ i: Int) { cursor = i; clampTop() }

    func toggleSelect(_ e: FileEntry) {
        guard !e.isUp else { return }
        if selected.contains(e.name) { selected.remove(e.name) } else { selected.insert(e.name) }
    }

    func selectMask(_ mask: String, select: Bool, includeDirs: Bool) {
        for e in entries where !e.isUp && (includeDirs || !e.isDir) && matchesMask(e.display, mask) {
            if select { selected.insert(e.name) } else { selected.remove(e.name) }
        }
    }

    func invertSelection() {
        for e in entries where !e.isUp && !e.isDir {
            if selected.contains(e.name) { selected.remove(e.name) } else { selected.insert(e.name) }
        }
    }

    func quickFind(_ prefix: String, from start: Int = 0) -> Int? {
        let p = prefix.lowercased()
        let n = entries.count
        guard n > 0 else { return nil }
        for k in 0..<n {
            let i = (start + k) % n
            if entries[i].display.lowercased().hasPrefix(p) { return i }
        }
        for k in 0..<n {
            let i = (start + k) % n
            if entries[i].display.lowercased().contains(p) { return i }
        }
        return nil
    }

    // MARK: Rendering

    func role(for e: FileEntry, isCursor: Bool) -> Role {
        let sel = selected.contains(e.name)
        if isCursor { return sel ? .cursorSelected : .cursor }
        if sel { return .selected }
        if e.isUp || (e.isDir && !e.isPackage) { return e.isHidden ? .hidden : .dir }
        if e.isSymlink { return .symlink }
        if e.isHidden { return .hidden }
        if e.isPackage || e.isExec { return .exec }
        if e.isArchive { return .archive }
        return .panel
    }

    func sizeText(_ e: FileEntry, _ w: Int) -> String {
        if e.isUp { return pad("►UP--DIR◄", w, right: true) }
        if e.isDir {
            if let s = dirSizes[e.name] { return pad(columnSize(s, w), w, right: true) }
            if e.isPackage { return pad("►BUNDLE◄", w, right: true) }
            if e.isSymlink { return pad("►SYMLINK◄", w, right: true) }
            return pad("►SUB-DIR◄", w, right: true)
        }
        return pad(columnSize(e.size, w), w, right: true)
    }

    func render(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool, other: Panel) {
        frame = (x, y, w, h)
        switch mode {
        case .info: renderInfo(s, x: x, y: y, w: w, h: h, active: active, other: other)
        case .quickView: renderQuickView(s, x: x, y: y, w: w, h: h, active: active, other: other)
        default: renderList(s, x: x, y: y, w: w, h: h, active: active)
        }
    }

    private func renderList(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool) {
        s.box(x, y, w, h, .panelFrame)
        let iw = w - 2
        listRows = max(1, h - 5)
        listY = y + 2
        let sepY = y + h - 3

        // Column layout
        var cols: [(title: String, width: Int)] = []
        if mode == .full {
            var nameW = iw - (10 + 1) - (8 + 1) - (5 + 1)
            var sizeW = 10, dateW = 8, timeW = 5
            if nameW < 14 { nameW += timeW + 1; timeW = 0 }
            if nameW < 14 { nameW += dateW + 1; dateW = 0 }
            if nameW < 12 { nameW += sizeW + 1; sizeW = 0 }
            cols.append(("Name", nameW))
            if sizeW > 0 { cols.append(("Size", sizeW)) }
            if dateW > 0 { cols.append(("Date", dateW)) }
            if timeW > 0 { cols.append(("Time", timeW)) }
            columns = 1
        } else {
            let n = iw >= 66 ? 3 : 2
            columns = n
            let base = (iw - (n - 1)) / n
            for i in 0..<n { cols.append(("Name", i == n - 1 ? iw - (n - 1) - base * (n - 1) : base)) }
        }
        colWidth = cols[0].width
        clampTop()

        // Dividers
        var cx = x + 1
        var dividerXs: [Int] = []
        for (i, c) in cols.enumerated() {
            s.put(cx, y + 1, center(c.title, c.width), .panelHeader)
            cx += c.width
            if i < cols.count - 1 {
                dividerXs.append(cx)
                s.putc(cx, y, "╤", .panelFrame)
                for yy in (y + 1)..<sepY { s.putc(cx, yy, "│", .panelFrame) }
                cx += 1
            }
        }
        s.separator(x, sepY, w, .panelFrame)
        for dx in dividerXs { s.putc(dx, sepY, "┴", .panelFrame) }

        // Rows
        for row in 0..<listRows {
            let yy = listY + row
            if mode == .full {
                let i = top + row
                guard i < entries.count else { continue }
                let e = entries[i]
                let isCur = active && i == cursor
                let r = role(for: e, isCursor: isCur)
                var cx = x + 1
                for (ci, c) in cols.enumerated() {
                    let text: String
                    switch c.title {
                    case "Name": text = truncate(e.display, c.width)
                    case "Size": text = sizeText(e, c.width)
                    case "Date": text = e.isUp ? "" : dateFmt.string(from: e.mtime)
                    default: text = e.isUp ? "" : timeFmt.string(from: e.mtime)
                    }
                    s.put(cx, yy, text, r, width: c.width)
                    cx += c.width
                    if ci < cols.count - 1 { s.recolor(cx, yy, 1, isCur ? s.attr(r) : s.attr(.panelFrame)); cx += 1 }
                }
            } else {
                var cx = x + 1
                for ci in 0..<columns {
                    let i = top + ci * listRows + row
                    let cw = cols[ci].width
                    if i < entries.count {
                        let e = entries[i]
                        let isCur = active && i == cursor
                        s.put(cx, yy, truncate(e.display, cw), role(for: e, isCursor: isCur), width: cw)
                    }
                    cx += cw + 1
                }
            }
        }

        // Title (path)
        var title = abbreviatePath(path.path)
        if !filter.isEmpty { title += " [\(filter)]" }
        let t = " " + truncateLeft(title, w - 6) + " "
        s.put(x + (w - t.count) / 2, y, t, active ? .panelTitleActive : .panelTitle)

        // Status line
        let sy = y + h - 2
        if let e = current {
            if let err = error {
                s.put(x + 1, sy, truncate("⚠ " + err, iw), .panel, width: iw)
            } else if e.isUp {
                s.put(x + 1, sy, "..", .panel, width: iw)
                let r = "Up to " + truncateLeft(abbreviatePath(e.url.path), iw - 10)
                s.put(x + 1 + iw - r.count, sy, r, .panel)
            } else {
                let right: String
                if e.isDir {
                    right = (dirSizes[e.name].map { grouped($0) } ?? (e.isPackage ? "Bundle" : "Folder")) + " " + dateFmt.string(from: e.mtime) + " " + timeFmt.string(from: e.mtime)
                } else {
                    right = grouped(e.size) + " " + dateFmt.string(from: e.mtime) + " " + timeFmt.string(from: e.mtime)
                }
                var nm = e.display
                if e.isSymlink, let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: e.url.path) {
                    nm += " → " + dest
                }
                let nw = max(4, iw - right.count - 1)
                s.put(x + 1, sy, truncate(nm, nw), .panel, width: iw)
                s.put(x + 1 + iw - min(right.count, iw), sy, String(right.suffix(iw)), .panel)
            }
        } else if let err = error {
            s.put(x + 1, sy, truncate("⚠ " + err, iw), .panel, width: iw)
        }

        // Bottom border: selection summary or totals
        let by = y + h - 1
        if !selected.isEmpty {
            let sel = entries.filter { selected.contains($0.name) }
            let bytes = sel.reduce(Int64(0)) { $0 + ($1.isDir ? (dirSizes[$1.name] ?? 0) : $1.size) }
            let msg = " \(grouped(bytes)) bytes in \(sel.count) selected item\(sel.count == 1 ? "" : "s") "
            s.put(x + max(1, (w - msg.count) / 2), by, truncate(msg, w - 2), .selected)
        } else {
            let files = entries.filter { !$0.isDir }
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            var msg = " \(grouped(bytes)) bytes in \(files.count) files"
            if freeSpace > 0 { msg += " · \(humanSize(freeSpace)) free" }
            msg += " "
            s.put(x + max(1, (w - msg.count) / 2), by, truncate(msg, w - 2), .panelFrame)
        }

        // Scroll indicator
        let total = entries.count
        if total > pageSize && listRows > 2 {
            let frac = Double(cursor) / Double(max(1, total - 1))
            let py = listY + Int(frac * Double(listRows - 1))
            s.putc(x + w - 1, py, "▓", .panelFrame)
        }
    }

    // MARK: Info panel

    private func renderInfo(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool, other: Panel) {
        s.box(x, y, w, h, .panelFrame, title: "Info", titleRole: active ? .panelTitleActive : .panelTitle)
        let iw = w - 4
        var yy = y + 1
        func line(_ a: String, _ b: String = "", _ role: Role = .panel) {
            guard yy < y + h - 1 else { return }
            if b.isEmpty {
                s.put(x + 2, yy, truncate(a, iw), role, width: iw)
            } else {
                let lw = min(10, iw / 3)
                s.put(x + 2, yy, pad(a, lw), .panelHeader)
                s.put(x + 2 + lw, yy, truncate(b, iw - lw), role, width: iw - lw)
            }
            yy += 1
        }
        func sep() { guard yy < y + h - 1 else { return }; s.separator(x, yy, w, .panelFrame); yy += 1 }

        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        line("RetroDir", "", .dir)
        line("User", NSUserName() + " @ " + host)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        line("macOS", "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
        let mem = ProcessInfo.processInfo.physicalMemory
        line("Memory", humanSize(Int64(mem)))
        sep()
        line("Volume", other.volumeName)
        if other.volumeTotal > 0 {
            line("Total", humanSize(other.volumeTotal))
            let pct = Int(Double(other.freeSpace) / Double(other.volumeTotal) * 100)
            line("Free", "\(humanSize(other.freeSpace)) (\(pct)%)")
            // usage bar
            if yy < y + h - 1 {
                let bw = iw
                let used = Int(Double(bw) * (1 - Double(other.freeSpace) / Double(other.volumeTotal)))
                s.put(x + 2, yy, String(repeating: "█", count: max(0, used)) + String(repeating: "░", count: max(0, bw - used)), .panelDim)
                yy += 1
            }
        }
        sep()
        let files = other.entries.filter { !$0.isDir }
        let dirs = other.entries.filter { $0.isDir && !$0.isUp }
        line("Folder", abbreviatePath(other.path.path))
        line("Contents", "\(files.count) files, \(dirs.count) folders")
        line("Size", humanSize(files.reduce(0) { $0 + $1.size }) + " (files)")
        sep()
        guard let e = other.current, !e.isUp else { return }
        let key = e.url.path + "|\(e.mtime.timeIntervalSince1970)|\(e.size)"
        if infoCache?.key != key { infoCache = (key, Panel.infoLines(e)) }
        for (a, b) in infoCache!.lines { line(a, b) }
    }

    static func infoLines(_ e: FileEntry) -> [(String, String)] {
        var out: [(String, String)] = [("Name", e.display)]
        let rv = try? e.url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .creationDateKey, .contentModificationDateKey, .contentAccessDateKey, .totalFileAllocatedSizeKey])
        out.append(("Kind", rv?.localizedTypeDescription ?? (e.isDir ? "Folder" : "File")))
        if !e.isDir {
            out.append(("Size", "\(grouped(e.size)) bytes (\(humanSize(e.size)))"))
            if let a = rv?.totalFileAllocatedSize { out.append(("On disk", humanSize(Int64(a)))) }
        }
        if let c = rv?.creationDate { out.append(("Created", longFmt.string(from: c))) }
        if let m = rv?.contentModificationDate { out.append(("Modified", longFmt.string(from: m))) }
        if let a = rv?.contentAccessDate { out.append(("Accessed", longFmt.string(from: a))) }
        out.append(("Perms", permString(e.mode, isDir: e.isDir, isLink: e.isSymlink) + String(format: "  (%03o)", Int(e.mode) & 0o777)))
        if let attrs = try? FileManager.default.attributesOfItem(atPath: e.url.path) {
            let o = attrs[.ownerAccountName] as? String ?? "?"
            let g = attrs[.groupOwnerAccountName] as? String ?? "?"
            out.append(("Owner", "\(o):\(g)"))
        }
        if e.isSymlink, let d = try? FileManager.default.destinationOfSymbolicLink(atPath: e.url.path) {
            out.append(("Link to", d))
        }
        if let tags = try? e.url.resourceValues(forKeys: [.tagNamesKey]).tagNames, !tags.isEmpty {
            out.append(("Tags", tags.joined(separator: ", ")))
        }
        return out
    }

    // MARK: Quick view panel

    private func renderQuickView(_ s: Screen, x: Int, y: Int, w: Int, h: Int, active: Bool, other: Panel) {
        guard let e = other.current else {
            s.box(x, y, w, h, .panelFrame, title: "Quick View", titleRole: active ? .panelTitleActive : .panelTitle)
            return
        }
        s.box(x, y, w, h, .panelFrame, title: "Quick View: " + e.display, titleRole: active ? .panelTitleActive : .panelTitle)
        let iw = w - 2, ih = h - 2
        let key = e.url.path + "|\(e.mtime.timeIntervalSince1970)|\(e.size)|\(iw)"
        if previewCache?.key != key { previewCache = (key, Panel.preview(e, width: iw), Panel.previewImage(e)) }
        if let img = previewCache?.image {
            s.overlays.append(ImageOverlay(x: x + 1, y: y + 1, w: iw, h: ih - 2, image: img))
            let d = "\(Int(img.size.width))×\(Int(img.size.height))  \(humanSize(e.size))"
            s.put(x + 1, y + h - 2, center(d, iw), .panelHeader)
            return
        }
        for (i, l) in (previewCache?.lines ?? []).prefix(ih).enumerated() {
            s.put(x + 1, y + 1 + i, l, .panel, width: iw)
        }
    }

    static func previewImage(_ e: FileEntry) -> NSImage? {
        guard !e.isDir, imageExts.contains(e.ext), e.size < 80_000_000 else { return nil }
        return NSImage(contentsOf: e.url)
    }

    static func preview(_ e: FileEntry, width: Int) -> [String] {
        if e.isUp { return [] }
        if e.isDir {
            var out = ["", "  Folder: " + e.display, ""]
            if let items = try? FileManager.default.contentsOfDirectory(atPath: e.url.path) {
                out.append("  \(items.count) items")
                out.append("")
                for n in items.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }).prefix(200) {
                    out.append("  " + n.precomposedStringWithCanonicalMapping)
                }
            } else {
                out.append("  (no access)")
            }
            return out
        }
        guard let fh = FileHandle(forReadingAtPath: e.url.path) else { return ["", "  Cannot read file"] }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: 32 * 1024)) ?? Data()
        if data.isEmpty { return ["", "  (empty file)"] }
        if e.isArchive {
            let out = runCapture("/usr/bin/tar", ["-tf", e.url.path], limit: 64 * 1024)
            return ["  Archive contents:", ""] + out.split(separator: "\n", omittingEmptySubsequences: false).prefix(300).map { "  " + $0 }
        }
        if data.contains(0) {
            return hexLines(data.prefix(4096), base: 0, width: width)
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\t", with: "    ")
        }
    }

    static func hexLines(_ data: Data, base: Int, width: Int) -> [String] {
        let per = width >= 76 ? 16 : 8
        var out: [String] = []
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let chunk = bytes[i..<min(i + per, bytes.count)]
            var hex = chunk.map { String(format: "%02X", $0) }.joined(separator: " ")
            hex = hex.padding(toLength: per * 3 - 1, withPad: " ", startingAt: 0)
            let asc = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            out.append(String(format: "%06X ", base + i) + hex + " " + asc)
            i += per
        }
        return out
    }
}

/// Runs a process and captures stdout (used for small, quick helpers).
func runCapture(_ exe: String, _ args: [String], cwd: URL? = nil, limit: Int = 1 << 20) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let c = cwd { p.currentDirectoryURL = c }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    do { try p.run() } catch { return "Failed to run \(exe): \(error.localizedDescription)" }
    var data = Data()
    while true {
        let d = pipe.fileHandleForReading.availableData
        if d.isEmpty { break }
        if data.count < limit { data.append(d) }
    }
    p.waitUntilExit()
    return String(decoding: data.prefix(limit), as: UTF8.self)
}
