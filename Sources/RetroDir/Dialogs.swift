import AppKit

// MARK: - Single-line text editor

final class LineEdit {
    var chars: [Character]
    var pos: Int
    var scroll = 0
    var fresh: Bool   // first keystroke replaces the whole text (like NC dialogs)

    init(_ text: String = "", selectAll: Bool = true) {
        chars = Array(text)
        pos = chars.count
        fresh = selectAll && !text.isEmpty
    }

    var text: String {
        get { String(chars) }
        set { chars = Array(newValue); pos = chars.count; fresh = false }
    }

    func insert(_ s: String) {
        if fresh { chars = []; pos = 0; fresh = false }
        let a = Array(s.replacingOccurrences(of: "\n", with: " "))
        chars.insert(contentsOf: a, at: pos)
        pos += a.count
    }

    /// Returns true if the key was consumed.
    @discardableResult
    func key(_ k: Key) -> Bool {
        if let c = k.text { insert(String(c)); return true }
        let wasFresh = fresh
        fresh = false
        switch (k.code, k.mods) {
        case (.left, []): pos = max(0, pos - 1)
        case (.right, []): pos = min(chars.count, pos + 1)
        case (.left, [.alt]), (.left, [.ctrl]): pos = wordStart(pos)
        case (.right, [.alt]), (.right, [.ctrl]): pos = wordEnd(pos)
        case (.home, _), (.left, [.cmd]): pos = 0
        case (.end, _), (.right, [.cmd]): pos = chars.count
        case (.backspace, []):
            if wasFresh { chars = []; pos = 0 } else if pos > 0 { chars.remove(at: pos - 1); pos -= 1 }
        case (.backspace, [.alt]):
            let s = wordStart(pos); chars.removeSubrange(s..<pos); pos = s
        case (.backspace, [.cmd]), (.char("u"), [.ctrl]):
            chars.removeSubrange(0..<pos); pos = 0
        case (.delete, []):
            if wasFresh { chars = []; pos = 0 } else if pos < chars.count { chars.remove(at: pos) }
        case (.char("y"), [.ctrl]): chars = []; pos = 0
        case (.char("k"), [.ctrl]): chars.removeSubrange(pos..<chars.count)
        case (.char("a"), [.ctrl]): pos = 0
        case (.char("e"), [.ctrl]): pos = chars.count
        case (.char("v"), [.cmd]):
            if let s = NSPasteboard.general.string(forType: .string) { insert(s) }
        case (.char("c"), [.cmd]):
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        default:
            fresh = wasFresh
            return false
        }
        return true
    }

    private func wordStart(_ p: Int) -> Int {
        var i = p
        while i > 0 && chars[i - 1] == " " { i -= 1 }
        while i > 0 && chars[i - 1] != " " && chars[i - 1] != "/" { i -= 1 }
        return i == p && i > 0 ? i - 1 : i
    }

    private func wordEnd(_ p: Int) -> Int {
        var i = p
        while i < chars.count && (chars[i] == " " || chars[i] == "/") { i += 1 }
        while i < chars.count && chars[i] != " " && chars[i] != "/" { i += 1 }
        return i
    }

    /// Draw into a field of width w; sets the caret if focused.
    func render(_ s: Screen, _ x: Int, _ y: Int, _ w: Int, _ role: Role, focused: Bool, selRole: Role = .cursor) {
        if pos < scroll { scroll = pos }
        if pos >= scroll + w { scroll = pos - w + 1 }
        scroll = max(0, min(scroll, max(0, chars.count - w + 1)))
        let visible = String(chars[min(scroll, chars.count)..<min(chars.count, scroll + w)])
        s.put(x, y, visible, role, width: w)
        if focused && fresh && !chars.isEmpty {
            s.recolor(x, y, min(w, chars.count - scroll), .menuItemSel)
        }
        if focused { s.caret = (x + pos - scroll, y) }
    }
}

// MARK: - Generic dialog

