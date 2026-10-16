import AppKit

// MARK: - Colors and roles

enum Role: Int, CaseIterable {
    case panel, panelFrame, panelHeader, panelTitle, panelTitleActive
    case dir, exec, archive, hidden, symlink, selected, cursor, cursorSelected, panelDim
    case cmdline, keyNum, keyLabel
    case menuBar, menuBarSel, menuItem, menuItemSel, menuHot, menuDisabled
    case dialog, dialogFrame, dialogInput, dialogButton, dialogButtonSel, dialogHi
    case error, errorFrame, errorInput, errorButton, errorButtonSel
    case viewer, viewerStatus, viewerFound, editor, editorSel, editorStatus
    case console, consoleCmd, help, helpHeading, helpKey, shadow, quickSearch
    case progressFill, progressEmpty
}

struct Attr: Equatable { var fg: UInt8; var bg: UInt8 }

private let roleTable: [Role: Attr] = [
    .panel: Attr(fg: 11, bg: 1), .panelFrame: Attr(fg: 11, bg: 1), .panelHeader: Attr(fg: 14, bg: 1),
    .panelTitle: Attr(fg: 11, bg: 1), .panelTitleActive: Attr(fg: 0, bg: 3),
    .dir: Attr(fg: 15, bg: 1), .exec: Attr(fg: 10, bg: 1), .archive: Attr(fg: 13, bg: 1),
    .hidden: Attr(fg: 3, bg: 1), .symlink: Attr(fg: 7, bg: 1), .selected: Attr(fg: 14, bg: 1),
    .cursor: Attr(fg: 0, bg: 3), .cursorSelected: Attr(fg: 14, bg: 3), .panelDim: Attr(fg: 3, bg: 1),
    .cmdline: Attr(fg: 7, bg: 0), .keyNum: Attr(fg: 7, bg: 0), .keyLabel: Attr(fg: 0, bg: 3),
    .menuBar: Attr(fg: 0, bg: 3), .menuBarSel: Attr(fg: 15, bg: 0), .menuItem: Attr(fg: 0, bg: 3),
    .menuItemSel: Attr(fg: 15, bg: 0), .menuHot: Attr(fg: 1, bg: 3), .menuDisabled: Attr(fg: 8, bg: 3),
    .dialog: Attr(fg: 0, bg: 7), .dialogFrame: Attr(fg: 15, bg: 7), .dialogInput: Attr(fg: 0, bg: 3),
    .dialogButton: Attr(fg: 0, bg: 7), .dialogButtonSel: Attr(fg: 0, bg: 3), .dialogHi: Attr(fg: 1, bg: 7),
    .error: Attr(fg: 15, bg: 4), .errorFrame: Attr(fg: 15, bg: 4), .errorInput: Attr(fg: 0, bg: 7),
    .errorButton: Attr(fg: 15, bg: 4), .errorButtonSel: Attr(fg: 0, bg: 7),
    .viewer: Attr(fg: 11, bg: 1), .viewerStatus: Attr(fg: 0, bg: 3), .viewerFound: Attr(fg: 0, bg: 14),
    .editor: Attr(fg: 11, bg: 1), .editorSel: Attr(fg: 0, bg: 3), .editorStatus: Attr(fg: 0, bg: 3),
    .console: Attr(fg: 7, bg: 0), .consoleCmd: Attr(fg: 14, bg: 0),
    .help: Attr(fg: 0, bg: 3), .helpHeading: Attr(fg: 15, bg: 3), .helpKey: Attr(fg: 1, bg: 3),
    .shadow: Attr(fg: 8, bg: 0), .quickSearch: Attr(fg: 0, bg: 3),
    .progressFill: Attr(fg: 1, bg: 7), .progressEmpty: Attr(fg: 8, bg: 7),
]

let roleAttrs: [Attr] = Role.allCases.map { roleTable[$0] ?? Attr(fg: 7, bg: 0) }

struct Theme {
    let name: String
    let palette: [CGColor]
    init(_ name: String, _ hex: [UInt32]) {
        self.name = name
        palette = hex.map {
            CGColor(srgbRed: CGFloat(($0 >> 16) & 0xff) / 255, green: CGFloat(($0 >> 8) & 0xff) / 255,
                    blue: CGFloat($0 & 0xff) / 255, alpha: 1)
        }
    }
}

