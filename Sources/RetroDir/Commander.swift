import AppKit

/// The main controller: owns both panels, the command line, the console and the layer stack.
final class Commander {
    var left: Panel!
    var right: Panel!
    var activeLeft = true
    var active: Panel { activeLeft ? left : right }
    var passive: Panel { activeLeft ? right : left }

    weak var view: TermView?
    private(set) var layers: [Layer] = []
    var heldMods: Mods = []
    var activeJobs = 0

    // Command line & console
    let cmd = LineEdit("", selectAll: false)
    var cmdHistory: [String] = []
    private var histIdx: Int?
    var console: [String] = []
    private var consolePartial = ""
    private var consoleScroll = 0
    var panelsVisible = true
    private var running: Process?
    private var runningOutput = false

    var quick: String?
    private var toastMsg: (text: String, until: Date)?

    // Settings
    var showHidden = false
    var themeIndex = 0
    var theme: Theme { themes[themeIndex] }
    var fontSize: CGFloat = 14
    var confirmDelete = true
    var confirmQuit = true
    var hotlist: [String] = []

    var screenRows = 25
    var screenCols = 80
    private var keyBarSlot = 8

    // Embedded terminal (bottom split)
    var dock: TerminalDock?
    weak var container: NSView?
    var terminalVisible = false
    var terminalRows = 14
    private var tabRow = -1
    private var tabRects: [(x: Int, w: Int, idx: Int, close: Int)] = []   // idx -1 = new-tab button
    private var resizingTerminal = false
    private var dockCellRect: (y: Int, h: Int)?
    var terminalFocused: Bool { terminalVisible && (dock?.isFocused ?? false) }