final class Dialog: Layer {
    enum Row {
        case text(String)
        case center(String)
        case hi(String)
        case field(Int)
        case labeledField(String, Int)
        case check(Int)
        case separator
        case blank
    }

    unowned let app: Commander
    var title: String
    var rows: [Row] = []
    var fields: [LineEdit] = []
    var checks: [(label: String, on: Bool)] = []
    var buttons: [String]
    var isError: Bool
    var minWidth: Int
    var focus = 0
    var onClose: ((Int?, Dialog) -> Void)?
    var cancelIndex: Int?

    private var buttonRects: [(x: Int, y: Int, w: Int)] = []
    private var checkRects: [(x: Int, y: Int, w: Int)] = []
    private var fieldRects: [(x: Int, y: Int, w: Int)] = []

    init(app: Commander, title: String, buttons: [String] = ["OK", "Cancel"], error: Bool = false, width: Int = 50) {
        self.app = app
        self.title = title
        self.buttons = buttons
        self.isError = error
        self.minWidth = width
    }

    @discardableResult func text(_ t: String) -> Dialog { rows.append(.text(t)); return self }
    @discardableResult func centered(_ t: String) -> Dialog { rows.append(.center(t)); return self }
    @discardableResult func hi(_ t: String) -> Dialog { rows.append(.hi(t)); return self }
    @discardableResult func field(_ initial: String, label: String? = nil, selectAll: Bool = true) -> Dialog {
        fields.append(LineEdit(initial, selectAll: selectAll))
        rows.append(label.map { .labeledField($0, fields.count - 1) } ?? .field(fields.count - 1))
        return self
    }
    @discardableResult func check(_ label: String, _ on: Bool) -> Dialog {
        checks.append((label, on)); rows.append(.check(checks.count - 1)); return self
    }
    @discardableResult func sep() -> Dialog { rows.append(.separator); return self }
    @discardableResult func blank() -> Dialog { rows.append(.blank); return self }

    var focusCount: Int { fields.count + checks.count + buttons.count }

    func focusDefault() {
        focus = fields.isEmpty ? fields.count + checks.count : 0
    }

    private var role: Role { isError ? .error : .dialog }
    private var frameRole: Role { isError ? .errorFrame : .dialogFrame }

    func render(_ s: Screen) {
        let contentW = rows.map { r -> Int in
            switch r {
            case .text(let t), .center(let t), .hi(let t): return t.count
            case .check(let i): return checks[i].label.count + 4
            default: return 0
            }
        }.max() ?? 0
        let btnW = buttons.reduce(0) { $0 + $1.count + 5 }
        let w = min(s.cols - 4, max(minWidth, contentW + 6, btnW + 6))
        let h = rows.count + 5
        let x = (s.cols - w) / 2
        let y = max(1, (s.rows - h) / 2 - 1)
        s.box(x, y, w, h, frameRole, .double, title: title)
        s.shadow(x, y, w, h)
        let iw = w - 6
        buttonRects = []; checkRects = []; fieldRects = []
        var yy = y + 2
        for r in rows {
            switch r {
            case .text(let t): s.put(x + 3, yy, truncate(t, iw), role)
            case .center(let t): s.put(x + 3, yy, center(t, iw), role)
            case .hi(let t): s.put(x + 3, yy, truncate(t, iw), isError ? .error : .dialogHi)
            case .field(let i):
                fieldRects.append((x + 3, yy, iw))
                fields[i].render(s, x + 3, yy, iw, isError ? .errorInput : .dialogInput, focused: focus == i)
            case .labeledField(let label, let i):
                s.put(x + 3, yy, label, role)
                let fx = x + 3 + label.count + 1
                fieldRects.append((fx, yy, iw - label.count - 1))
                fields[i].render(s, fx, yy, iw - label.count - 1, isError ? .errorInput : .dialogInput, focused: focus == i)
            case .check(let i):
                let t = "[\(checks[i].on ? "x" : " ")] " + checks[i].label
                checkRects.append((x + 3, yy, t.count))
                s.put(x + 3, yy, t, role)
                if focus == fields.count + i {
                    s.recolor(x + 3, yy, 3, isError ? .errorButtonSel : .dialogButtonSel)
                    s.caret = (x + 4, yy)
                }
            case .separator: s.separator(x, yy, w, frameRole, double: true)
            case .blank: break
            }
            yy += 1
        }
        yy += 1
        let labels = buttons.map { "[ \($0) ]" }
        let total = labels.reduce(0) { $0 + $1.count } + (labels.count - 1) * 2
        var bx = x + (w - total) / 2
        for (i, l) in labels.enumerated() {
            let focused = focus == fields.count + checks.count + i
            s.put(bx, yy, l, focused ? (isError ? .errorButtonSel : .dialogButtonSel) : (isError ? .errorButton : .dialogButton))
            buttonRects.append((bx, yy, l.count))
            bx += l.count + 2
        }
    }

