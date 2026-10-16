import AppKit
import Quartz

// MARK: - Keys

struct Mods: OptionSet {
    let rawValue: Int
    static let shift = Mods(rawValue: 1)
    static let ctrl = Mods(rawValue: 2)
    static let alt = Mods(rawValue: 4)
    static let cmd = Mods(rawValue: 8)
}

struct Key {
    enum Code: Equatable {
        case char(Character)
        case up, down, left, right, home, end, pageUp, pageDown
        case enter, escape, tab, backspace, delete, insert
        case f(Int)
    }
    var code: Code
    var mods: Mods = []
    /// Set when Cmd+digit was translated into an F-key (lets the terminal use Cmd-1...9 for tabs).
    var cmdDigit: Int?

    var plain: Bool { mods.isEmpty }
    var shift: Bool { mods.contains(.shift) }
    var ctrl: Bool { mods.contains(.ctrl) }
    var alt: Bool { mods.contains(.alt) }
    var cmd: Bool { mods.contains(.cmd) }

    /// A printable character typed without command modifiers.
    var text: Character? {
        if case .char(let c) = code, mods.subtracting(.shift).isEmpty { return c }
        return nil
    }
    func isCtrl(_ c: Character) -> Bool { code == .char(c) && mods == [.ctrl] }
    func isCmd(_ c: Character) -> Bool { code == .char(c) && mods == [.cmd] }
    func isF(_ n: Int, _ m: Mods = []) -> Bool { code == .f(n) && mods == m }
    func `is`(_ c: Code, _ m: Mods = []) -> Bool { code == c && mods == m }

    static func from(_ e: NSEvent) -> Key? {
        var m: Mods = []
        let f = e.modifierFlags
        if f.contains(.shift) { m.insert(.shift) }
        if f.contains(.control) { m.insert(.ctrl) }
        if f.contains(.option) { m.insert(.alt) }
        if f.contains(.command) { m.insert(.cmd) }
        let special: [UInt16: Code] = [
            126: .up, 125: .down, 123: .left, 124: .right, 115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
            36: .enter, 76: .enter, 53: .escape, 48: .tab, 51: .backspace, 117: .delete, 114: .insert,
            122: .f(1), 120: .f(2), 99: .f(3), 118: .f(4), 96: .f(5), 97: .f(6), 98: .f(7), 100: .f(8),
            101: .f(9), 109: .f(10), 103: .f(11), 111: .f(12),
        ]
        if let c = special[e.keyCode] {
            // Arrow/function keys carry the .function / .numericPad flags; we don't care about them.
            return Key(code: c, mods: m)
        }
        // Cmd+digit acts as a function key (for laptop keyboards without fn): Cmd-1..Cmd-0 = F1..F10.
        let digits: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10]
        if m.contains(.cmd), let n = digits[e.keyCode] {
            m.remove(.cmd)
            return Key(code: .f(n), mods: m, cmdDigit: n)
        }
        if m.contains(.ctrl) || m.contains(.cmd) || m.contains(.alt) {
            if m.contains(.ctrl), let n = digits[e.keyCode] {
                return Key(code: .char(Character(n == 10 ? "0" : "\(n)")), mods: m)
            }
            guard let s = e.charactersIgnoringModifiers, let c = s.lowercased().first else { return nil }
            var mm = m
            if !c.isLetter { /* keep shift for symbols like Cmd-+ */ } else { mm.remove(.shift) }
            return Key(code: .char(c), mods: mm)
        }
        guard let s = e.characters, let c = s.first else { return nil }
        if let a = c.asciiValue, a < 32 || a == 127 { return nil }
        if c.unicodeScalars.first.map({ $0.value >= 0xF700 && $0.value <= 0xF8FF }) == true { return nil }
        return Key(code: .char(c), mods: m.intersection(.shift))
    }
}

enum MouseKind { case down, double, right, scrollUp, scrollDown, drag }

protocol Layer: AnyObject {
    var isFullScreen: Bool { get }
    func render(_ s: Screen)
    func key(_ k: Key)
    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int)
}

extension Layer {
    var isFullScreen: Bool { false }
    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {}
}

// MARK: - Rendering view

