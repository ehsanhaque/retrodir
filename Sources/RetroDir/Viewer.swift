import AppKit

/// F3 viewer: text (with wrap) and hex modes, search, goto. Files are memory-mapped.
final class Viewer: Layer {
    var isFullScreen: Bool { true }
    unowned let app: Commander
    let title: String
    let url: URL?
    private let data: Data
    private var lineStarts: [Int] = [0]
    private var hex = false
    private var wrap = false
    private var topLine = 0
    private var topSub = 0
    private var hexTop = 0
    private var leftCol = 0
    private var found: (start: Int, len: Int)?
    private var lastSearch = ""
    private var caseSensitive = false
    private var hexSearch = false
    private var w = 80
    private var h = 23

    init(app: Commander, url: URL) throws {
        self.app = app
        self.url = url
        self.title = url.path
        data = try Data(contentsOf: url, options: .alwaysMapped)
        hex = data.prefix(8192).contains(0)
        indexLines()
    }

    init(app: Commander, title: String, text: String) {
        self.app = app
        self.url = nil
        self.title = title
        data = Data(text.utf8)
        indexLines()
    }

    private func indexLines() {
        var starts = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var off = 0
            let n = raw.count
            starts.reserveCapacity(n / 40 + 1)
            while off < n, let p = memchr(base + off, 0x0A, n - off) {
                let idx = base.distance(to: p)
                starts.append(idx + 1)
                off = idx + 1
            }
        }
        if starts.count > 1 && starts.last == data.count { starts.removeLast() }
        lineStarts = starts
    }

    private var lineCount: Int { lineStarts.count }
    private var hexRows: Int { max(1, (data.count + 15) / 16) }

    private func lineRange(_ i: Int) -> Range<Int> {
        let s = lineStarts[i]
        var e = i + 1 < lineStarts.count ? lineStarts[i + 1] - 1 : data.count
        if e > s && data[e - 1] == 0x0D { e -= 1 }
        return s..<max(s, e)
    }

    private func decode(_ r: Range<Int>) -> [Character] {
        let str = String(decoding: data[r], as: UTF8.self)
        var out: [Character] = []
        out.reserveCapacity(r.count)
        for c in str {
            if c == "\t" {
                repeat { out.append(" ") } while out.count % 8 != 0
            } else if let a = c.asciiValue, a < 32 || a == 127 {
                out.append("·")
            } else {
                out.append(c)
            }
        }
        return out
    }

    private func line(_ i: Int) -> [Character] { decode(lineRange(i)) }

    private func wrapCount(_ i: Int) -> Int { max(1, (line(i).count + w - 1) / max(1, w)) }

    private func lineIndex(forOffset off: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= off { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Rendering

    func render(_ s: Screen) {
        w = s.cols
        h = s.rows - 2
        s.clear(.viewer)
        if hex { renderHex(s) } else { renderText(s) }

        // Status bar
        let pct: Int
        let pos: String
        if hex {
            pct = data.isEmpty ? 100 : min(100, (hexTop * 16 + h * 16) * 100 / max(1, data.count))
            pos = String(format: "Offset 0x%08X", hexTop * 16)
        } else {
            let off = lineStarts.isEmpty ? 0 : lineStarts[min(topLine, lineStarts.count - 1)]
            pct = topLine + h >= lineCount ? 100 : off * 100 / max(1, data.count)
            pos = "Line \(topLine + 1) of \(lineCount)" + (leftCol > 0 ? "  Col +\(leftCol)" : "")
        }
        let flags = (wrap && !hex ? "Wrap " : "") + (hex ? "Hex " : "Text ") + "UTF-8"
        let right = "\(pos)  \(grouped(Int64(data.count))) bytes  \(flags)  \(pct)% "
        s.fill(0, 0, s.cols, 1, " ", .viewerStatus)
        s.put(1, 0, truncateLeft(abbreviatePath(title), max(10, s.cols - right.count - 3)), .viewerStatus)
        s.put(s.cols - right.count, 0, right, .viewerStatus)

        app.drawKeyBar(s, ["Help", wrap ? "Unwrap" : "Wrap", "Quit", hex ? "Text" : "Hex", "Goto", "", "Search", "", "", "Quit"])
    }

    private func renderText(_ s: Screen) {
        var li = topLine
        var sub = topSub
        var y = 1
        while y <= h && li < lineCount {
            let chars = line(li)
            let r = lineRange(li)
            var hl: (Int, Int)?
            if let f = found, f.start >= r.lowerBound, f.start <= r.upperBound {
                let a = decode(r.lowerBound..<f.start).count
                let b = decode(r.lowerBound..<min(r.upperBound, f.start + f.len)).count
                hl = (a, max(a + 1, b))
            }
            if wrap {
                let n = max(1, (chars.count + w - 1) / w)
                while sub < n && y <= h {
                    let from = sub * w
                    let seg = chars.count > from ? String(chars[from..<min(chars.count, from + w)]) : ""
                    s.put(0, y, seg, .viewer)
                    if let (a, b) = hl {
                        let x0 = max(a, from), x1 = min(b, from + w)
                        if x1 > x0 { s.recolor(x0 - from, y, x1 - x0, .viewerFound) }
                    }
                    sub += 1; y += 1
                }
                sub = 0; li += 1
            } else {
                if chars.count > leftCol {
                    s.put(0, y, String(chars[leftCol..<min(chars.count, leftCol + w)]), .viewer)
                }
                if let (a, b) = hl {
                    let x0 = max(a, leftCol), x1 = min(b, leftCol + w)
                    if x1 > x0 { s.recolor(x0 - leftCol, y, x1 - x0, .viewerFound) }
                }
                y += 1; li += 1
            }
        }
    }

    private func renderHex(_ s: Screen) {
        let per = 16
        for row in 0..<h {
            let off = (hexTop + row) * per
            guard off < data.count else { break }
            let end = min(data.count, off + per)
            var line = String(format: "%08X │ ", off)
            var asc = ""
            for i in off..<(off + per) {
                if i < end {
                    let b = data[i]
                    line += String(format: "%02X ", b)
                    asc.append(b >= 32 && b < 127 ? Character(UnicodeScalar(b)) : "·")
                } else {
                    line += "   "
                }
                if i == off + 7 { line += " " }
            }
            line += "│ " + asc
            s.put(0, row + 1, line, .viewer)
            if let f = found {
                for i in max(off, f.start)..<min(end, f.start + f.len) where i >= off {
                    let k = i - off
                    s.recolor(11 + k * 3 + (k > 7 ? 1 : 0), row + 1, 2, .viewerFound)
                    s.recolor(11 + per * 3 + 1 + 2 + k, row + 1, 1, .viewerFound)
                }
            }
        }
    }

    // MARK: Scrolling

    private func scrollDown(_ n: Int) {
        if hex { hexTop = min(max(0, hexRows - h), hexTop + n); return }
        if !wrap { topLine = max(0, min(max(0, lineCount - h), topLine + n)); return }
        for _ in 0..<n {
            let c = wrapCount(topLine)
            if topSub + 1 < c { topSub += 1 } else if topLine + 1 < lineCount { topLine += 1; topSub = 0 } else { break }
        }
    }

    private func scrollUp(_ n: Int) {
        if hex { hexTop = max(0, hexTop - n); return }
        if !wrap { topLine = max(0, topLine - n); return }
        for _ in 0..<n {
            if topSub > 0 { topSub -= 1 } else if topLine > 0 { topLine -= 1; topSub = wrapCount(topLine) - 1 } else { break }
        }
    }

    private func goEnd() {
        if hex { hexTop = max(0, hexRows - h); return }
        topLine = max(0, lineCount - 1); topSub = 0
        if wrap { topSub = wrapCount(topLine) - 1; scrollUp(h - 1) } else { topLine = max(0, lineCount - h) }
    }

    private func reveal(offset: Int) {
        if hex {
            let row = offset / 16
            if row < hexTop || row >= hexTop + h { hexTop = max(0, row - h / 3) }
        } else {
            let li = lineIndex(forOffset: offset)
            if li < topLine || li >= topLine + h - 1 { topLine = max(0, li - h / 3); topSub = 0 }
            if !wrap {
                let col = decode(lineRange(li).lowerBound..<offset).count
                if col < leftCol || col >= leftCol + w - 10 { leftCol = max(0, col - w / 3) }
            }
        }
    }

    // MARK: Search

    private func needleBytes() -> [UInt8]? {
        if hexSearch {
            let hexChars = lastSearch.filter { $0.isHexDigit }
            guard hexChars.count >= 2, hexChars.count % 2 == 0 else { return nil }
            var out: [UInt8] = []
            var it = hexChars.makeIterator()
            while let a = it.next(), let b = it.next() { out.append(UInt8(String([a, b]), radix: 16)!) }
            return out
        }
        return Array(lastSearch.utf8)
    }

    private func searchNext() {
        guard let needle = needleBytes(), !needle.isEmpty else { return }
        let startOff: Int
        if let f = found { startOff = f.start + 1 } else if hex { startOff = hexTop * 16 } else { startOff = lineStarts[min(topLine, lineStarts.count - 1)] }
        let fold = !caseSensitive && !hexSearch
        func low(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
        let nd = fold ? needle.map(low) : needle
        var result: Int?
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let n = raw.count, m = nd.count
            guard m <= n else { return }
            var i = startOff
            let first = nd[0]
            while i <= n - m {
                let b = fold ? low(raw[i]) : raw[i]
                if b == first {
                    var j = 1
                    while j < m && (fold ? low(raw[i + j]) : raw[i + j]) == nd[j] { j += 1 }
                    if j == m { result = i; return }
                }
                i += 1
            }
        }
        if let r = result {
            found = (r, needle.count)
            reveal(offset: r)
        } else {
            app.message("Search", "\"\(lastSearch)\" not found" + (found != nil ? " (no more matches)" : ""))
        }
    }

    private func searchDialog() {
        let d = Dialog(app: app, title: "Search", buttons: ["Search", "Cancel"], width: 56)
        d.text("Search for:").field(lastSearch).check("Case sensitive", caseSensitive).check("Hex bytes (e.g. 4D 5A 90)", hexSearch)
        d.onClose = { [unowned self] r, d in
            guard r == 0, !d.fields[0].text.isEmpty else { return }
            lastSearch = d.fields[0].text
            caseSensitive = d.checks[0].on
            hexSearch = d.checks[1].on
            found = nil
            searchNext()
        }
        app.push(d)
    }

    private func gotoDialog() {
        let d = Dialog(app: app, title: "Go to", buttons: ["Go", "Cancel"], width: 50)
        d.text(hex ? "Offset (hex 0x1F00, decimal, or 50%):" : "Line number, 0x offset, or percent (50%):").field("")
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let t = d.fields[0].text.trimmingCharacters(in: .whitespaces)
            var off: Int?
            if t.hasSuffix("%"), let p = Double(t.dropLast()) { off = Int(Double(data.count) * p / 100) }
            else if t.lowercased().hasPrefix("0x") { off = Int(t.dropFirst(2), radix: 16) }
            else if let n = Int(t) {
                if hex { off = n } else { topLine = max(0, min(lineCount - 1, n - 1)); topSub = 0; return }
            }
            if let o = off {
                let o2 = max(0, min(data.count, o))
                if hex { hexTop = o2 / 16 } else { topLine = lineIndex(forOffset: o2); topSub = 0 }
            }
        }
        app.push(d)
    }

    func key(_ k: Key) {
        switch (k.code, k.mods) {
        case (.escape, _), (.f(3), []), (.f(10), []), (.char("q"), []): app.pop(self)
        case (.down, []), (.enter, []): scrollDown(1)
        case (.up, []): scrollUp(1)
        case (.pageDown, []), (.char(" "), []): scrollDown(h - 1)
        case (.pageUp, []), (.char("b"), []): scrollUp(h - 1)
        case (.home, _), (.up, [.cmd]): topLine = 0; topSub = 0; hexTop = 0; leftCol = 0
        case (.end, _), (.down, [.cmd]): goEnd()
        case (.left, []): leftCol = max(0, leftCol - 1)
        case (.right, []): if !wrap && !hex { leftCol += 1 }
        case (.left, [.shift]): leftCol = max(0, leftCol - 20)
        case (.right, [.shift]): if !wrap && !hex { leftCol += 20 }
        case (.f(2), []), (.char("w"), []):
            wrap.toggle(); topSub = 0; leftCol = 0
        case (.f(4), []), (.char("h"), []):
            // Keep roughly the same position when switching modes.
            if hex { topLine = lineIndex(forOffset: hexTop * 16); topSub = 0 } else { hexTop = lineStarts[min(topLine, lineCount - 1)] / 16 }
            hex.toggle()
        case (.f(5), []), (.char("g"), []): gotoDialog()
        case (.f(7), []), (.char("/"), []), (.char("f"), [.cmd]): searchDialog()
        case (.f(7), [.shift]), (.char("n"), []), (.char("g"), [.cmd]): searchNext()
        case (.f(1), []): app.showHelp()
        case (.char("c"), [.cmd]):
            if let u = url { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string); app.toast("Path copied") }
        default: break
        }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        switch kind {
        case .scrollUp: scrollUp(3)
        case .scrollDown: scrollDown(3)
        case .down:
            if y == app.screenRows - 1 { app.keyBarClick(x) { self.key(Key(code: .f($0))) } }
        default: break
        }
    }
}