    func close(_ result: Int?) {
        app.pop(self)
        onClose?(result, self)
    }

    func key(_ k: Key) {
        let nf = fields.count, nc = checks.count
        switch (k.code, k.mods) {
        case (.escape, _), (.f(10), []):
            close(cancelIndex)
            return
        case (.tab, []), (.down, []):
            focus = (focus + 1) % focusCount; return
        case (.tab, [.shift]), (.up, []):
            focus = (focus - 1 + focusCount) % focusCount; return
        case (.enter, _):
            if focus >= nf + nc { close(focus - nf - nc) } else { close(0) }
            return
        default: break
        }
        if focus < nf {
            fields[focus].key(k)
        } else if focus < nf + nc {
            if k.code == .char(" ") { checks[focus - nf].on.toggle() }
        } else {
            switch k.code {
            case .left: if focus > nf + nc { focus -= 1 }
            case .right: if focus < focusCount - 1 { focus += 1 }
            case .char(" "): close(focus - nf - nc)
            case .char(let c):
                // Hotkey: first letter of a button
                if let i = buttons.firstIndex(where: { $0.lowercased().first == Character(c.lowercased()) }) { close(i) }
            default: break
            }
        }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        guard kind == .down || kind == .double else { return }
        for (i, r) in buttonRects.enumerated() where y == r.y && x >= r.x && x < r.x + r.w { close(i); return }
        for (i, r) in checkRects.enumerated() where y == r.y && x >= r.x && x < r.x + r.w {
            checks[i].on.toggle(); focus = fields.count + i; return
        }
        for (i, r) in fieldRects.enumerated() where y == r.y && x >= r.x && x < r.x + r.w {
            focus = i
            fields[i].fresh = false
            fields[i].pos = min(fields[i].chars.count, fields[i].scroll + x - r.x)
            return
        }
    }
}

// MARK: - List picker (volumes, history, hotlist, find results, user menu)

final class ListPicker: Layer {
    unowned let app: Commander
    var title: String
    var items: [(label: String, hint: String)]
    var cursor = 0
    var top = 0
    var footer: String?
    var minWidth = 40
    var onSelect: ((Int, ListPicker) -> Void)?
    var onKey: ((Key, ListPicker) -> Bool)?
    var onCancel: ((ListPicker) -> Void)?
    var filterable = true
    private var filterText = ""
    private var rect = (x: 0, y: 0, w: 0, h: 0)
    private var visibleRows = 10

    init(app: Commander, title: String, items: [(String, String)]) {
        self.app = app
        self.title = title
        self.items = items.map { (label: $0.0, hint: $0.1) }
    }