    init() {
        let d = UserDefaults.standard
        showHidden = d.bool(forKey: "showHidden")
        themeIndex = min(themes.count - 1, max(0, d.integer(forKey: "theme")))
        let fs = d.double(forKey: "fontSize")
        fontSize = fs >= 8 ? CGFloat(fs) : 14
        confirmDelete = d.object(forKey: "confirmDelete") as? Bool ?? true
        confirmQuit = d.object(forKey: "confirmQuit") as? Bool ?? true
        hotlist = d.stringArray(forKey: "hotlist") ?? [NSHomeDirectory(), NSHomeDirectory() + "/Desktop",
                                                        NSHomeDirectory() + "/Documents", NSHomeDirectory() + "/Downloads", "/Applications"]
        cmdHistory = d.stringArray(forKey: "cmdHistory") ?? []
        activeLeft = d.object(forKey: "activeLeft") as? Bool ?? true
        let tr = d.integer(forKey: "terminalRows")
        terminalRows = tr >= 4 ? tr : 14

        func startPath(_ key: String, _ def: String) -> URL {
            let p = d.string(forKey: key) ?? def
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: p) }
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        left = Panel(app: self, path: startPath("leftPath", NSHomeDirectory()))
        right = Panel(app: self, path: startPath("rightPath", NSHomeDirectory() + "/Downloads"))
        for (p, k) in [(left!, "left"), (right!, "right")] {
            p.mode = PanelMode(rawValue: d.string(forKey: k + "Mode") ?? "") ?? .full
            p.sort = SortMode(rawValue: d.string(forKey: k + "Sort") ?? "") ?? .name
            p.reverse = d.bool(forKey: k + "Reverse")
        }
    }

    func start() {
        left.load()
        right.load()
    }

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(showHidden, forKey: "showHidden")
        d.set(themeIndex, forKey: "theme")
        d.set(Double(fontSize), forKey: "fontSize")
        d.set(confirmDelete, forKey: "confirmDelete")
        d.set(confirmQuit, forKey: "confirmQuit")
        d.set(hotlist, forKey: "hotlist")
        d.set(Array(cmdHistory.suffix(200)), forKey: "cmdHistory")
        d.set(activeLeft, forKey: "activeLeft")
        d.set(terminalRows, forKey: "terminalRows")
        d.set(terminalVisible && !(dock?.tabs.isEmpty ?? true), forKey: "terminalVisible")
        d.set(left.path.path, forKey: "leftPath")
        d.set(right.path.path, forKey: "rightPath")
        for (p, k) in [(left!, "left"), (right!, "right")] {
            d.set(p.mode.rawValue, forKey: k + "Mode")
            d.set(p.sort.rawValue, forKey: k + "Sort")
            d.set(p.reverse, forKey: k + "Reverse")
        }
    }

    // MARK: - Layers

    func push(_ l: Layer) {
        layers.append(l)
        // Dialogs are drawn by the grid view, so it must own the keyboard while they are up.
        if let v = view, v.window?.firstResponder !== v { v.window?.makeFirstResponder(v) }
        view?.refresh()
    }
    func pop(_ l: Layer) { layers.removeAll { $0 === l }; view?.refresh() }

    func message(_ title: String, _ text: String, error: Bool = false, buttons: [String] = ["OK"], completion: ((Int?) -> Void)? = nil) {
        let d = Dialog(app: self, title: title, buttons: buttons, error: error, width: 44)
        let maxW = max(30, min(70, screenCols - 12))
        for l in text.components(separatedBy: "\n") {
            for w in wrapText(l, maxW) { d.centered(w) }
        }
        d.focusDefault()
        d.onClose = { r, _ in completion?(r) }
        push(d)
    }

    func toast(_ s: String) {
        toastMsg = (s, Date().addingTimeInterval(3))
        view?.refresh()
    }

    /// Called by the view's timer; returns true when a redraw is needed.
    func tick() -> Bool {
        if let t = toastMsg, t.until < Date() { toastMsg = nil; return true }
        return activeJobs > 0 || running != nil || toastMsg != nil || terminalVisible
    }

    // MARK: - Rendering

    func render(_ s: Screen) {
        screenRows = s.rows
        screenCols = s.cols
        if let fi = layers.lastIndex(where: { $0.isFullScreen }) {
            for l in layers[fi...] { l.render(s) }
            return
        }
        renderBase(s)
        for l in layers { l.render(s) }
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let t = "RetroDir - " + abbreviatePath(active.path.path)
        if view?.window?.title != t { view?.window?.title = t }
    }

    static let menuTitles = ["Left", "Files", "Commands", "Options", "Right"]

    private func renderBase(_ s: Screen) {
        s.clear(.console)
        // Menu bar
        s.fill(0, 0, s.cols, 1, " ", .menuBar)
        for (i, p) in MenuBarLayer.titlePositions(Commander.menuTitles).enumerated() {
            s.put(p.x, 0, " \(Commander.menuTitles[i]) ", .menuBar)
        }
        let clock = timeFmt.string(from: Date())
        s.put(s.cols - clock.count - 1, 0, clock, .menuBar)

        var ph = s.rows - 3
        dockCellRect = nil
        tabRow = -1
        if terminalVisible {
            // 2-by-1 split: panels on top, tab bar, terminal across the full width, key bar.
            let tr = max(4, min(terminalRows, s.rows - 10))
            ph = s.rows - 3 - tr
            tabRow = 1 + ph
            dockCellRect = (tabRow + 1, tr)
            renderTabBar(s, y: tabRow)
            s.fill(0, tabRow + 1, s.cols, tr, " ", .console)
        }
        if panelsVisible {
            let lw = s.cols / 2
            let pf = !terminalFocused
            left.render(s, x: 0, y: 1, w: lw, h: ph, active: activeLeft && pf, other: right)
            right.render(s, x: lw, y: 1, w: s.cols - lw, h: ph, active: !activeLeft && pf, other: left)
            if !pf {
                // Keep the cursor row visible (dimmed) while the terminal has focus.
                let p = active
                if p.mode == .full || p.mode == .brief, p.cursor >= p.top, p.cursor < p.top + p.pageSize {
                    let r = p.columns > 1 ? (p.cursor - p.top) % p.listRows : p.cursor - p.top
                    let c = p.columns > 1 ? (p.cursor - p.top) / p.listRows : 0
                    let x0 = p.frame.x + 1 + c * (p.colWidth + 1)
                    let w = p.columns > 1 ? p.colWidth : p.frame.w - 2
                    s.recolor(x0, p.listY + r, w, Attr(fg: 0, bg: 7))
                }
            }
            if let q = quick {
                let p = active
                let t = " Search: \(q) "
                let x = p.frame.x + 2
                let y = p.frame.y + p.frame.h - 2
                s.put(x, y, pad(t, max(t.count + 2, 20)), .quickSearch)
                if layers.isEmpty { s.caret = (x + t.count - 1, y) }
            }
        } else {
            renderConsole(s, y: 1, h: ph)
        }

        if terminalVisible {
            drawKeyBar(s, baseLabels())
            if terminalFocused { drawTerminalHints(s) }
            return
        }
        // Command line
        let cy = s.rows - 2
        var prompt = truncateLeft(abbreviatePath(active.path.path), max(10, s.cols / 3)) + (running != nil ? " (running)> " : "> ")
        if let t = toastMsg, cmd.chars.isEmpty {
            s.put(0, cy, prompt, .cmdline)
            s.put(prompt.count, cy, t.text, .consoleCmd, width: s.cols - prompt.count)
        } else {
            if prompt.count > s.cols / 2 { prompt = String(prompt.suffix(s.cols / 2)) }
            s.put(0, cy, prompt, .cmdline)
            cmd.render(s, prompt.count, cy, s.cols - prompt.count, .cmdline, focused: layers.isEmpty && quick == nil)
        }
        drawKeyBar(s, baseLabels())
    }

    private func renderConsole(_ s: Screen, y: Int, h: Int) {
        var lines = console
        if !consolePartial.isEmpty { lines.append(consolePartial) }
        if lines.isEmpty {
            s.put(1, y, "Console is empty. Type a command and press Enter. Ctrl-O shows the panels.", .console)
            return
        }
        let maxScroll = max(0, lines.count - h)
        consoleScroll = max(0, min(consoleScroll, maxScroll))
        let start = max(0, lines.count - h - consoleScroll)
        for (i, l) in lines[start..<min(lines.count, start + h)].enumerated() {
            s.put(0, y + i, l, l.hasPrefix("\u{1}") ? .consoleCmd : .console, width: s.cols)
            if l.hasPrefix("\u{1}") { s.put(0, y + i, String(l.dropFirst()), .consoleCmd, width: s.cols) }
        }
        if consoleScroll > 0 {
            let t = " ↑ \(consoleScroll) more lines below (PgDn) "
            s.put(s.cols - t.count, y, t, .menuBar)
        }
    }

    private func renderTabBar(_ s: Screen, y: Int) {
        s.fill(0, y, s.cols, 1, "═", .panelFrame)
        tabRects = []
        guard let dock = dock else { return }
        let focused = terminalFocused
        var x = 1
        for (i, t) in dock.tabs.enumerated() {
            let label = " \(i + 1) " + truncate(t.title, 22) + " "
            let sel = i == dock.current
            let role: Role = focused ? .panelTitleActive : .menuBar
            guard x + label.count + 3 < s.cols - 12 else { break }
            let r: Role = sel ? role : .panelTitle
            s.put(x, y, label + "× ", r)
            tabRects.append((x, label.count + 2, i, x + label.count))
            x += label.count + 3
        }
        s.put(x, y, " + ", .menuBar)
        tabRects.append((x, 3, -1, -1))
        let hint = focused ? " Cmd-J: panels " : " Cmd-J: terminal "
        s.put(s.cols - hint.count - 1, y, hint, .panelFrame)
    }

    private func drawTerminalHints(_ s: Screen) {
        drawKeyBar(s, ["NewTab", "Close", "Switch", "Tab#", "Rename", "Panels", "Hide", "Resize", "cd←pnl", "pnl←cd"],
                   keys: ["⌘T", "⌘W", "⌘⇧[]", "⌘1-9", "⌘⇧R", "⌘J", "⌘⇧J", "⌘⌥↑↓", "⌘⇧D", "⌘⇧P"])
    }

    /// Positions the native terminal view over the grid rows reserved for it.
    func layoutDock(cellW: CGFloat, cellH: CGFloat) {
        guard let dock = dock, let term = view, let box = container else { return }
        guard let r = dockCellRect, terminalVisible else {
            if !dock.isHidden { DispatchQueue.main.async { dock.isHidden = true } }
            return
        }
        let rect = NSRect(x: 0, y: CGFloat(r.y) * cellH, width: term.bounds.width, height: CGFloat(r.h) * cellH)
        let f = term.convert(rect, to: box).integral
        if dock.frame != f || dock.isHidden {
            DispatchQueue.main.async {
                dock.frame = f
                if dock.isHidden { dock.isHidden = false }
            }
        }
    }

    // MARK: - Terminal actions

    func showTerminal(focus: Bool) {
        if dock == nil, let box = container {
            let d = TerminalDock(app: self)
            d.isHidden = true
            d.onEmpty = { [unowned self] in hideTerminal() }
            box.addSubview(d)
            dock = d
        }
        guard let dock = dock else { return }
        terminalVisible = true
        if dock.tabs.isEmpty { dock.newTab(cwd: active.path) }
        dock.isHidden = false
        if focus { dock.focus() } else { view?.window?.makeFirstResponder(view) }
        view?.refresh()
    }

    /// Cmd-T from the panels: show the terminal in the active panel's folder. Switches to a tab whose shell is
    /// already there, otherwise opens a new tab, so shells busy with something else (ssh, vim) are never touched.
    func openTerminalAtPanel() {
        let had = !(dock?.tabs.isEmpty ?? true)
        showTerminal(focus: true)
        guard had, let dock = dock else { return }
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        let want = real(active.path.path)
        if dock.currentTab?.cwd.map(real) == want { return }
        if let i = dock.tabs.firstIndex(where: { $0.cwd.map(real) == want }) {
            dock.select(i)
        } else {
            dock.newTab(cwd: active.path)
        }
    }

    func hideTerminal() {
        terminalVisible = false
        dock?.isHidden = true
        if let v = view { v.window?.makeFirstResponder(v) }
        view?.refresh()
    }

    private func focusPanels() {
        if let v = view { v.window?.makeFirstResponder(v) }
        view?.refresh()
    }

    private func renameTab() {
        guard let dock = dock, let t = dock.currentTab else { return }
        let d = Dialog(app: self, title: "Rename tab", buttons: ["OK", "Reset", "Cancel"], width: 44)
        d.text("Tab name:").field(t.customName ?? t.title)
        d.onClose = { [unowned self] r, d in
            if r == 0 { t.customName = d.fields[0].text }
            if r == 1 { t.customName = nil }
            self.dock?.focus()
        }
        push(d)
    }

    /// Terminal hotkeys. Returns true if handled. Called before any other key handling.
    func terminalShortcut(_ k: Key) -> Bool {
        guard layers.isEmpty else { return false }
        let focused = terminalFocused
        if let n = k.cmdDigit, focused, k.mods.isEmpty, let dock = dock {
            if n <= dock.tabs.count { dock.select(n - 1) }
            return true
        }
        switch (k.code, k.mods) {
        case (.char("t"), [.cmd]):
            if focused { dock?.newTab(cwd: dock?.currentTab?.cwd.map { URL(fileURLWithPath: $0) } ?? active.path) } else { openTerminalAtPanel() }
        case (.char("j"), [.cmd]):
            if focused { focusPanels() } else { showTerminal(focus: true) }
        case (.char("j"), [.cmd, .shift]):
            if terminalVisible { hideTerminal() } else { showTerminal(focus: true) }
        case (.char("w"), [.cmd]) where focused:
            if let d = dock { d.close(d.current) }
        case (.char("]"), [.cmd, .shift]) where focused, (.char("}"), [.cmd, .shift]) where focused, (.tab, [.ctrl]) where focused:
            dock?.next(1)
        case (.char("["), [.cmd, .shift]) where focused, (.char("{"), [.cmd, .shift]) where focused, (.tab, [.ctrl, .shift]) where focused:
            dock?.next(-1)
        case (.left, [.cmd, .alt, .shift]) where focused: if let d = dock { d.move(d.current, by: -1) }
        case (.right, [.cmd, .alt, .shift]) where focused: if let d = dock { d.move(d.current, by: 1) }
        case (.char("r"), [.cmd, .shift]) where terminalVisible: renameTab()
        case (.up, [.cmd, .alt]) where terminalVisible: terminalRows = min(screenRows - 10, terminalRows + 2); view?.refresh()
        case (.down, [.cmd, .alt]) where terminalVisible: terminalRows = max(4, terminalRows - 2); view?.refresh()
        case (.char("d"), [.cmd, .shift]):
            showTerminal(focus: true)
            dock?.run("cd " + shellQuote(active.path.path))
        case (.char("p"), [.cmd, .shift]) where terminalVisible:
            if let c = dock?.currentTab?.cwd { active.go(URL(fileURLWithPath: c)) }
        case (.char("k"), [.cmd]) where focused:
            dock?.send("\u{0C}")   // Ctrl-L: clear screen
        case (.char("="), [.cmd]) where focused, (.char("+"), [.cmd]) where focused, (.char("+"), [.cmd, .shift]) where focused:
            setFont(fontSize + 1)
        case (.char("-"), [.cmd]) where focused:
            setFont(fontSize - 1)
        default:
            return false
        }
        view?.refresh()
        return true
    }

    func baseLabels() -> [String] {
        if heldMods.contains(.shift) {
            return ["", "", "QLook", "New", "CopyIn", "Rename", "", "DelPrm", "Save", "Quit"]
        } else if heldMods.contains(.alt) {
            return ["Left", "Right", "", "Open", "Pack", "Unpack", "Find", "Histry", "", "Hotlst"]
        } else if heldMods.contains(.ctrl) {
            return ["", "", "Name", "Ext", "Time", "Size", "Unsort", "", "Revers", ""]
        }
        return ["Help", "UserMn", "View", "Edit", "Copy", "RenMov", "Mkdir", "Delete", "PullDn", "Quit"]
    }

    func drawKeyBar(_ s: Screen, _ labels: [String], keys: [String]? = nil) {
        let y = s.rows - 1
        let n = labels.count
        let slot = max(4, s.cols / n)
        keyBarSlot = slot
        var x = 0
        s.fill(0, y, s.cols, 1, " ", .keyNum)
        for i in 0..<n {
            let num = keys?[i] ?? "\(i + 1)"
            let w = i == n - 1 ? s.cols - x : slot
            s.put(x, y, num, .keyNum)
            s.put(x + num.count, y, labels[i], .keyLabel, width: max(0, w - num.count - (i == n - 1 ? 0 : 1)))
            x += w
        }
    }

    func keyBarClick(_ x: Int, _ handler: (Int) -> Void) {
        handler(min(10, x / max(1, keyBarSlot) + 1))
    }

    // MARK: - Keyboard

    func key(_ k: Key) {
        if let top = layers.last {
            top.key(k)
            return
        }
        if terminalShortcut(k) { return }
        if quick != nil && handleQuickSearch(k) { return }
        let p = active
        let cmdEmpty = cmd.chars.isEmpty
        let prevCursor = p.cursor

        switch (k.code, k.mods) {
        // Function keys
        case (.f(1), []): showHelp()
        case (.f(2), []): userMenu()
        case (.f(3), []): viewFile()
        case (.f(3), [.shift]), (.char("y"), [.cmd]): quickLook()
        case (.f(4), []): edit()
        case (.f(4), [.shift]): newFile()
        case (.f(4), [.alt]): openDefault()
        case (.f(5), []): copyOrMove(move: false)
        case (.f(5), [.shift]): copyOrMove(move: false, samePanel: true)
        case (.f(5), [.alt]): pack()
        case (.f(6), []): copyOrMove(move: true)
        case (.f(6), [.shift]), (.f(2), [.shift]): copyOrMove(move: true, samePanel: true)
        case (.f(6), [.alt]): unpack()
        case (.f(7), []): makeDir()
        case (.f(7), [.alt]): findFiles()
        case (.f(8), []): delete(permanent: false)
        case (.f(8), [.shift]), (.delete, [.cmd, .alt]): delete(permanent: true)
        case (.f(8), [.alt]): commandHistory()
        case (.f(9), []): openMenu(activeLeft ? 0 : 4)
        case (.f(9), [.shift]): saveSettings(); toast("Setup saved")
        case (.f(10), []), (.f(10), [.shift]): quit()
        case (.f(10), [.alt]), (.char("d"), [.ctrl]): showHotlist()
        case (.f(1), [.alt]): volumeMenu(left: true)
        case (.f(2), [.alt]): volumeMenu(left: false)
        case (.f(12), [.alt]), (.char("h"), [.alt, .ctrl]): folderHistory()
        case (.f(3), [.ctrl]): setSort(.name)
        case (.f(4), [.ctrl]): setSort(.ext)
        case (.f(5), [.ctrl]): setSort(.time)
        case (.f(6), [.ctrl]): setSort(.size)
        case (.f(7), [.ctrl]): setSort(.unsorted)
        case (.f(9), [.ctrl]): p.reverse.toggle(); p.resort()
        case (.f(11), []): volumeMenu(left: true)
        case (.f(12), []): volumeMenu(left: false)

        // Panels
        case (.tab, []), (.tab, [.shift]):
            activeLeft.toggle()
            if active.mode == .info || active.mode == .quickView { activeLeft.toggle() }
        case (.char("u"), [.ctrl]): swapPanels()
        case (.char("o"), [.ctrl]): panelsVisible.toggle(); consoleScroll = 0
        case (.char("r"), [.ctrl]): left.reload(); right.reload(); toast("Re-read")
        case (.char("h"), [.ctrl]), (.char("."), [.cmd, .shift]): toggleHidden()
        case (.char("l"), [.ctrl]): togglePassiveMode(.info)
        case (.char("q"), [.ctrl]): togglePassiveMode(.quickView)
        case (.char("1"), [.ctrl]): p.mode = .brief
        case (.char("2"), [.ctrl]): p.mode = .full
        case (.char("\\"), [.ctrl]): p.go(URL(fileURLWithPath: "/"))
        case (.char("g"), [.ctrl]), (.char("g"), [.cmd, .shift]): gotoFolder()
        case (.char("t"), [.ctrl]): openTerminal()
        case (.char("s"), [.ctrl]): quick = ""
        case (.char("="), [.ctrl]): passive.go(p.path, select: p.current?.name)
        case (.char("f"), [.ctrl]): filterDialog()

        // Command line helpers
        case (.enter, [.ctrl]), (.char("j"), [.ctrl]):
            if let c = p.current, !c.isUp {
                if terminalVisible { dock?.send(shellQuote(c.url.path) + " "); dock?.focus() } else { cmd.insert(shellQuote(c.name) + " ") }
            }
        case (.enter, [.ctrl, .shift]):
            if let c = p.current {
                if terminalVisible { dock?.send(shellQuote(c.url.path) + " "); dock?.focus() } else { cmd.insert(shellQuote(c.url.path) + " ") }
            }
        case (.char("["), [.ctrl]): cmd.insert(shellQuote(left.path.path) + " ")
        case (.char("]"), [.ctrl]): cmd.insert(shellQuote(right.path.path) + " ")
        case (.char("e"), [.ctrl]), (.up, [.alt]): historyStep(-1)
        case (.char("x"), [.ctrl]), (.down, [.alt]): historyStep(1)
        case (.char("c"), [.ctrl]):
            if let r = running { r.interrupt(); toast("Interrupted") } else { cmd.text = "" }

        // Clipboard and Finder
        case (.char("c"), [.cmd]): copyPaths(full: true)
        case (.char("c"), [.cmd, .alt]): copyPaths(full: false)
        case (.char("v"), [.cmd]):
            if !pasteFiles() { cmd.key(k) }
        case (.char("r"), [.cmd]): reveal()
        case (.char("i"), [.cmd]): getInfo()
        case (.char("a"), [.cmd]): for e in p.entries where !e.isUp { p.selected.insert(e.name) }
        case (.char("="), [.cmd]), (.char("+"), [.cmd]), (.char("+"), [.cmd, .shift]), (.char("="), [.cmd, .shift]): setFont(fontSize + 1)
        case (.char("-"), [.cmd]): setFont(fontSize - 1)
        case (.char("n"), [.cmd, .shift]): makeDir()

        // Navigation
        case (.enter, []):
            if !cmdEmpty { execute(cmd.text) } else { openCurrent() }
        case (.enter, [.shift]): reveal()
        case (.enter, [.alt]): getInfo()
        case (.up, []): p.move(-1)
        case (.down, []): p.move(1)
        case (.up, [.shift]), (.insert, [.shift]):
            if let c = p.current { p.toggleSelect(c) }; p.move(-1)
        case (.down, [.shift]), (.insert, []):
            if let c = p.current { p.toggleSelect(c) }; p.move(1)
        case (.pageUp, []): p.move(-(p.columns > 1 ? p.pageSize : max(1, p.listRows - 1)))
        case (.pageDown, []): p.move(p.columns > 1 ? p.pageSize : max(1, p.listRows - 1))
        case (.pageUp, [.ctrl]), (.up, [.cmd]): p.goUp()
        case (.pageDown, [.ctrl]), (.down, [.cmd]): enterCurrent(force: true)
        case (.home, _) where cmdEmpty || k.mods.contains(.ctrl): p.moveTo(0)
        case (.end, _) where cmdEmpty || k.mods.contains(.ctrl): p.moveTo(max(0, p.entries.count - 1))
        case (.left, []) where cmdEmpty:
            p.move(p.columns > 1 ? -p.listRows : -max(1, p.listRows - 1))
        case (.right, []) where cmdEmpty:
            p.move(p.columns > 1 ? p.listRows : max(1, p.listRows - 1))
        case (.left, [.cmd]) where cmdEmpty, (.char("["), [.cmd]):
            if let back = p.history.popLast() { p.go(back, recordHistory: false) }
        case (.backspace, []) where cmdEmpty: p.goUp()
        case (.char(" "), []) where cmdEmpty:
            if let c = p.current { p.toggleSelect(c) }; p.move(1)
        case (.char("+"), _) where cmdEmpty: selectGroup(select: true)
        case (.char("-"), _) where cmdEmpty: selectGroup(select: false)
        case (.char("*"), _) where cmdEmpty: p.invertSelection()
        case (.escape, _):
            if !cmdEmpty { cmd.text = "" } else if !panelsVisible { panelsVisible = true } else if !p.selected.isEmpty { p.selected.removeAll() }
        case (.pageUp, [.shift]) where !panelsVisible, (.pageUp, _) where !panelsVisible: consoleScroll += 10
        case (.pageDown, [.shift]) where !panelsVisible: consoleScroll = max(0, consoleScroll - 10)
        default:
            if case .char(let c) = k.code, k.mods == [.alt] || k.mods == [.alt, .shift] {
                // Option+letter starts quick search (NC: Alt+letter)
                quick = ""
                _ = handleQuickSearch(Key(code: .char(c)))
                return
            }
            if !panelsVisible, k.code == .pageDown { consoleScroll = max(0, consoleScroll - 10); return }
            if terminalVisible, let c = k.text {
                // The command line is replaced by the terminal: typing goes straight to the shell.
                dock?.focus(); dock?.send(String(c)); return
            }
            cmd.key(k)
        }
        if p.cursor != prevCursor { previewMoved() }
    }

    private func previewMoved() {
        view?.updateQuickLook(active.targets.isEmpty ? [] : [active.current!.url])
    }

    private func handleQuickSearch(_ k: Key) -> Bool {
        guard var q = quick else { return false }
        let p = active
        switch (k.code, k.mods) {
        case (.escape, _): quick = nil; return true
        case (.backspace, _):
            if q.isEmpty { quick = nil } else { q.removeLast(); quick = q }
            return true
        case (.char("s"), [.ctrl]), (.down, [.ctrl]):
            if let i = p.quickFind(q, from: p.cursor + 1) { p.moveTo(i) }
            return true
        default:
            if case .char(let c) = k.code, k.mods.subtracting([.shift, .alt]).isEmpty {
                let nq = q + String(c)
                if let i = p.quickFind(nq, from: p.cursor) { quick = nq; p.moveTo(i) } else { NSSound.beep() }
                return true
            }
            quick = nil
            return false   // fall through to normal handling
        }
    }

    private func historyStep(_ d: Int) {
        guard !cmdHistory.isEmpty else { return }
        var i = (histIdx ?? cmdHistory.count) + d
        i = max(0, min(cmdHistory.count, i))
        histIdx = i
        cmd.text = i < cmdHistory.count ? cmdHistory[i] : ""
    }

    // MARK: - Mouse

    func mouse(_ kind: MouseKind, _ x: Int, _ y: Int) {
        if let top = layers.last { top.mouse(kind, x, y); return }
        if y == 0 && kind == .down {
            for (i, p) in MenuBarLayer.titlePositions(Commander.menuTitles).enumerated() where x >= p.x && x < p.x + p.w {
                openMenu(i); return
            }
            return
        }
        if y == screenRows - 1 && kind == .down {
            keyBarClick(x) { n in key(Key(code: .f(n), mods: heldMods)) }
            return
        }
        if y == tabRow && terminalVisible {
            if kind == .down || kind == .double {
                resizingTerminal = false
                if let hit = tabRects.first(where: { x >= $0.x && x < $0.x + $0.w }) {
                    if hit.idx < 0 { showTerminal(focus: true); dock?.newTab(cwd: active.path) }
                    else if x == hit.close { dock?.close(hit.idx) }
                    else { dock?.select(hit.idx); if kind == .double { renameTab() } }
                } else {
                    resizingTerminal = true   // drag the bar to resize
                }
            }
            return
        }
        if kind == .drag && resizingTerminal && terminalVisible {
            terminalRows = max(4, min(screenRows - 10, screenRows - 2 - y))
            return
        }
        resizingTerminal = false
        if y == screenRows - 2 && kind == .down && !terminalVisible {
            cmd.pos = max(0, min(cmd.chars.count, x - (abbreviatePath(active.path.path).count + 2) + cmd.scroll))
            return
        }
        guard panelsVisible else {
            if kind == .scrollUp { consoleScroll += 3 }
            if kind == .scrollDown { consoleScroll = max(0, consoleScroll - 3) }
            return
        }
        let p = x < left.frame.x + left.frame.w ? left! : right!
        let wasActive = p === active
        if kind != .scrollUp && kind != .scrollDown {
            if p.mode == .info || p.mode == .quickView { return }
            activeLeft = p === left
            quick = nil
        }
        switch kind {
        case .scrollUp: p.move(-1); return
        case .scrollDown: p.move(1); return
        default: break
        }
        let row = y - p.listY
        guard row >= 0, row < p.listRows else { return }
        let col = p.columns > 1 ? min(p.columns - 1, max(0, (x - p.frame.x - 1) / (p.colWidth + 1))) : 0
        let idx = p.top + col * p.listRows + row
        guard idx < p.entries.count else { return }
        switch kind {
        case .down: p.cursor = idx; if !wasActive { p.clampTop() }
        case .double: p.cursor = idx; openCurrent()
        case .right:
            p.cursor = idx
            p.toggleSelect(p.entries[idx])
        case .drag:
            if idx != p.cursor { p.cursor = idx; p.clampTop() }
        default: break
        }
        previewMoved()
    }

    // MARK: - Menus

    func openMenu(_ index: Int) {
        push(MenuBarLayer(app: self, menus: buildMenus(), start: index))
    }

    private func panelMenu(_ p: Panel, isLeft: Bool) -> PullMenu {
        let other = isLeft ? right! : left!
        func setMode(_ m: PanelMode) -> () -> Void {
            { [unowned self] in
                p.mode = m
                if m == .info || m == .quickView, self.active === p { self.activeLeft = !isLeft }
                _ = other
            }
        }
        func sort(_ s: SortMode) -> () -> Void { { if p.sort == s { p.reverse.toggle() } else { p.sort = s; p.reverse = false }; p.resort() } }
        return PullMenu(title: isLeft ? "Left" : "Right", items: [
            MenuItem(title: "Brief", shortcut: "Ctrl-1", checked: p.mode == .brief, action: setMode(.brief)),
            MenuItem(title: "Full", shortcut: "Ctrl-2", checked: p.mode == .full, action: setMode(.full)),
            MenuItem(title: "Info", shortcut: "Ctrl-L", checked: p.mode == .info, action: setMode(.info)),
            MenuItem(title: "Quick view", shortcut: "Ctrl-Q", checked: p.mode == .quickView, action: setMode(.quickView)),
            .sep,
            MenuItem(title: "Name", shortcut: "Ctrl-F3", checked: p.sort == .name, action: sort(.name)),
            MenuItem(title: "Extension", shortcut: "Ctrl-F4", checked: p.sort == .ext, action: sort(.ext)),
            MenuItem(title: "Time", shortcut: "Ctrl-F5", checked: p.sort == .time, action: sort(.time)),
            MenuItem(title: "Size", shortcut: "Ctrl-F6", checked: p.sort == .size, action: sort(.size)),
            MenuItem(title: "Unsorted", shortcut: "Ctrl-F7", checked: p.sort == .unsorted, action: sort(.unsorted)),
            MenuItem(title: "Reverse order", shortcut: "Ctrl-F9", checked: p.reverse, action: { p.reverse.toggle(); p.resort() }),
            .sep,
            MenuItem(title: "Filter...", shortcut: "Ctrl-F", checked: !p.filter.isEmpty, action: { [unowned self] in self.activeLeft = isLeft; self.filterDialog() }),
            MenuItem(title: "Re-read", shortcut: "Ctrl-R", action: { p.reload() }),
            MenuItem(title: "Change volume...", shortcut: isLeft ? "Alt-F1" : "Alt-F2", action: { [unowned self] in self.volumeMenu(left: isLeft) }),
            MenuItem(title: "Go to folder...", shortcut: "Ctrl-G", action: { [unowned self] in self.activeLeft = isLeft; self.gotoFolder() }),
        ])
    }

    private func buildMenus() -> [PullMenu] {
        let files = PullMenu(title: "Files", items: [
            MenuItem(title: "Help", shortcut: "F1", action: { [unowned self] in showHelp() }),
            MenuItem(title: "User menu", shortcut: "F2", action: { [unowned self] in userMenu() }),
            MenuItem(title: "View", shortcut: "F3", action: { [unowned self] in viewFile() }),
            MenuItem(title: "Edit", shortcut: "F4", action: { [unowned self] in edit() }),
            MenuItem(title: "Copy", shortcut: "F5", action: { [unowned self] in copyOrMove(move: false) }),
            MenuItem(title: "Rename or move", shortcut: "F6", action: { [unowned self] in copyOrMove(move: true) }),
            MenuItem(title: "Make folder", shortcut: "F7", action: { [unowned self] in makeDir() }),
            MenuItem(title: "Move to Trash", shortcut: "F8", action: { [unowned self] in delete(permanent: false) }),
            MenuItem(title: "Delete permanently", shortcut: "Shift-F8", action: { [unowned self] in delete(permanent: true) }),
            .sep,
            MenuItem(title: "New file", shortcut: "Shift-F4", action: { [unowned self] in newFile() }),
            MenuItem(title: "Open with default app", shortcut: "Alt-F4", action: { [unowned self] in openDefault() }),
            MenuItem(title: "Quick Look", shortcut: "Cmd-Y", action: { [unowned self] in quickLook() }),
            MenuItem(title: "Reveal in Finder", shortcut: "Cmd-R", action: { [unowned self] in reveal() }),
            MenuItem(title: "Get info", shortcut: "Cmd-I", action: { [unowned self] in getInfo() }),
            MenuItem(title: "Attributes...", shortcut: "", action: { [unowned self] in attributes() }),
            MenuItem(title: "Symlink in other panel", shortcut: "", action: { [unowned self] in makeSymlink() }),
            .sep,
            MenuItem(title: "Select group", shortcut: "+", action: { [unowned self] in selectGroup(select: true) }),
            MenuItem(title: "Unselect group", shortcut: "-", action: { [unowned self] in selectGroup(select: false) }),
            MenuItem(title: "Invert selection", shortcut: "*", action: { [unowned self] in active.invertSelection() }),
            MenuItem(title: "Select all", shortcut: "Cmd-A", action: { [unowned self] in for e in active.entries where !e.isUp { active.selected.insert(e.name) } }),
            .sep,
            MenuItem(title: "Pack (zip/tar)", shortcut: "Alt-F5", action: { [unowned self] in pack() }),
            MenuItem(title: "Unpack", shortcut: "Alt-F6", action: { [unowned self] in unpack() }),
            .sep,
            MenuItem(title: "Quit", shortcut: "F10", action: { [unowned self] in quit() }),
        ])
        let commands = PullMenu(title: "Commands", items: [
            MenuItem(title: "Find file", shortcut: "Alt-F7", action: { [unowned self] in findFiles() }),
            MenuItem(title: "Command history", shortcut: "Alt-F8", action: { [unowned self] in commandHistory() }),
            MenuItem(title: "Folder history", shortcut: "Alt-F12", action: { [unowned self] in folderHistory() }),
            MenuItem(title: "Folder hotlist", shortcut: "Ctrl-D", action: { [unowned self] in showHotlist() }),
            .sep,
            MenuItem(title: "Swap panels", shortcut: "Ctrl-U", action: { [unowned self] in swapPanels() }),
            MenuItem(title: "Panels on/off", shortcut: "Ctrl-O", action: { [unowned self] in panelsVisible.toggle() }),
            MenuItem(title: "Same folder in other panel", shortcut: "Ctrl-=", action: { [unowned self] in passive.go(active.path) }),
            MenuItem(title: "Compare folders", shortcut: "", action: { [unowned self] in compareFolders() }),
            MenuItem(title: "Calculate folder sizes", shortcut: "", action: { [unowned self] in calcSizes(active.entries.filter { $0.isDir && !$0.isUp }) }),
            .sep,
            MenuItem(title: "Terminal panel", shortcut: "Cmd-T", checked: terminalVisible, action: { [unowned self] in openTerminalAtPanel() }),
            MenuItem(title: "Hide terminal panel", shortcut: "Cmd-Shift-J", action: { [unowned self] in hideTerminal() }),
            MenuItem(title: "New terminal tab", shortcut: "", action: { [unowned self] in
                let had = !(dock?.tabs.isEmpty ?? true)
                showTerminal(focus: true)
                if had { dock?.newTab(cwd: active.path) }
            }),
            MenuItem(title: "Rename terminal tab", shortcut: "Cmd-Shift-R", action: { [unowned self] in if terminalVisible { renameTab() } }),
            MenuItem(title: "cd terminal to this folder", shortcut: "Cmd-Shift-D", action: { [unowned self] in showTerminal(focus: true); dock?.run("cd " + shellQuote(active.path.path)) }),
            MenuItem(title: "Open Terminal.app here", shortcut: "Ctrl-T", action: { [unowned self] in openTerminal() }),
            MenuItem(title: "Clear console", shortcut: "", action: { [unowned self] in console.removeAll(); consolePartial = "" }),
        ])
        var optItems: [MenuItem] = themes.enumerated().map { i, t in
            MenuItem(title: "Theme: " + t.name, shortcut: "", checked: i == themeIndex, action: { [unowned self] in themeIndex = i; dock?.applyStyle(); saveSettings() })
        }
        optItems += [
            .sep,
            MenuItem(title: "Larger font", shortcut: "Cmd-+", action: { [unowned self] in setFont(fontSize + 1) }),
            MenuItem(title: "Smaller font", shortcut: "Cmd--", action: { [unowned self] in setFont(fontSize - 1) }),
            .sep,
            MenuItem(title: "Show hidden files", shortcut: "Ctrl-H", checked: showHidden, action: { [unowned self] in toggleHidden() }),
            MenuItem(title: "Confirm delete", shortcut: "", checked: confirmDelete, action: { [unowned self] in confirmDelete.toggle() }),
            MenuItem(title: "Confirm quit", shortcut: "", checked: confirmQuit, action: { [unowned self] in confirmQuit.toggle() }),
            .sep,
            MenuItem(title: "Save setup", shortcut: "Shift-F9", action: { [unowned self] in saveSettings(); toast("Setup saved") }),
            MenuItem(title: "About RetroDir", shortcut: "", action: { [unowned self] in
                message("About", "RetroDir \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")\n\nA retro dual-panel file manager for macOS, inspired by the classic orthodox file managers.\n\nRetroDir is an experimental, non-commercial project built with AI (Claude Code). Original code and artwork; not affiliated with or endorsed by any other file manager or its owners. Provided as is, without warranty. It can move and delete files, so keep backups.\n\nCopyright (c) 2026 Ehsan Haque. MIT licence.\nTerminal emulation by SwiftTerm (MIT licence).\nOptions > Licences shows the full text.\n\nPress F1 for keyboard help.")
            }),
            MenuItem(title: "Licences", shortcut: "", action: { [unowned self] in showLicences() }),
        ]
        let options = PullMenu(title: "Options", items: optItems)
        return [panelMenu(left, isLeft: true), files, commands, options, panelMenu(right, isLeft: false)]
    }

    // MARK: - Panel actions

    private func setSort(_ s: SortMode) {
        let p = active
        if p.sort == s { p.reverse.toggle() } else { p.sort = s; p.reverse = false }
        p.resort()
        toast("Sort by \(s.rawValue)\(p.reverse ? " (reversed)" : "")")
    }

    private func togglePassiveMode(_ m: PanelMode) {
        let p = passive
        p.mode = p.mode == m ? .full : m
        if p.mode == .full { p.reload() }
    }

    private func toggleHidden() {
        showHidden.toggle()
        left.reload(); right.reload()
        toast(showHidden ? "Showing hidden files" : "Hiding hidden files")
    }

    private func swapPanels() {
        let lp = left.path, rp = right.path
        let lm = left.mode, rm = right.mode
        left.go(rp, recordHistory: false); right.go(lp, recordHistory: false)
        left.mode = rm; right.mode = lm
        activeLeft.toggle()
    }

    private func setFont(_ size: CGFloat) {
        fontSize = max(9, min(32, size))
        view?.setFontSize(fontSize)
        dock?.applyStyle()
    }

    private func openCurrent() {
        guard let e = active.current else { return }
        if e.isUp { active.goUp(); return }
        if e.isDir && !e.isPackage { active.go(e.url); return }
        if e.isArchive {
            let l = ListPicker(app: self, title: e.display, items: [
                ("View contents", "F3"), ("Extract to other panel...", "Alt-F6"), ("Extract here", ""), ("Open with default app", "Alt-F4"),
            ])
            l.filterable = false
            l.onSelect = { [unowned self] i, _ in
                switch i {
                case 0: viewFile()
                case 1: unpack()
                case 2: extract(e.url, to: active.path)
                default: openDefault()
                }
            }
            push(l)
            return
        }
        let ext = e.ext
        if e.isExec && (ext.isEmpty || ["sh", "command", "py", "pl", "rb", "zsh", "bash"].contains(ext)) {
            execute("./" + shellQuote(e.name))
            return
        }
        NSWorkspace.shared.open(e.url)
    }

    private func enterCurrent(force: Bool) {
        guard let e = active.current else { return }
        if e.isUp { active.goUp() } else if e.isDir { active.go(e.url) }
    }

    /// Third-party notices shipped in the app bundle (Contents/Resources/LICENSES.txt).
    private func showLicences() {
        let text = Bundle.main.url(forResource: "LICENSES", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "Licence file not found in the app bundle."
        push(TextBox(app: self, title: "Licences", text: text))
    }

    func showHelp() {
        push(TextBox(app: self, title: "RetroDir Help", text: helpText))
    }

    private func viewFile() {
        guard let e = active.current else { return }
        if e.isUp { return }
        if e.isDir {
            calcSizes(active.targets.filter(\.isDir).isEmpty ? [e] : active.targets.filter(\.isDir))
            return
        }
        if e.isArchive {
            let out = runCapture("/usr/bin/tar", ["-tvf", e.url.path])
            push(Viewer(app: self, title: e.url.path + " (archive listing)", text: out))
            return
        }
        do {
            push(try Viewer(app: self, url: e.url))
        } catch {
            message("Error", "Cannot open file:\n\(e.url.path)\n\n\(error.localizedDescription)", error: true)
        }
    }

    private func edit(_ url: URL? = nil, isNew: Bool = false) {
        let target: URL
        if let u = url { target = u } else {
            guard let e = active.current, !e.isUp else { return }
            if e.isDir { toast("Cannot edit a folder"); return }
            target = e.url
        }
        do {
            let ed = try Editor(app: self, url: target, isNew: isNew)
            ed.onClose = { [unowned self] in
                active.load(select: ed.url.lastPathComponent, keepCursor: true)
                passive.reload()
            }
            push(ed)
        } catch {
            message("Error", error.localizedDescription, error: true)
        }
    }

    private func newFile() {
        let d = Dialog(app: self, title: "New file", buttons: ["Edit", "Cancel"])
        d.text("File name:").field("", selectAll: false)
        d.onClose = { [unowned self] r, d in
            guard r == 0, !d.fields[0].text.isEmpty else { return }
            let u = expandPath(d.fields[0].text, relativeTo: active.path)
            edit(u, isNew: !FileManager.default.fileExists(atPath: u.path))
        }
        push(d)
    }

    private func openDefault() {
        let t = active.targets
        guard !t.isEmpty else { return }
        for e in t { NSWorkspace.shared.open(e.url) }
    }

    private func quickLook() {
        let urls = active.targets.map(\.url)
        guard !urls.isEmpty else { return }
        view?.toggleQuickLook(urls)
    }

    private func reveal() {
        let t = active.targets
        if t.isEmpty { NSWorkspace.shared.open(active.path) } else { NSWorkspace.shared.activateFileViewerSelecting(t.map(\.url)) }
    }

    private func copyPaths(full: Bool) {
        let t = active.targets
        guard !t.isEmpty else { return }
        let s = t.map { full ? $0.url.path : $0.name }.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(t.map { $0.url as NSURL })
        pb.setString(s, forType: .string)
        toast("Copied \(t.count == 1 ? (full ? "path" : "name") : "\(t.count) \(full ? "paths" : "names")") to clipboard")
    }

    /// Cmd-V with files on the pasteboard (e.g. copied in Finder) copies them into the active panel.
    private func pasteFiles() -> Bool {
        guard cmd.chars.isEmpty,
              let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        dropFiles(urls)
        return true
    }

    func dropFiles(_ urls: [URL]) {
        let dest = active.path
        let what = urls.count == 1 ? "\"\(urls[0].lastPathComponent)\"" : "\(urls.count) items"
        message("Copy", "Copy \(what) into\n\(abbreviatePath(dest.path))?", buttons: ["Copy", "Move", "Cancel"]) { [unowned self] r in
            guard let r = r, r < 2 else { return }
            let job = FileJob(app: self, op: r == 0 ? .copy : .move, items: urls, dest: dest)
            job.completion = { [unowned self] _ in left.reload(); right.reload() }
            job.start()
        }
    }

    private func getInfo() {
        guard let e = active.current, !e.isUp else { return }
        var lines = Panel.infoLines(e).map { pad($0.0, 10) + "  " + $0.1 }
        lines.insert("", at: 0)
        if e.isDir {
            lines.append(active.dirSizes[e.name].map { pad("Size", 10) + "  \(grouped($0)) bytes (\(humanSize($0)))" } ?? "Press F3 on a folder to calculate its size")
        }
        lines.append("")
        push(TextBox(app: self, title: "Info", text: lines.joined(separator: "\n")))
    }

    private func attributes() {
        let t = active.targets
        guard let first = t.first else { return }
        let d = Dialog(app: self, title: "Attributes", buttons: ["Set", "Cancel"], width: 50)
        d.text(t.count == 1 ? first.display : "\(t.count) items")
        d.text(permString(first.mode, isDir: first.isDir, isLink: first.isSymlink))
        d.blank()
        d.field(String(format: "%03o", Int(first.mode) & 0o7777), label: "Mode (octal):")
        d.check("Hidden (chflags hidden)", first.isHidden && !first.name.hasPrefix("."))
        d.check("Apply recursively to folder contents", false)
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            guard let mode = Int(d.fields[0].text, radix: 8) else { message("Error", "Invalid octal mode", error: true); return }
            let hidden = d.checks[0].on, rec = d.checks[1].on
            var errs: [String] = []
            func apply(_ path: String) {
                if chmod(path, mode_t(mode)) != 0 { errs.append("\(path): \(String(cString: strerror(errno)))") }
                var st = stat()
                if lstat(path, &st) == 0 {
                    let fl = hidden ? (st.st_flags | UInt32(UF_HIDDEN)) : (st.st_flags & ~UInt32(UF_HIDDEN))
                    if fl != st.st_flags { lchflags(path, fl) }
                }
            }
            for e in t {
                apply(e.url.path)
                if rec && e.isDir, let en = FileManager.default.enumerator(atPath: e.url.path) {
                    for case let sub as String in en { apply(e.url.path + "/" + sub) }
                }
            }
            active.reload()
            if !errs.isEmpty { message("Errors", errs.prefix(6).joined(separator: "\n"), error: true) }
        }
        push(d)
    }

    private func makeSymlink() {
        guard let e = active.current, !e.isUp else { return }
        let d = Dialog(app: self, title: "Symlink", buttons: ["Create", "Cancel"], width: 60)
        d.text("Create symbolic link to \(e.display) as:").field(passive.path.appendingPathComponent(e.name).path)
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let dst = expandPath(d.fields[0].text, relativeTo: active.path)
            do {
                try FileManager.default.createSymbolicLink(at: dst, withDestinationURL: e.url)
                passive.reload()
            } catch { message("Error", error.localizedDescription, error: true) }
        }
        push(d)
    }

    private func selectGroup(select: Bool) {
        let d = Dialog(app: self, title: select ? "Select" : "Unselect", buttons: ["OK", "Cancel"], width: 40)
        d.field("*", selectAll: true).check("Include folders", false)
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            active.selectMask(d.fields[0].text, select: select, includeDirs: d.checks[0].on)
        }
        push(d)
    }

    private func filterDialog() {
        let p = active
        let d = Dialog(app: self, title: "Filter", buttons: ["Apply", "Clear", "Cancel"], width: 50)
        d.text("Show only files matching (e.g. *.swift,*.md):").field(p.filter.isEmpty ? "*" : p.filter)
        d.onClose = { r, d in
            guard let r = r, r < 2 else { return }
            let f = d.fields[0].text.trimmingCharacters(in: .whitespaces)
            p.filter = (r == 1 || f == "*") ? "" : f
            p.reload()
        }
        push(d)
    }

    private func gotoFolder() {
        let d = Dialog(app: self, title: "Go to folder", buttons: ["Go", "Cancel"], width: 60)
        d.text("Folder (~, absolute or relative path):").field(abbreviatePath(active.path.path))
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let u = expandPath(d.fields[0].text, relativeTo: active.path)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue {
                active.go(u.deletingLastPathComponent(), select: u.lastPathComponent)
            } else {
                active.go(u)
            }
        }
        push(d)
    }

    private func openTerminal() {
        _ = runCapture("/usr/bin/open", ["-a", "Terminal", active.path.path])
    }

    // MARK: - File operations

    private func copyOrMove(move: Bool, samePanel: Bool = false) {
        let p = active
        let t = p.targets
        guard !t.isEmpty else { return }
        let what = t.count == 1 ? "\"\(t[0].display)\"" : "\(t.count) items"
        let def: String
        if samePanel {
            if t.count == 1 {
                def = move ? t[0].display : copyName(t[0])
            } else { def = abbreviatePath(p.path.path) + "/" }
        } else {
            def = abbreviatePath(passive.path.path) + "/"
        }
        let title = move ? (samePanel ? "Rename" : "Rename/Move") : "Copy"
        let d = Dialog(app: self, title: title, buttons: [move ? (samePanel ? "Rename" : "Move") : "Copy", "Cancel"], width: 64)
        d.text("\(move ? "Move" : "Copy") \(what) to:").field(def)
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let text = d.fields[0].text
            guard !text.isEmpty else { return }
            var dest = expandPath(text, relativeTo: p.path)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir)
            if (t.count > 1 || text.hasSuffix("/")) && !exists {
                do { try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true) } catch {
                    message("Error", error.localizedDescription, error: true); return
                }
            } else if t.count > 1 && !isDir.boolValue {
                message("Error", "Destination must be a folder when copying several items.", error: true); return
            }
            dest = dest.standardizedFileURL
            let job = FileJob(app: self, op: move ? .move : .copy, items: t.map(\.url), dest: dest)
            let single = t.count == 1 && !(exists && isDir.boolValue)
            job.completion = { [unowned self] job in
                for u in job.completed { p.selected.remove(u.lastPathComponent) }
                if single && dest.deletingLastPathComponent().path == p.path.path {
                    p.load(select: dest.lastPathComponent, keepCursor: true)
                } else {
                    p.reload()
                }
                let other = p === left ? right! : left!
                if single && dest.deletingLastPathComponent().path == other.path.path {
                    other.load(select: dest.lastPathComponent, keepCursor: true)
                } else { other.reload() }
            }
            job.start()
        }
        push(d)
    }

    private func copyName(_ e: FileEntry) -> String {
        let base = (e.display as NSString).deletingPathExtension
        let ext = (e.display as NSString).pathExtension
        var n = 1
        while true {
            let cand = (n == 1 ? "\(base) copy" : "\(base) copy \(n)") + (ext.isEmpty || e.isDir ? "" : ".\(ext)")
            if !FileManager.default.fileExists(atPath: active.path.appendingPathComponent(cand).path) { return cand }
            n += 1
        }
    }

    private func makeDir() {
        let d = Dialog(app: self, title: "Make folder", buttons: ["OK", "Cancel"])
        d.text("Create the folder (a/b/c creates nested folders):").field("", selectAll: false)
        d.onClose = { [unowned self] r, d in
            guard r == 0, !d.fields[0].text.isEmpty else { return }
            let u = expandPath(d.fields[0].text, relativeTo: active.path)
            do {
                try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
                let rel = u.path.hasPrefix(active.path.path + "/") ? String(u.path.dropFirst(active.path.path.count + 1)) : u.lastPathComponent
                active.load(select: rel.split(separator: "/").first.map(String.init))
                if passive.path == active.path { passive.reload() }
            } catch {
                message("Error", "Cannot create folder:\n\(u.path)\n\n\(error.localizedDescription)", error: true)
            }
        }
        push(d)
    }

    private func delete(permanent: Bool) {
        let p = active
        let t = p.targets
        guard !t.isEmpty else { return }
        let what = t.count == 1 ? "\"\(t[0].display)\"" : "\(t.count) items"
        let run = { [unowned self] in
            let job = FileJob(app: self, op: permanent ? .delete : .trash, items: t.map(\.url), dest: nil)
            job.completion = { [unowned self] job in
                for u in job.completed { p.selected.remove(u.lastPathComponent) }
                p.load(keepCursor: true)
                passive.reload()
            }
            job.start()
        }
        if permanent {
            message("Delete", "Permanently delete \(what)?\nThis cannot be undone.", error: true, buttons: ["Delete", "Cancel"]) { r in
                if r == 0 { run() }
            }
        } else if confirmDelete {
            message("Move to Trash", "Move \(what) to the Trash?", buttons: ["Trash", "Cancel"]) { r in if r == 0 { run() } }
        } else {
            run()
        }
    }

    private func calcSizes(_ dirs: [FileEntry]) {
        guard !dirs.isEmpty else { return }
        let p = active
        let task = BackgroundTask(app: self, title: "Folder sizes")
        var results: [String: Int64] = [:]
        var totalFiles = 0
        task.runBlock({ t in
            for d in dirs {
                if t.isCancelled { break }
                DispatchQueue.main.async { t.status = "Scanning " + d.display }
                let r = directorySize(d.url, cancel: { t.isCancelled })
                results[d.name] = r.bytes
                totalFiles += r.files
            }
        }, completion: { [unowned self] in
            for (k, v) in results { p.dirSizes[k] = v }
            if p.sort == .size { p.resort() }
            if dirs.count == 1, let b = results[dirs[0].name] {
                toast("\(dirs[0].display): \(grouped(b)) bytes (\(humanSize(b))) in \(totalFiles) files")
            } else {
                toast("Sizes calculated for \(results.count) folders")
            }
        })
    }

    private func compareFolders() {
        let a = active, b = passive
        func idx(_ p: Panel) -> [String: FileEntry] {
            Dictionary(p.entries.filter { !$0.isDir }.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        }
        let ia = idx(a), ib = idx(b)
        a.selected.removeAll(); b.selected.removeAll()
        for (n, e) in ia { if let o = ib[n] { if e.mtime > o.mtime || (e.mtime == o.mtime && e.size != o.size) { a.selected.insert(n) } } else { a.selected.insert(n) } }
        for (n, e) in ib { if let o = ia[n] { if e.mtime > o.mtime || (e.mtime == o.mtime && e.size != o.size) { b.selected.insert(n) } } else { b.selected.insert(n) } }
        if a.selected.isEmpty && b.selected.isEmpty { message("Compare", "The folders contain identical files.") } else {
            toast("Different/newer files selected: \(a.selected.count) here, \(b.selected.count) in the other panel")
        }
    }

    // MARK: - Archives

    private func pack() {
        let t = active.targets
        guard !t.isEmpty else { return }
        let base = t.count == 1 ? (t[0].isDir ? t[0].display : (t[0].display as NSString).deletingPathExtension) : active.path.lastPathComponent
        let d = Dialog(app: self, title: "Pack", buttons: ["Pack", "Cancel"], width: 64)
        d.text("Compress \(t.count == 1 ? "\"\(t[0].display)\"" : "\(t.count) items") to archive:")
        d.field(abbreviatePath(passive.path.appendingPathComponent(base + ".zip").path))
        d.text("Format by extension: .zip .tar .tar.gz/.tgz .tar.bz2 .tar.xz")
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            let out = expandPath(d.fields[0].text, relativeTo: active.path)
            let names = t.map(\.name)
            let lower = out.lastPathComponent.lowercased()
            let exe: String, args: [String]
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") { exe = "/usr/bin/tar"; args = ["-czf", out.path] + names }
            else if lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz") { exe = "/usr/bin/tar"; args = ["-cjf", out.path] + names }
            else if lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz") { exe = "/usr/bin/tar"; args = ["-cJf", out.path] + names }
            else if lower.hasSuffix(".tar") { exe = "/usr/bin/tar"; args = ["-cf", out.path] + names }
            else { exe = "/usr/bin/zip"; args = ["-r", "-y", "-q", out.path] + names }
            let task = BackgroundTask(app: self, title: "Pack")
            task.status = "Creating " + out.lastPathComponent
            task.runProcess(exe, args, cwd: active.path) { [unowned self] code, output in
                left.reload(); right.reload()
                if code == 0 { toast("Created \(out.lastPathComponent)") } else if code > 0 {
                    message("Pack failed", output.isEmpty ? "Exit code \(code)" : String(output.suffix(800)), error: true)
                }
            }
        }
        push(d)
    }

    private func unpack() {
        guard let e = active.current, !e.isUp, !e.isDir else { return }
        let d = Dialog(app: self, title: "Unpack", buttons: ["Extract", "Cancel"], width: 64)
        d.text("Extract \"\(e.display)\" to:").field(abbreviatePath(passive.path.path) + "/")
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            extract(e.url, to: expandPath(d.fields[0].text, relativeTo: active.path))
        }
        push(d)
    }

    private func extract(_ archive: URL, to dest: URL) {
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let isZip = ["zip", "jar", "war", "apk"].contains(archive.pathExtension.lowercased())
        let task = BackgroundTask(app: self, title: "Unpack")
        task.status = "Extracting " + archive.lastPathComponent
        let exe = isZip ? "/usr/bin/ditto" : "/usr/bin/tar"
        let args = isZip ? ["-x", "-k", archive.path, dest.path] : ["-xf", archive.path, "-C", dest.path]
        task.runProcess(exe, args, cwd: dest) { [unowned self] code, output in
            left.reload(); right.reload()
            if code == 0 { toast("Extracted to \(abbreviatePath(dest.path))") } else if code > 0 {
                message("Unpack failed", output.isEmpty ? "Exit code \(code)" : String(output.suffix(800)), error: true)
            }
        }
    }

    // MARK: - Pickers

    private func volumeMenu(left isLeft: Bool) {
        var items: [(String, String, URL)] = []
        let home = NSHomeDirectory()
        items.append(("/  (root)", "", URL(fileURLWithPath: "/")))
        items.append(("~  Home", "", URL(fileURLWithPath: home)))
        for (n, p) in [("Desktop", "Desktop"), ("Documents", "Documents"), ("Downloads", "Downloads")] {
            items.append(("   " + n, "", URL(fileURLWithPath: home + "/" + p)))
        }
        items.append(("   Applications", "", URL(fileURLWithPath: "/Applications")))
        let icloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if FileManager.default.fileExists(atPath: icloud) { items.append(("   iCloud Drive", "", URL(fileURLWithPath: icloud))) }
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeIsRemovableKey]
        for v in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let rv = try? v.resourceValues(forKeys: Set(keys))
            let free = Int64(rv?.volumeAvailableCapacity ?? 0), total = Int64(rv?.volumeTotalCapacity ?? 0)
            let name = rv?.volumeName ?? v.lastPathComponent
            items.append(("◘  " + name, total > 0 ? "\(humanSize(free)) free of \(humanSize(total))" : "", v))
        }
        let l = ListPicker(app: self, title: isLeft ? "Left panel" : "Right panel", items: items.map { ($0.0, $0.1) })
        let target = isLeft ? left! : right!
        l.cursor = items.firstIndex(where: { target.path.path == $0.2.path }) ?? 0
        l.onSelect = { [unowned self] i, _ in
            activeLeft = isLeft
            if target.mode == .info || target.mode == .quickView { target.mode = .full }
            target.go(items[i].2)
        }
        push(l)
    }

    private func showHotlist() {
        let l = ListPicker(app: self, title: "Folder hotlist", items: hotlist.map { (abbreviatePath($0), "") })
        l.footer = "Ins/Cmd-N: add current  Del: remove  Enter: go"
        l.minWidth = 50
        l.filterable = false
        l.onSelect = { [unowned self] i, _ in active.go(URL(fileURLWithPath: hotlist[i])) }
        l.onKey = { [unowned self] k, l in
            if k.code == .insert || k.isCmd("n") || k.code == .char("+") {
                if !hotlist.contains(active.path.path) { hotlist.append(active.path.path) }
                l.items = hotlist.map { (abbreviatePath($0), "") }; l.cursor = hotlist.count - 1
                saveSettings(); return true
            }
            if (k.code == .delete || k.code == .f(8) || k.code == .backspace || k.code == .char("-")), hotlist.indices.contains(l.cursor) {
                hotlist.remove(at: l.cursor)
                l.items = hotlist.map { (abbreviatePath($0), "") }
                saveSettings(); return true
            }
            return false
        }
        push(l)
    }

    private func commandHistory() {
        let h = Array(cmdHistory.reversed())
        let l = ListPicker(app: self, title: "Command history", items: h.map { ($0, "") })
        l.footer = "Enter: put on command line  Shift-Enter: run"
        l.onKey = { [unowned self] k, l in
            if k.code == .enter && k.shift, h.indices.contains(l.cursor) { l.close(); execute(h[l.cursor]); return true }
            return false
        }
        l.onSelect = { [unowned self] i, _ in cmd.text = h[i] }
        push(l)
    }

    private func folderHistory() {
        let h = Array(active.history.reversed())
        let l = ListPicker(app: self, title: "Folder history", items: h.map { (abbreviatePath($0.path), "") })
        l.onSelect = { [unowned self] i, _ in active.go(h[i]) }
        push(l)
    }

    private func userMenu() {
        let items: [(String, String, () -> Void)] = [
            ("Reveal in Finder", "Cmd-R", { [unowned self] in reveal() }),
            ("Open Terminal here", "Ctrl-T", { [unowned self] in openTerminal() }),
            ("Quick Look", "Cmd-Y", { [unowned self] in quickLook() }),
            ("Open with default app", "Alt-F4", { [unowned self] in openDefault() }),
            ("Copy full path(s)", "Cmd-C", { [unowned self] in copyPaths(full: true) }),
            ("Copy name(s)", "Cmd-Alt-C", { [unowned self] in copyPaths(full: false) }),
            ("Get info", "Cmd-I", { [unowned self] in getInfo() }),
            ("Attributes / permissions...", "", { [unowned self] in attributes() }),
            ("Symlink in other panel...", "", { [unowned self] in makeSymlink() }),
            ("Compress to archive...", "Alt-F5", { [unowned self] in pack() }),
            ("Extract archive...", "Alt-F6", { [unowned self] in unpack() }),
            ("Calculate folder sizes", "", { [unowned self] in calcSizes(active.entries.filter { $0.isDir && !$0.isUp }) }),
            ("Compare folders", "", { [unowned self] in compareFolders() }),
            ("Disk usage of this folder (du)", "", { [unowned self] in execute("du -sh -- * .[!.]* 2>/dev/null | sort -h") }),
            ("Git status", "", { [unowned self] in execute("git status") }),
            ("Git log (last 30)", "", { [unowned self] in execute("git log --oneline --graph --decorate -30") }),
            ("Make executable (chmod +x)", "", { [unowned self] in
                for e in active.targets where !e.isDir { chmod(e.url.path, mode_t(Int(e.mode) | 0o111)) }
                active.reload()
            }),
            ("SHA-256 checksum", "", { [unowned self] in
                let files = active.targets.filter { !$0.isDir }.map { shellQuote($0.name) }
                if !files.isEmpty { execute("shasum -a 256 " + files.joined(separator: " ")) }
            }),
            ("New file...", "Shift-F4", { [unowned self] in newFile() }),
        ]
        let l = ListPicker(app: self, title: "User menu", items: items.map { ($0.0, $0.1) })
        l.onSelect = { i, _ in items[i].2() }
        push(l)
    }

    // MARK: - Find files

    private func findFiles() {
        let d = Dialog(app: self, title: "Find file", buttons: ["Find", "Cancel"], width: 60)
        d.field("*", label: "File name mask: ")
        d.field("", label: "Containing text:", selectAll: false)
        d.check("Search subfolders", true)
        d.check("Case sensitive text", false)
        d.check("Include hidden files", showHidden)
        d.text("Search in: " + abbreviatePath(active.path.path))
        d.onClose = { [unowned self] r, d in
            guard r == 0 else { return }
            runFind(root: active.path, mask: d.fields[0].text.isEmpty ? "*" : d.fields[0].text, text: d.fields[1].text,
                    recursive: d.checks[0].on, caseSensitive: d.checks[1].on, hidden: d.checks[2].on)
        }
        push(d)
    }

    private func runFind(root: URL, mask: String, text: String, recursive: Bool, caseSensitive: Bool, hidden: Bool) {
        let l = ListPicker(app: self, title: "Find: searching…", items: [])
        l.minWidth = min(100, screenCols - 8)
        l.footer = "Searching in " + abbreviatePath(root.path)
        l.filterable = false
        let lock = NSLock()
        var cancelled = false
        var found: [URL] = []
        var scanned = 0
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        l.onCancel = { _ in lock.lock(); cancelled = true; lock.unlock() }
        l.onSelect = { [unowned self] i, _ in
            lock.lock(); cancelled = true; lock.unlock()
            let u = found[i]
            active.go(u.deletingLastPathComponent(), select: u.lastPathComponent)
            if active.mode == .info || active.mode == .quickView { active.mode = .full }
        }
        l.onKey = { [unowned self] k, l in
            if k.code == .f(3), found.indices.contains(l.cursor) {
                if let v = try? Viewer(app: self, url: found[l.cursor]) { push(v) }
                return true
            }
            return false
        }
        push(l)
        activeJobs += 1
        let needle = Array(text.utf8)
        let rootPath: String = root.path.withCString { c in
            guard let r = realpath(c, nil) else { return root.path }
            defer { free(r) }
            return String(cString: r)
        }
        let root = URL(fileURLWithPath: rootPath)
        DispatchQueue.global(qos: .userInitiated).async {
            var opts: FileManager.DirectoryEnumerationOptions = []
            if !hidden { opts.insert(.skipsHiddenFiles) }
            if !recursive { opts.insert(.skipsSubdirectoryDescendants) }
            let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: opts, errorHandler: { _, _ in true })
            var batch: [URL] = []
            var lastFlush = Date()
            func flush(_ final: Bool) {
                let b = batch; batch = []
                let sc = scanned
                DispatchQueue.main.async {
                    found.append(contentsOf: b)
                    l.items.append(contentsOf: b.map { u in
                        let rel = u.path.hasPrefix(rootPath + "/") ? String(u.path.dropFirst(rootPath.count + 1)) : u.path
                        return (label: rel, hint: "")
                    })
                    l.title = (final ? "Find: " : "Find: searching… ") + "\(found.count) found"
                    l.footer = final ? "Done. \(sc) items scanned. Enter: go to file  F3: view" : "Scanned \(sc) items…"
                    self.view?.refresh()
                }
            }
            while let u = en?.nextObject() as? URL {
                if isCancelled() { break }
                scanned += 1
                guard matchesMask(u.lastPathComponent, mask) else { continue }
                if !needle.isEmpty {
                    guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    if !fileContains(u, needle, caseSensitive: caseSensitive, cancelled: isCancelled) { continue }
                }
                batch.append(u)
                if Date().timeIntervalSince(lastFlush) > 0.2 { flush(false); lastFlush = Date() }
            }
            flush(true)
            DispatchQueue.main.async { self.activeJobs -= 1 }
        }
    }

    // MARK: - Command line

    func execute(_ line: String) {
        let c = line.trimmingCharacters(in: .whitespaces)
        cmd.text = ""
        histIdx = nil
        guard !c.isEmpty else { return }
        if terminalVisible, let d = dock {
            d.run(c); d.focus(); return
        }
        cmdHistory.removeAll { $0 == c }
        cmdHistory.append(c)
        if cmdHistory.count > 500 { cmdHistory.removeFirst() }

        if c == "cd" || c.hasPrefix("cd ") {
            let arg = c == "cd" ? "~" : String(c.dropFirst(3))
            if arg.trimmingCharacters(in: .whitespaces) == "-" {
                if let b = active.history.popLast() { active.go(b, recordHistory: false) }
            } else {
                active.go(expandPath(arg, relativeTo: active.path))
            }
            return
        }
        if c == "cls" || c == "clear" { console.removeAll(); consolePartial = ""; return }
        if c == "exit" || c == "quit" { quit(); return }
        if running != nil { toast("A command is already running (Ctrl-C to interrupt)"); return }

        console.append("\u{1}" + abbreviatePath(active.path.path) + "> " + c)
        consoleScroll = 0
        panelsVisible = false
        runningOutput = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", c]
        p.currentDirectoryURL = active.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["COLUMNS"] = "\(screenCols)"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.appendConsole(s) }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                guard let self = self else { return }
                if !self.consolePartial.isEmpty { self.console.append(self.consolePartial); self.consolePartial = "" }
                let status = proc.terminationStatus
                if status != 0 { self.console.append("\u{1}[exit \(status)]") }
                self.running = nil
                if !self.runningOutput && status == 0 { self.panelsVisible = true }
                self.left.reload(); self.right.reload()
                self.view?.refresh()
            }
        }
        do {
            try p.run()
            running = p
        } catch {
            console.append("Failed: \(error.localizedDescription)")
        }
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[A-Za-z]|\u{1B}\\][^\u{7}]*\u{7}|\u{1B}[()][A-Z0-9]")

    private func appendConsole(_ s: String) {
        runningOutput = true
        let clean = Commander.ansi.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        var text = consolePartial + clean
        consolePartial = ""
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parts = text.components(separatedBy: "\n")
        let last = parts.removeLast()
        for p in parts {
            console.append(p.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? "")
        }
        consolePartial = last.components(separatedBy: "\r").last ?? ""
        if console.count > 10000 { console.removeFirst(console.count - 10000) }
        view?.refresh()
    }

    // MARK: - Quit

    func quit() {
        if confirmQuit {
            message("RetroDir", "Do you want to quit RetroDir?", buttons: ["Yes", "No"]) { [unowned self] r in
                if r == 0 { saveSettings(); NSApp.terminate(nil) }
            }
        } else {
            saveSettings()
            NSApp.terminate(nil)
        }
    }
}

/// Streams a file looking for a byte sequence (ASCII case-folding when not case sensitive).
func fileContains(_ url: URL, _ needle: [UInt8], caseSensitive: Bool, cancelled: () -> Bool) -> Bool {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? fh.close() }
    func low(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
    let nd = caseSensitive ? needle : needle.map(low)
    let m = nd.count
    var carry: [UInt8] = []
    while true {
        if cancelled() { return false }
        guard let chunk = try? fh.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
        var buf = carry + [UInt8](chunk)
        if !caseSensitive { for i in 0..<buf.count { buf[i] = low(buf[i]) } }
        if buf.count >= m {
            var i = 0
            let first = nd[0]
            while i <= buf.count - m {
                if buf[i] == first {
                    var j = 1
                    while j < m && buf[i + j] == nd[j] { j += 1 }
                    if j == m { return true }
                }
                i += 1
            }
        }
        carry = Array(buf.suffix(max(0, m - 1)))
    }
}