final class TermView: NSView, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    unowned let app: Commander
    private(set) var font: NSFont
    private(set) var cellW: CGFloat = 8
    private(set) var cellH: CGFloat = 16
    private var ascent: CGFloat = 12
    private var glyphCache: [Character: GlyphInfo] = [:]
    let screen = Screen()
    private var blinkPhase = 0
    private var timer: Timer?
    private var scrollAccum: CGFloat = 0

    enum GlyphInfo { case glyph(CTFont, CGGlyph), string(String), none }

    init(app: Commander, fontSize: CGFloat) {
        self.app = app
        font = NSFont(name: "Menlo", size: fontSize) ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 640))
        computeMetrics()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setFontSize(_ size: CGFloat) {
        let s = max(8, min(36, size))
        font = NSFont(name: "Menlo", size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular)
        computeMetrics()
        glyphCache.removeAll()
        window?.contentResizeIncrements = NSSize(width: cellW, height: cellH)
        needsDisplay = true
    }

    private func computeMetrics() {
        let ct = font as CTFont
        var g: CGGlyph = 0
        var ch: UniChar = 0x4D // "M"
        CTFontGetGlyphsForCharacters(ct, &ch, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &g, &adv, 1)
        cellW = adv.width
        ascent = ceil(CTFontGetAscent(ct))
        cellH = ascent + ceil(CTFontGetDescent(ct))
    }

    var grid: (cols: Int, rows: Int) {
        (max(40, Int(bounds.width / cellW)), max(14, Int(bounds.height / cellH)))
    }

    func cellAt(_ e: NSEvent) -> (Int, Int) {
        let p = convert(e.locationInWindow, from: nil)
        return (Int(p.x / cellW), Int(p.y / cellH))
    }

    private func tick() {
        blinkPhase = (blinkPhase + 1) % 10
        if app.tick() || blinkPhase == 0 || blinkPhase == 5 { needsDisplay = true }
    }

    func refresh() {
        blinkPhase = 0
        needsDisplay = true
    }

    // MARK: Drawing

    private func glyph(_ c: Character) -> GlyphInfo {
        if let g = glyphCache[c] { return g }
        let ct = font as CTFont
        let s = String(c)
        var units = Array(s.utf16)
        var info: GlyphInfo = .none
        if units.count <= 2 {
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if CTFontGetGlyphsForCharacters(ct, &units, &glyphs, units.count) {
                info = .glyph(ct, glyphs[0])
            } else {
                let fb = CTFontCreateForString(ct, s as CFString, CFRange(location: 0, length: units.count))
                if CTFontGetGlyphsForCharacters(fb, &units, &glyphs, units.count) {
                    info = .glyph(fb, glyphs[0])
                } else {
                    info = .string(s)
                }
            }
        } else {
            info = .string(s)
        }
        glyphCache[c] = info
        return info
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let (c, r) = grid
        screen.resize(c, r)
        app.render(screen)
        app.layoutDock(cellW: cellW, cellH: cellH)
        let pal = app.theme.palette

        ctx.setShouldAntialias(false)
        ctx.setFillColor(pal[0])
        ctx.fill(bounds)
        // Backgrounds, merged into horizontal runs.
        for y in 0..<r {
            var x = 0
            let base = y * c
            while x < c {
                let bg = screen.cells[base + x].a.bg
                var x2 = x + 1
                while x2 < c && screen.cells[base + x2].a.bg == bg { x2 += 1 }
                if bg != 0 {
                    ctx.setFillColor(pal[Int(bg)])
                    let x0 = (CGFloat(x) * cellW).rounded(.down)
                    let x1 = x2 == c ? bounds.width : (CGFloat(x2) * cellW).rounded(.down)
                    let y1 = y == r - 1 ? bounds.height : CGFloat(y + 1) * cellH
                    ctx.fill(CGRect(x: x0, y: CGFloat(y) * cellH, width: x1 - x0, height: y1 - CGFloat(y) * cellH))
                }
                x = x2
            }
        }
        ctx.setShouldAntialias(true)

        // Glyphs
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var glyphs: [CGGlyph] = []
        var positions: [CGPoint] = []
        var curFont: CTFont?
        var curFg: UInt8 = 255
        func flush() {
            if let f = curFont, !glyphs.isEmpty {
                ctx.setFillColor(pal[Int(curFg)])
                CTFontDrawGlyphs(f, glyphs, positions, glyphs.count, ctx)
            }
            glyphs.removeAll(keepingCapacity: true)
            positions.removeAll(keepingCapacity: true)
        }
        for y in 0..<r {
            for x in 0..<c {
                let cell = screen.cells[y * c + x]
                if cell.ch == " " { continue }
                switch glyph(cell.ch) {
                case .glyph(let f, let g):
                    if f !== curFont || cell.a.fg != curFg { flush(); curFont = f; curFg = cell.a.fg }
                    glyphs.append(g)
                    positions.append(CGPoint(x: CGFloat(x) * cellW, y: -(CGFloat(y) * cellH + ascent)))  // text space (y flipped by textMatrix)
                case .string(let s):
                    flush()
                    let color = NSColor(cgColor: pal[Int(cell.a.fg)]) ?? .white
                    (s as NSString).draw(at: NSPoint(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH),
                                         withAttributes: [.font: font, .foregroundColor: color])
                    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                case .none: break
                }
            }
        }
        flush()
        // The text matrix is not part of the saved graphics state; reset it so views drawn
        // after us in a shared context (the embedded terminal) are not flipped.
        ctx.textMatrix = .identity

        // Image overlays (quick view)
        for o in screen.overlays {
            let rect = CGRect(x: CGFloat(o.x) * cellW, y: CGFloat(o.y) * cellH,
                              width: CGFloat(o.w) * cellW, height: CGFloat(o.h) * cellH)
            let sz = o.image.size
            guard sz.width > 0, sz.height > 0 else { continue }
            let scale = min(rect.width / sz.width, rect.height / sz.height, 4)
            let w = sz.width * scale, h = sz.height * scale
            let dst = CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
            o.image.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Caret
        if let (cx, cy) = screen.caret, blinkPhase < 5, cx < c, cy < r {
            let fg = screen.cells[cy * c + cx].a.fg
            ctx.setFillColor(pal[Int(fg)])
            ctx.fill(CGRect(x: CGFloat(cx) * cellW, y: CGFloat(cy + 1) * cellH - 3, width: cellW, height: 2))
        }
    }

    // MARK: Events

    override func keyDown(with e: NSEvent) {
        if let k = Key.from(e) { app.key(k) }
        refresh()
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.isKeyWindow == true, e.type == .keyDown else { return false }
        if let k = Key.from(e), app.terminalShortcut(k) { refresh(); return true }
        // When the embedded terminal has focus, every other key (Cmd-C/V, Ctrl-C...) belongs to it.
        guard window?.firstResponder === self else { return false }
        let f = e.modifierFlags
        if f.contains(.command) {
            let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
            // Leave standard app shortcuts to the menu.
            if ["q", "h", "m", "w", "`"].contains(ch) && !f.contains(.control) && !f.contains(.option) { return false }
            if let k = Key.from(e) { app.key(k); refresh(); return true }
        }
        if f.contains(.control), let k = Key.from(e) {
            // Ctrl-key combos like Ctrl-Tab or Ctrl-F-keys may arrive here first.
            app.key(k); refresh(); return true
        }
        return false
    }

    override func flagsChanged(with e: NSEvent) {
        var m: Mods = []
        if e.modifierFlags.contains(.shift) { m.insert(.shift) }
        if e.modifierFlags.contains(.control) { m.insert(.ctrl) }
        if e.modifierFlags.contains(.option) { m.insert(.alt) }
        if e.modifierFlags.contains(.command) { m.insert(.cmd) }
        app.heldMods = m
        needsDisplay = true
    }

    override func mouseDown(with e: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let (x, y) = cellAt(e)
        app.mouse(e.clickCount >= 2 ? .double : .down, x, y)
        refresh()
    }

    override func mouseDragged(with e: NSEvent) {
        let (x, y) = cellAt(e)
        app.mouse(.drag, x, y)
        refresh()
    }

    override func rightMouseDown(with e: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let (x, y) = cellAt(e)
        app.mouse(.right, x, y)
        refresh()
    }

    override func scrollWheel(with e: NSEvent) {
        let (x, y) = cellAt(e)
        let d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY / cellH : e.scrollingDeltaY
        scrollAccum += d
        while scrollAccum >= 1 { app.mouse(.scrollUp, x, y); scrollAccum -= 1 }
        while scrollAccum <= -1 { app.mouse(.scrollDown, x, y); scrollAccum += 1 }
        refresh()
    }

    // MARK: Quick Look

    var quickLookURLs: [URL] = []

    func toggleQuickLook(_ urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            quickLookURLs = urls
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    func updateQuickLook(_ urls: [URL]) {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        quickLookURLs = urls
        panel.reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil; panel.delegate = nil }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookURLs[index] as NSURL
    }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // Let arrow keys move the panel cursor while Quick Look is open.
        if event.type == .keyDown, [125, 126].contains(event.keyCode) {
            keyDown(with: event)
            return true
        }
        return false
    }
}