    func render(_ s: Screen) {
        let contentW = items.map { $0.label.count + ($0.hint.isEmpty ? 0 : $0.hint.count + 3) }.max() ?? 10
        let w = min(s.cols - 6, max(minWidth, contentW + 6, title.count + 8, (footer?.count ?? 0) + 6))
        let maxRows = s.rows - 8
        visibleRows = max(3, min(maxRows, max(items.count, 1)))
        let h = visibleRows + 2 + (footer == nil ? 0 : 2)
        let x = (s.cols - w) / 2
        let y = max(1, (s.rows - h) / 2 - 1)
        rect = (x, y, w, h)
        s.box(x, y, w, h, .menuItem, .double, title: title)
        s.shadow(x, y, w, h)
        cursor = max(0, min(cursor, items.count - 1))
        if cursor < top { top = cursor }
        if cursor >= top + visibleRows { top = cursor - visibleRows + 1 }
        let iw = w - 4
        for r in 0..<visibleRows {
            let i = top + r
            guard i < items.count else { break }
            let it = items[i]
            let yy = y + 1 + r
            let sel = i == cursor
            let hw = it.hint.isEmpty ? 0 : min(it.hint.count, iw / 2)
            s.put(x + 1, yy, " " + truncate(it.label, iw - hw - (hw > 0 ? 1 : 0)), sel ? .menuItemSel : .menuItem, width: iw + 2)
            if hw > 0 { s.put(x + 2 + iw - hw, yy, truncateLeft(it.hint, hw), sel ? .menuItemSel : .menuHot) }
        }
        if items.isEmpty { s.put(x + 2, y + 1, "(empty)", .menuDisabled) }
        if let f = footer {
            s.separator(x, y + h - 3, w, .menuItem)
            s.put(x + 2, y + h - 2, truncate(f, iw), .menuItem)
        }
        if !filterText.isEmpty {
            let t = " Filter: \(filterText) "
            s.put(x + 2, y + h - 1, t, .menuItemSel)
        }
        if items.count > visibleRows {
            let py = y + 1 + Int(Double(cursor) / Double(max(1, items.count - 1)) * Double(visibleRows - 1))
            s.putc(x + w - 1, py, "▓", .menuItem)
        }
    }

    func close() { app.pop(self) }

    func key(_ k: Key) {
        if let h = onKey, h(k, self) { return }
        switch (k.code, k.mods) {
        case (.escape, _), (.f(10), []):
            if !filterText.isEmpty { filterText = ""; return }
            close(); onCancel?(self)
        case (.up, []): cursor = max(0, cursor - 1)
        case (.down, []): cursor = min(items.count - 1, cursor + 1)
        case (.pageUp, []): cursor = max(0, cursor - visibleRows)
        case (.pageDown, []): cursor = min(items.count - 1, cursor + visibleRows)
        case (.home, _): cursor = 0
        case (.end, _): cursor = max(0, items.count - 1)
        case (.enter, _):
            guard items.indices.contains(cursor) else { return }
            close(); onSelect?(cursor, self)
        case (.backspace, []):
            if !filterText.isEmpty { filterText.removeLast() }
        default:
            if filterable, let c = k.text {
                filterText.append(c)
                let f = filterText.lowercased()
                if let i = items.firstIndex(where: { $0.label.lowercased().contains(f) }) { cursor = i }
            }
        }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        switch kind {
        case .scrollUp: cursor = max(0, cursor - 1)
        case .scrollDown: cursor = min(items.count - 1, cursor + 1)
        case .down, .double:
            guard x >= rect.x, x < rect.x + rect.w, y > rect.y, y < rect.y + 1 + visibleRows else {
                if kind == .down && !(x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h) { close(); onCancel?(self) }
                return
            }
            let i = top + (y - rect.y - 1)
            guard items.indices.contains(i) else { return }
            cursor = i
            if kind == .double || true { close(); onSelect?(i, self) }
        default: break
        }
    }
}

// MARK: - Progress dialog

final class ProgressLayer: Layer {
    unowned let app: Commander
    var title: String
    var provider: () -> (lines: [String], file: Double?, total: Double?, footer: String)
    var onCancel: () -> Void

    init(app: Commander, title: String, provider: @escaping () -> (lines: [String], file: Double?, total: Double?, footer: String), onCancel: @escaping () -> Void) {
        self.app = app
        self.title = title
        self.provider = provider
        self.onCancel = onCancel
    }