let themes: [Theme] = [
    Theme("Classic Blue", [0x000000, 0x0000AA, 0x00AA00, 0x00AAAA, 0xAA0000, 0xAA00AA, 0xAA5500, 0xAAAAAA,
                             0x555555, 0x5555FF, 0x55FF55, 0x55FFFF, 0xFF5555, 0xFF55FF, 0xFFFF55, 0xFFFFFF]),
    Theme("Midnight", [0x0B0D12, 0x161B26, 0x4FB06A, 0x2F7890, 0xA83838, 0x9A5BC4, 0xB08A3A, 0xB8BEC9,
                       0x4A5162, 0x6C9BFF, 0x7EE08F, 0x9AD8EA, 0xFF7A7A, 0xD89BFF, 0xF2D16B, 0xF4F6FA]),
    Theme("Amber", [0x0F0A00, 0x150E00, 0xC88400, 0xD99A00, 0x7A2A00, 0x8A5A00, 0x8A5A00, 0xFFB000,
                    0x6B4A00, 0xFFC640, 0xFFD060, 0xFFB000, 0xFFD27A, 0xFFC640, 0xFFE6A8, 0xFFEDC4]),
    Theme("Navy", [0x000000, 0x000080, 0x008000, 0x008080, 0x800000, 0x800080, 0x808000, 0xC0C0C0,
                          0x808080, 0x0000FF, 0x00FF00, 0x00FFFF, 0xFF0000, 0xFF00FF, 0xFFFF00, 0xFFFFFF]),
]

// MARK: - Character grid

struct Cell: Equatable {
    var ch: Character = " "
    var a = Attr(fg: 7, bg: 0)
}

struct ImageOverlay { let x, y, w, h: Int; let image: NSImage }

final class Screen {
    private(set) var cols = 80
    private(set) var rows = 25
    var cells: [Cell] = Array(repeating: Cell(), count: 80 * 25)
    var caret: (x: Int, y: Int)?
    var overlays: [ImageOverlay] = []

    func resize(_ c: Int, _ r: Int) {
        if c != cols || r != rows {
            cols = c; rows = r
            cells = Array(repeating: Cell(), count: c * r)
        }
        caret = nil
        overlays.removeAll()
    }

    @inline(__always) func attr(_ role: Role) -> Attr { roleAttrs[role.rawValue] }

    func clear(_ role: Role) {
        let c = Cell(ch: " ", a: attr(role))
        for i in 0..<cells.count { cells[i] = c }
    }

    @inline(__always) func set(_ x: Int, _ y: Int, _ ch: Character, _ a: Attr) {
        guard x >= 0, y >= 0, x < cols, y < rows else { return }
        cells[y * cols + x] = Cell(ch: ch, a: a)
    }

    func cell(_ x: Int, _ y: Int) -> Cell? {
        guard x >= 0, y >= 0, x < cols, y < rows else { return nil }
        return cells[y * cols + x]
    }

    func putc(_ x: Int, _ y: Int, _ ch: Character, _ role: Role) { set(x, y, ch, attr(role)) }

    /// Writes text; if `width` is given the text is truncated/padded to exactly that width.
    @discardableResult
    func put(_ x: Int, _ y: Int, _ text: String, _ role: Role, width: Int? = nil) -> Int {
        put(x, y, text, attr(role), width: width)
    }

    @discardableResult
    func put(_ x: Int, _ y: Int, _ text: String, _ a: Attr, width: Int? = nil) -> Int {
        var cx = x
        let limit = width.map { x + $0 } ?? cols
        for ch in text {
            if cx >= limit { break }
            set(cx, y, ch == "\t" ? " " : ch, a)
            cx += 1
        }
        if let w = width {
            while cx < x + w { set(cx, y, " ", a); cx += 1 }
        }
        return cx - x
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ ch: Character = " ", _ role: Role) {
        let a = attr(role)
        for yy in y..<(y + max(0, h)) { for xx in x..<(x + max(0, w)) { set(xx, yy, ch, a) } }
    }

    func recolor(_ x: Int, _ y: Int, _ w: Int, _ role: Role) { recolor(x, y, w, attr(role)) }

    func recolor(_ x: Int, _ y: Int, _ w: Int, _ a: Attr) {
        guard y >= 0, y < rows else { return }
        for xx in max(0, x)..<min(cols, x + max(0, w)) { cells[y * cols + xx].a = a }
    }

    func recolorFg(_ x: Int, _ y: Int, _ w: Int, fg: UInt8) {
        guard y >= 0, y < rows else { return }
        for xx in max(0, x)..<min(cols, x + max(0, w)) { cells[y * cols + xx].a.fg = fg }
    }

