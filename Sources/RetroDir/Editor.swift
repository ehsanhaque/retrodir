import AppKit

/// F4 editor: multi-line editing with selection, clipboard, undo, search/replace.
final class Editor: Layer {
    var isFullScreen: Bool { true }
    unowned let app: Commander
    private(set) var url: URL
    private var lines: [[Character]] = [[]]
    private var crlf = false
    private var latin1 = false
    private var row = 0, col = 0
    private var prefVCol: Int?
    private var top = 0, left = 0
    private var anchor: (r: Int, c: Int)?
    private var modified = false
    private var undoStack: [(lines: [[Character]], row: Int, col: Int)] = []
    private var redoStack: [(lines: [[Character]], row: Int, col: Int)] = []
    private var lastEditKind = ""
    private var lastSearch = ""
    private var lastReplace = ""
    private var caseSensitive = false
    private var w = 80, h = 22
    private let tabWidth = 4
    var onClose: (() -> Void)?

    init(app: Commander, url: URL, isNew: Bool = false) throws {
        self.app = app
        self.url = url
        if !isNew {
            let data = try Data(contentsOf: url)
            if data.count > 20_000_000 { throw NSError(domain: "Editor", code: 1, userInfo: [NSLocalizedDescriptionKey: "File is too large for the editor (\(humanSize(Int64(data.count)))). Use F3 to view it."]) }
            if data.prefix(8192).contains(0) { throw NSError(domain: "Editor", code: 2, userInfo: [NSLocalizedDescriptionKey: "This looks like a binary file. Use F3 (viewer, hex mode) instead."]) }
            var text: String
            if let t = String(data: data, encoding: .utf8) { text = t } else { text = String(data: data, encoding: .isoLatin1) ?? ""; latin1 = true }
            if text.contains("\r\n") { crlf = true; text = text.replacingOccurrences(of: "\r\n", with: "\n") }
            lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) }
            if lines.isEmpty { lines = [[]] }
        } else {
            modified = true
        }
    }

    // MARK: Helpers

    private func vcol(_ r: Int, _ c: Int) -> Int {
        var v = 0
        for ch in lines[r].prefix(c) { v = ch == "\t" ? (v / tabWidth + 1) * tabWidth : v + 1 }
        return v
    }

    private func colFor(_ r: Int, vcol target: Int) -> Int {
        var v = 0
        for (i, ch) in lines[r].enumerated() {
            let nv = ch == "\t" ? (v / tabWidth + 1) * tabWidth : v + 1
            if nv > target { return i }
            v = nv
        }
        return lines[r].count
    }

    private func expanded(_ r: Int) -> [Character] {
        var out: [Character] = []
        for ch in lines[r] {
            if ch == "\t" { repeat { out.append(" ") } while out.count % tabWidth != 0 } else { out.append(ch) }
        }
        return out
    }

    private var selection: (s: (r: Int, c: Int), e: (r: Int, c: Int))? {
        guard let a = anchor, a.r != row || a.c != col else { return nil }
        if a.r < row || (a.r == row && a.c < col) { return (a, (row, col)) }
        return ((row, col), a)
    }

    private func selectedText() -> String? {
        guard let sel = selection else { return nil }
        if sel.s.r == sel.e.r { return String(lines[sel.s.r][sel.s.c..<sel.e.c]) }
        var parts = [String(lines[sel.s.r][sel.s.c...])]
        for r in (sel.s.r + 1)..<sel.e.r { parts.append(String(lines[r])) }
        parts.append(String(lines[sel.e.r][..<sel.e.c]))
        return parts.joined(separator: "\n")
    }

    private func snapshot(_ kind: String) {
        if kind != lastEditKind || kind == "other" {
            undoStack.append((lines, row, col))
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        lastEditKind = kind
        modified = true
    }

    private func deleteSelection() -> Bool {
        guard let sel = selection else { anchor = nil; return false }
        let head = Array(lines[sel.s.r][..<sel.s.c])
        let tail = Array(lines[sel.e.r][sel.e.c...])
        lines.replaceSubrange(sel.s.r...sel.e.r, with: [head + tail])
        row = sel.s.r; col = sel.s.c
        anchor = nil
        return true
    }

    private func insert(_ text: String) {
        _ = deleteSelection()
        let parts = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { Array($0) }
        let head = Array(lines[row][..<col])
        let tail = Array(lines[row][col...])
        if parts.count == 1 {
            lines[row] = head + parts[0] + tail
            col += parts[0].count
        } else {
            var newLines = [head + parts[0]]
            newLines.append(contentsOf: parts[1..<(parts.count - 1)])
            newLines.append(parts[parts.count - 1] + tail)
            lines.replaceSubrange(row...row, with: newLines)
            row += parts.count - 1
            col = parts[parts.count - 1].count
        }
    }

    private func ensureVisible() {
        row = max(0, min(row, lines.count - 1))
        col = max(0, min(col, lines[row].count))
        if row < top { top = row }
        if row >= top + h { top = row - h + 1 }
        let v = vcol(row, col)
        if v < left { left = max(0, v - 8) }
        if v >= left + w { left = v - w + 8 }
    }

    // MARK: Rendering

    func render(_ s: Screen) {
        w = s.cols
        h = s.rows - 2
        ensureVisible()
        s.clear(.editor)
        let sel = selection
        for i in 0..<h {
            let r = top + i
            guard r < lines.count else { break }
            let ex = expanded(r)
            if ex.count > left { s.put(0, i + 1, String(ex[left..<min(ex.count, left + w)]), .editor) }
            if let sel = sel, r >= sel.s.r, r <= sel.e.r {
                let a = r == sel.s.r ? vcol(r, sel.s.c) : 0
                let b = r == sel.e.r ? vcol(r, sel.e.c) : ex.count + 1
                let x0 = max(0, a - left), x1 = min(w, b - left)
                if x1 > x0 { s.recolor(x0, i + 1, x1 - x0, .editorSel) }
            }
        }
        s.fill(0, 0, s.cols, 1, " ", .editorStatus)
        let right = "Ln \(row + 1)/\(lines.count)  Col \(vcol(row, col) + 1)  \(latin1 ? "Latin-1" : "UTF-8") \(crlf ? "CRLF" : "LF") "
        s.put(1, 0, (modified ? "* " : "  ") + truncateLeft(abbreviatePath(url.path), max(10, s.cols - right.count - 5)), .editorStatus)
        s.put(s.cols - right.count, 0, right, .editorStatus)
        s.caret = (vcol(row, col) - left, row - top + 1)
        app.drawKeyBar(s, ["Help", "Save", "Mark", "", "", "Replac", "Search", "DelLn", "SaveAs", "Quit"])
    }

    // MARK: Keys

    private func moveCursor(_ k: Key) -> Bool {
        let extend = k.shift
        let before = (row, col)
        var vertical = false
        switch (k.code, k.mods.subtracting(.shift)) {
        case (.left, []):
            if col > 0 { col -= 1 } else if row > 0 { row -= 1; col = lines[row].count }
        case (.right, []):
            if col < lines[row].count { col += 1 } else if row < lines.count - 1 { row += 1; col = 0 }
        case (.left, [.alt]), (.left, [.ctrl]):
            if col == 0, row > 0 { row -= 1; col = lines[row].count } else {
                while col > 0 && !lines[row][col - 1].isLetterOrDigit { col -= 1 }
                while col > 0 && lines[row][col - 1].isLetterOrDigit { col -= 1 }
            }
        case (.right, [.alt]), (.right, [.ctrl]):
            if col == lines[row].count, row < lines.count - 1 { row += 1; col = 0 } else {
                while col < lines[row].count && !lines[row][col].isLetterOrDigit { col += 1 }
                while col < lines[row].count && lines[row][col].isLetterOrDigit { col += 1 }
            }
        case (.up, []): vertical = true; row = max(0, row - 1)
        case (.down, []): vertical = true; row = min(lines.count - 1, row + 1)
        case (.pageUp, []): vertical = true; row = max(0, row - h + 1); top = max(0, top - h + 1)
        case (.pageDown, []): vertical = true; row = min(lines.count - 1, row + h - 1); top = min(max(0, lines.count - h), top + h - 1)
        case (.home, []), (.left, [.cmd]):
            let indent = lines[row].prefix { $0 == " " || $0 == "\t" }.count
            col = col == indent ? 0 : indent
        case (.end, []), (.right, [.cmd]): col = lines[row].count
        case (.home, [.ctrl]), (.up, [.cmd]), (.home, [.cmd]): row = 0; col = 0
        case (.end, [.ctrl]), (.down, [.cmd]), (.end, [.cmd]): row = lines.count - 1; col = lines[row].count
        default: return false
        }
        if vertical {
            let pv = prefVCol ?? vcol(before.0, before.1)
            prefVCol = pv
            col = colFor(row, vcol: pv)
        } else {
            prefVCol = nil
        }
        if extend { if anchor == nil { anchor = (before.0, before.1) } } else { anchor = nil }
        lastEditKind = ""
        return true
    }

    func key(_ k: Key) {
        if moveCursor(k) { return }
        switch (k.code, k.mods) {
        case (.escape, _), (.f(10), []): tryClose()
        case (.f(1), []): app.showHelp()
        case (.f(2), []), (.char("s"), [.cmd]): save()
        case (.f(9), []), (.f(2), [.shift]), (.char("s"), [.cmd, .shift]): saveAs()
        case (.f(3), []):
            anchor = anchor == nil ? (row, col) : nil
        case (.f(7), []), (.char("f"), [.cmd]): searchDialog(replace: false)
        case (.f(6), []), (.char("f"), [.cmd, .alt]): searchDialog(replace: true)
        case (.f(7), [.shift]), (.char("g"), [.cmd]): _ = findNext(wrapAround: true)
        case (.f(8), []), (.char("y"), [.ctrl]), (.char("k"), [.cmd, .shift]):
            snapshot("other")
            if lines.count > 1 { lines.remove(at: row) } else { lines = [[]] }
            row = min(row, lines.count - 1); col = 0; anchor = nil
        case (.char("a"), [.cmd]):
            anchor = (0, 0); row = lines.count - 1; col = lines[row].count
        case (.char("c"), [.cmd]):
            if let t = selectedText() ?? Optional(String(lines[row]) + "\n") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
            }
        case (.char("x"), [.cmd]):
            if let t = selectedText() {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string)
                snapshot("other"); _ = deleteSelection()
            }
        case (.char("v"), [.cmd]):
            if let t = NSPasteboard.general.string(forType: .string) { snapshot("other"); insert(t) }
        case (.char("z"), [.cmd]):
            if let u = undoStack.popLast() {
                redoStack.append((lines, row, col))
                lines = u.lines; row = u.row; col = u.col; anchor = nil; lastEditKind = ""; modified = true
            }
        case (.char("z"), [.cmd, .shift]):
            if let u = redoStack.popLast() {
                undoStack.append((lines, row, col))
                lines = u.lines; row = u.row; col = u.col; anchor = nil; lastEditKind = ""; modified = true
            }
        case (.char("d"), [.cmd]):
            // duplicate line
            snapshot("other"); lines.insert(lines[row], at: row + 1); row += 1
        case (.enter, _):
            snapshot("other")
            _ = deleteSelection()
            let indent = lines[row].prefix(while: { $0 == " " || $0 == "\t" })
            insert("\n" + String(indent))
        case (.tab, []):
            snapshot("type")
            if let sel = selection, sel.s.r != sel.e.r {
                for r in sel.s.r...sel.e.r { lines[r].insert("\t", at: 0) }
            } else { insert("\t") }
        case (.tab, [.shift]):
            snapshot("other")
            let range = selection.map { $0.s.r...$0.e.r } ?? row...row
            for r in range {
                if lines[r].first == "\t" { lines[r].removeFirst() } else {
                    let n = lines[r].prefix(while: { $0 == " " }).count
                    lines[r].removeFirst(min(n, tabWidth))
                }
            }
            col = min(col, lines[row].count)
        case (.backspace, []):
            snapshot("del")
            if deleteSelection() { break }
            if col > 0 { lines[row].remove(at: col - 1); col -= 1 } else if row > 0 {
                col = lines[row - 1].count
                lines[row - 1] += lines[row]
                lines.remove(at: row); row -= 1
            }
        case (.backspace, [.alt]):
            snapshot("other")
            if deleteSelection() { break }
            let end = col
            while col > 0 && !lines[row][col - 1].isLetterOrDigit { col -= 1 }
            while col > 0 && lines[row][col - 1].isLetterOrDigit { col -= 1 }
            lines[row].removeSubrange(col..<end)
        case (.delete, []):
            snapshot("del")
            if deleteSelection() { break }
            if col < lines[row].count { lines[row].remove(at: col) } else if row < lines.count - 1 {
                lines[row] += lines[row + 1]; lines.remove(at: row + 1)
            }
        default:
            if let c = k.text {
                snapshot(c == " " ? "space" : "type")
                insert(String(c))
            }
        }
    }

    // MARK: Search / replace

    private func matches(_ r: Int, _ c: Int, _ needle: [Character]) -> Bool {
        let l = lines[r]
        guard c + needle.count <= l.count else { return false }
        for (i, n) in needle.enumerated() {
            let a = l[c + i]
            if caseSensitive ? a != n : a.lowercased() != n.lowercased() { return false }
        }
        return true
    }

    private func findNext(wrapAround: Bool) -> Bool {
        let needle = Array(lastSearch)
        guard !needle.isEmpty else { return false }
        var r = row, c = col + (selection != nil ? 0 : 0)
        if let sel = selection { r = sel.e.r; c = sel.e.c }
        for pass in 0..<2 {
            while r < lines.count {
                var cc = c
                while cc + needle.count <= lines[r].count {
                    if matches(r, cc, needle) {
                        anchor = (r, cc); row = r; col = cc + needle.count
                        top = max(0, min(top, r)); if r >= top + h { top = max(0, r - h / 3) }
                        return true
                    }
                    cc += 1
                }
                r += 1; c = 0
            }
            if pass == 0 && wrapAround { r = 0; c = 0 } else { break }
        }
        app.message("Search", "\"\(lastSearch)\" not found")
        return false
    }

    private func searchDialog(replace: Bool) {
        let d = Dialog(app: app, title: replace ? "Replace" : "Search", buttons: replace ? ["Replace", "All", "Cancel"] : ["Search", "Cancel"], width: 56)
        d.text("Search for:").field(selectedText().flatMap { $0.contains("\n") ? nil : $0 } ?? lastSearch)
        if replace { d.text("Replace with:").field(lastReplace) }
        d.check("Case sensitive", caseSensitive)
        d.onClose = { [unowned self] r, d in
            guard let r = r, !d.fields[0].text.isEmpty else { return }
            lastSearch = d.fields[0].text
            caseSensitive = d.checks[0].on
            if !replace { if r == 0 { _ = findNext(wrapAround: true) }; return }
            lastReplace = d.fields[1].text
            if r == 2 { return }
            snapshot("other")
            if r == 1 {
                var count = 0
                row = 0; col = 0; anchor = nil
                while findNextSilent() { insert(lastReplace); count += 1 }
                app.toast("Replaced \(count) occurrence\(count == 1 ? "" : "s")")
            } else {
                if findNext(wrapAround: true) { insert(lastReplace) }
            }
        }
        app.push(d)
    }

    private func findNextSilent() -> Bool {
        let needle = Array(lastSearch)
        var r = row, c = col
        while r < lines.count {
            var cc = c
            while cc + needle.count <= lines[r].count {
                if matches(r, cc, needle) { anchor = (r, cc); row = r; col = cc + needle.count; return true }
                cc += 1
            }
            r += 1; c = 0
        }
        return false
    }

    // MARK: Save / close

    @discardableResult
    private func save() -> Bool {
        var text = lines.map { String($0) }.joined(separator: "\n")
        if crlf { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        guard let data = text.data(using: latin1 ? .isoLatin1 : .utf8) else {
            app.message("Error", "Cannot encode text", error: true); return false
        }
        do {
            // Preserve permissions of existing files.
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            try data.write(to: url, options: .atomic)
            if let p = attrs?[.posixPermissions] { try? FileManager.default.setAttributes([.posixPermissions: p], ofItemAtPath: url.path) }
            modified = false
            app.toast("Saved \(url.lastPathComponent)")
            return true
        } catch {
            app.message("Error", "Cannot save file:\n\(url.path)\n\n\(error.localizedDescription)", error: true)
            return false
        }
    }

    private func saveAs() {
        let d = Dialog(app: app, title: "Save as", buttons: ["Save", "Cancel"], width: 60)
        d.text("Save file as:").field(url.path)
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let u = expandPath(d.fields[0].text, relativeTo: url.deletingLastPathComponent())
            let old = url
            url = u
            if !save() { url = old }
        }
        app.push(d)
    }

    private func tryClose() {
        guard modified else { app.pop(self); onClose?(); return }
        app.message("Editor", "\(url.lastPathComponent) has been modified.\nSave changes?", buttons: ["Save", "Don't save", "Continue editing"]) { [unowned self] r in
            switch r {
            case 0: if save() { app.pop(self); onClose?() }
            case 1: app.pop(self); onClose?()
            default: break
            }
        }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        switch kind {
        case .scrollUp: top = max(0, top - 3); row = max(top, min(row, top + h - 1))
        case .scrollDown: top = max(0, min(lines.count - h, top + 3)); row = max(top, min(row, top + h - 1))
        case .down, .drag, .double:
            if y == app.screenRows - 1 { if kind == .down { app.keyBarClick(x) { self.key(Key(code: .f($0))) } }; return }
            guard y >= 1, y <= h else { return }
            let r = min(lines.count - 1, top + y - 1)
            if kind == .down { anchor = nil } else if kind == .drag && anchor == nil { anchor = (row, col) }
            row = r; col = colFor(r, vcol: left + x)
            if kind == .double {
                var a = col, b = col
                while a > 0 && lines[r][a - 1].isLetterOrDigit { a -= 1 }
                while b < lines[r].count && lines[r][b].isLetterOrDigit { b += 1 }
                anchor = (r, a); col = b
            }
        default: break
        }
    }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber || self == "_" }
}