    func render(_ s: Screen) {
        let p = provider()
        let w = min(s.cols - 4, 64)
        let h = p.lines.count + (p.file == nil ? 0 : 1) + (p.total == nil ? 0 : 1) + 6
        let x = (s.cols - w) / 2, y = max(1, (s.rows - h) / 2 - 1)
        s.box(x, y, w, h, .dialogFrame, title: title)
        s.shadow(x, y, w, h)
        var yy = y + 2
        let iw = w - 6
        for l in p.lines { s.put(x + 3, yy, truncateLeft(l, iw), .dialog); yy += 1 }
        func bar(_ f: Double) {
            let pct = String(format: " %3d%%", Int(f * 100))
            let bw = iw - pct.count
            let n = Int(Double(bw) * max(0, min(1, f)))
            s.put(x + 3, yy, String(repeating: "█", count: n), .progressFill)
            s.put(x + 3 + n, yy, String(repeating: "░", count: bw - n), .progressEmpty)
            s.put(x + 3 + bw, yy, pct, .dialog)
            yy += 1
        }
        if let f = p.file { bar(f) }
        if let t = p.total { bar(t) }
        s.put(x + 3, yy, truncate(p.footer, iw), .dialogHi)
        yy += 2
        s.put(x + (w - 10) / 2, yy, "[ Cancel ]", .dialogButtonSel)
    }

    func key(_ k: Key) {
        if k.code == .escape || k.code == .enter || k.isCtrl("c") { onCancel() }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {}
}

// MARK: - Help / text box

final class TextBox: Layer {
    unowned let app: Commander
    let title: String
    let lines: [String]
    var top = 0
    private var visible = 10

    init(app: Commander, title: String, text: String) {
        self.app = app
        self.title = title
        self.lines = text.components(separatedBy: "\n")
    }

    func render(_ s: Screen) {
        let w = min(s.cols - 4, max(60, (lines.map(\.count).max() ?? 40) + 6))
        let h = min(s.rows - 3, lines.count + 4)
        let x = (s.cols - w) / 2, y = max(1, (s.rows - h) / 2)
        visible = h - 4
        top = max(0, min(top, lines.count - visible))
        s.box(x, y, w, h, .help, .double, title: title)
        s.shadow(x, y, w, h)
        for i in 0..<visible {
            let li = top + i
            guard li < lines.count else { break }
            let l = lines[li]
            let yy = y + 2 + i
            if l.hasPrefix("# ") {
                s.put(x + 3, yy, String(l.dropFirst(2)), .helpHeading)
            } else if let r = l.range(of: "  ") , l.hasPrefix(" ") == false, l.first != nil, l.distance(from: l.startIndex, to: r.lowerBound) < 22 {
                let keyPart = String(l[..<r.lowerBound])
                s.put(x + 3, yy, keyPart, .helpKey)
                s.put(x + 3 + keyPart.count, yy, truncate(String(l[r.lowerBound...]), w - 6 - keyPart.count), .help)
            } else {
                s.put(x + 3, yy, truncate(l, w - 6), .help)
            }
        }
        if lines.count > visible {
            s.put(x + w - 16, y + h - 1, " \(top + 1)-\(min(lines.count, top + visible))/\(lines.count) ", .help)
        }
    }

    func key(_ k: Key) {
        switch k.code {
        case .escape, .enter, .f(10), .f(1), .f(3): app.pop(self)
        case .up: top -= 1
        case .down: top += 1
        case .pageUp: top -= visible
        case .pageDown, .char(" "): top += visible
        case .home: top = 0
        case .end: top = lines.count
        case .char("q"): app.pop(self)
        default: break
        }
        top = max(0, min(top, max(0, lines.count - visible)))
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        if kind == .scrollUp { top = max(0, top - 3) }
        if kind == .scrollDown { top = max(0, min(top + 3, lines.count - visible)) }
    }
}

// MARK: - Pull-down menu

struct MenuItem {
    let title: String
    var shortcut: String = ""
    var checked: Bool = false
    var action: (() -> Void)?
    static let sep = MenuItem(title: "-")
}

struct PullMenu {
    let title: String
    let items: [MenuItem]
}

final class MenuBarLayer: Layer {
    unowned let app: Commander
    var menus: [PullMenu]
    var current: Int
    var item = 0
    var open = true
    private var titleXs: [(x: Int, w: Int)] = []
    private var dropRect = (x: 0, y: 0, w: 0, h: 0)