    enum Line { case single, double }

    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ role: Role, _ style: Line = .double,
             title: String? = nil, titleRole: Role? = nil, fill: Bool = true) {
        guard w >= 2, h >= 2 else { return }
        let a = attr(role)
        let (tl, tr, bl, br, hz, vt): (Character, Character, Character, Character, Character, Character) =
            style == .double ? ("╔", "╗", "╚", "╝", "═", "║") : ("┌", "┐", "└", "┘", "─", "│")
        if fill { self.fill(x + 1, y + 1, w - 2, h - 2, " ", role) }
        set(x, y, tl, a); set(x + w - 1, y, tr, a); set(x, y + h - 1, bl, a); set(x + w - 1, y + h - 1, br, a)
        for xx in (x + 1)..<(x + w - 1) { set(xx, y, hz, a); set(xx, y + h - 1, hz, a) }
        for yy in (y + 1)..<(y + h - 1) { set(x, yy, vt, a); set(x + w - 1, yy, vt, a) }
        if let t = title, !t.isEmpty {
            let s = " " + truncate(t, w - 6) + " "
            put(x + (w - s.count) / 2, y, s, titleRole ?? role)
        }
    }

    /// Horizontal separator inside a double box: ╟───╢
    func separator(_ x: Int, _ y: Int, _ w: Int, _ role: Role, double: Bool = true) {
        let a = attr(role)
        set(x, y, double ? "╟" : "├", a)
        set(x + w - 1, y, double ? "╢" : "┤", a)
        for xx in (x + 1)..<(x + w - 1) { set(xx, y, "─", a) }
    }

    func shadow(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
        let a = attr(.shadow)
        for yy in (y + 1)..<(y + h + 1) { recolor(x + w, yy, 2, a) }
        recolor(x + 2, y + h, w, a)
    }
}

// MARK: - String helpers

func truncate(_ s: String, _ w: Int) -> String {
    if w <= 0 { return "" }
    if s.count <= w { return s }
    if w == 1 { return "…" }
    return String(s.prefix(w - 1)) + "…"
}

/// Truncate keeping the end visible (good for paths).
func truncateLeft(_ s: String, _ w: Int) -> String {
    if w <= 0 { return "" }
    if s.count <= w { return s }
    return "…" + String(s.suffix(w - 1))
}

func pad(_ s: String, _ w: Int, right: Bool = false) -> String {
    let t = truncate(s, w)
    let p = String(repeating: " ", count: max(0, w - t.count))
    return right ? p + t : t + p
}

func center(_ s: String, _ w: Int) -> String {
    let t = truncate(s, w)
    let l = (w - t.count) / 2
    return String(repeating: " ", count: l) + t + String(repeating: " ", count: w - t.count - l)
}

func wrapText(_ s: String, _ w: Int) -> [String] {
    var out: [String] = []
    for para in s.components(separatedBy: "\n") {
        var line = ""
        for word in para.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(word)
            while word.count > w {
                if !line.isEmpty { out.append(line); line = "" }
                out.append(String(word.prefix(w))); word = String(word.dropFirst(w))
            }
            if line.isEmpty { line = word } else if line.count + 1 + word.count <= w { line += " " + word } else {
                out.append(line); line = word
            }
        }
        out.append(line)
    }
    return out
}

let groupedFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.groupingSeparator = ","
    f.usesGroupingSeparator = true
    return f
}()

func grouped(_ n: Int64) -> String { groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)" }

func humanSize(_ n: Int64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var v = Double(n); var i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return i == 0 ? "\(n) B" : String(format: v < 10 ? "%.2f %@" : v < 100 ? "%.1f %@" : "%.0f %@", v, units[i])
}

/// Size formatted to fit a column: grouped digits if possible, otherwise scaled with K/M/G.
func columnSize(_ n: Int64, _ w: Int) -> String {
    let g = grouped(n)
    if g.count <= w { return g }
    let p = "\(n)"
    if p.count <= w { return p }
    let units = ["K", "M", "G", "T", "P"]
    var v = Double(n); var i = -1
    repeat { v /= 1024; i += 1 } while String(format: "%.0f%@", v, units[i]).count > w && i < units.count - 1
    return String(format: "%.0f%@", v, units[i])
}

func abbreviatePath(_ p: String) -> String {
    let home = NSHomeDirectory()
    if p == home { return "~" }
    if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
    return p
}

func expandPath(_ p: String, relativeTo base: URL) -> URL {
    var s = p.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 { s = String(s.dropFirst().dropLast()) }
    s = (s as NSString).expandingTildeInPath
    if s.hasPrefix("/") { return URL(fileURLWithPath: s).standardizedFileURL }
    return base.appendingPathComponent(s).standardizedFileURL
}

func shellQuote(_ s: String) -> String {
    if s.range(of: "^[A-Za-z0-9_./+-]+$", options: .regularExpression) != nil { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func matchesMask(_ name: String, _ mask: String) -> Bool {
    let parts = mask.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
    if parts.isEmpty { return true }
    for p in parts {
        if fnmatch(p, name, FNM_CASEFOLD) == 0 { return true }
    }
    return false
}