    init(app: Commander, menus: [PullMenu], start: Int) {
        self.app = app
        self.menus = menus
        self.current = start
        item = firstEnabled(from: 0, dir: 1)
    }

    static func titlePositions(_ menus: [String]) -> [(x: Int, w: Int)] {
        var x = 2
        return menus.map { t in defer { x += t.count + 4 }; return (x, t.count + 2) }
    }

    private func firstEnabled(from i: Int, dir: Int) -> Int {
        let items = menus[current].items
        var j = i
        for _ in 0..<items.count {
            if j < 0 { j = items.count - 1 }
            if j >= items.count { j = 0 }
            if items[j].title != "-" { return j }
            j += dir
        }
        return 0
    }

    func render(_ s: Screen) {
        s.fill(0, 0, s.cols, 1, " ", .menuBar)
        titleXs = MenuBarLayer.titlePositions(menus.map(\.title))
        for (i, m) in menus.enumerated() {
            s.put(titleXs[i].x, 0, " \(m.title) ", i == current ? .menuBarSel : .menuBar)
        }
        guard open else { return }
        let items = menus[current].items
        let lw = items.map(\.title.count).max() ?? 10
        let sw = items.map(\.shortcut.count).max() ?? 0
        let w = lw + sw + 8
        var x = titleXs[current].x - 1
        if x + w > s.cols { x = s.cols - w - 1 }
        let h = items.count + 2
        let y = 1
        dropRect = (x, y, w, h)
        s.box(x, y, w, h, .menuItem, .single)
        s.shadow(x, y, w, h)
        for (i, it) in items.enumerated() {
            let yy = y + 1 + i
            if it.title == "-" { s.separator(x, yy, w, .menuItem, double: false); continue }
            let sel = i == item
            let role: Role = sel ? .menuItemSel : (it.action == nil ? .menuDisabled : .menuItem)
            let mark = it.checked ? "√" : " "
            s.put(x + 1, yy, mark + " " + pad(it.title, lw) + "  " + pad(it.shortcut, sw, right: true) + " ", role, width: w - 2)
        }
    }

    func activate() {
        let it = menus[current].items[item]
        guard let a = it.action else { return }
        app.pop(self)
        a()
    }

    func key(_ k: Key) {
        switch k.code {
        case .escape, .f(9), .f(10): app.pop(self)
        case .left: current = (current - 1 + menus.count) % menus.count; item = firstEnabled(from: 0, dir: 1)
        case .right: current = (current + 1) % menus.count; item = firstEnabled(from: 0, dir: 1)
        case .up: item = firstEnabled(from: item - 1, dir: -1)
        case .down: item = firstEnabled(from: item + 1, dir: 1)
        case .home: item = firstEnabled(from: 0, dir: 1)
        case .end: item = firstEnabled(from: menus[current].items.count - 1, dir: -1)
        case .enter, .char(" "): activate()
        case .char(let c):
            let items = menus[current].items
            if let i = items.firstIndex(where: { $0.title.lowercased().first == Character(c.lowercased()) && $0.action != nil }) {
                item = i; activate()
            }
        default: break
        }
    }

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        guard kind == .down || kind == .double || kind == .drag else { return }
        if y == 0 {
            for (i, t) in titleXs.enumerated() where x >= t.x && x < t.x + t.w {
                if i == current && kind == .down { app.pop(self); return }
                current = i; item = firstEnabled(from: 0, dir: 1); return
            }
            return
        }
        let r = dropRect
        if x > r.x && x < r.x + r.w - 1 && y > r.y && y < r.y + r.h - 1 {
            let i = y - r.y - 1
            if menus[current].items[i].title != "-" { item = i; if kind != .drag { activate() } }
        } else if kind == .down {
            app.pop(self)
        }
    }
}
