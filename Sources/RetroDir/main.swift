import AppKit

final class DropView: NSView {
    weak var term: TermView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, let term = term else { return false }
        // Drop on the panel under the mouse.
        let p = term.convert(sender.draggingLocation, from: nil)
        let app = term.app
        if app.panelsVisible && app.layers.isEmpty {
            app.activeLeft = Int(p.x / term.cellW) < app.left.frame.x + app.left.frame.w
        }
        app.dropFiles(urls)
        term.refresh()
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let commander = Commander()
    var term: TermView!

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        commander.start()
        term = TermView(app: commander, fontSize: commander.fontSize)
        commander.view = term

        let cols: CGFloat = 132, rows: CGFloat = 42
        let size = NSSize(width: ceil(term.cellW * cols), height: ceil(term.cellH * rows))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "RetroDir"
        window.delegate = self
        window.contentResizeIncrements = NSSize(width: term.cellW, height: term.cellH)
        window.contentMinSize = NSSize(width: term.cellW * 60, height: term.cellH * 16)
        let container = DropView(frame: NSRect(origin: .zero, size: size))
        container.term = term
        term.frame = container.bounds
        term.autoresizingMask = [.width, .height]
        container.addSubview(term)
        window.contentView = container
        commander.container = container
        window.center()
        window.setFrameAutosaveName("RetroDirMain")
        window.backgroundColor = .black
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(term)
        NSApp.activate(ignoringOtherApps: true)
        if UserDefaults.standard.bool(forKey: "terminalVisible") && !ProcessInfo.processInfo.arguments.contains("--snapshot") {
            commander.showTerminal(focus: false)
        }

        runTestScriptIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        if !ProcessInfo.processInfo.arguments.contains("--snapshot") { commander.saveSettings() }
    }

    private func buildMenu() {
        let main = NSMenu()
        main.autoenablesItems = true
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About RetroDir", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide RetroDir", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit RetroDir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        // Edit menu: routes Cmd-C/V/A to the embedded terminal when it has focus
        // (the panels handle these keys themselves before the menu sees them).
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        winMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    // MARK: - Scripted snapshot mode (used for automated checks)
    // RetroDir --snapshot out.png [--left DIR] [--right DIR] [--keys "F9,Down,Enter,wait:500,text:abc"] [--size 132x42]

    private func runTestScriptIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let si = args.firstIndex(of: "--snapshot"), si + 1 < args.count else { return }
        let out = args[si + 1]
        func arg(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let l = arg("--left") { commander.left.go(URL(fileURLWithPath: l), recordHistory: false) }
        if let r = arg("--right") { commander.right.go(URL(fileURLWithPath: r), recordHistory: false) }
        if let t = arg("--theme"), let i = Int(t) { commander.themeIndex = i }
        if let sz = arg("--size") {
            let parts = sz.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                window.setContentSize(NSSize(width: ceil(term.cellW * parts[0]), height: ceil(term.cellH * parts[1])))
            }
        }
        commander.confirmQuit = false
        var steps = (arg("--keys") ?? "").split(separator: ",").map(String.init)
        func next() {
            guard !steps.isEmpty else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let root = self.window.contentView!
                    root.display()
                    if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                        root.cacheDisplay(in: root.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                    }
                    exit(0)
                }
                return
            }
            let s = steps.removeFirst()
            if s.hasPrefix("wait:"), let ms = Double(s.dropFirst(5)) {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000) { next() }
                return
            }
            if s.hasPrefix("dump:"), let d = commander.dock {
                // Write every tab's screen text (for automated checks).
                let text = d.tabs.enumerated().map { i, t in
                    "=== tab \(i + 1): \(t.title)\n" + String(decoding: t.view.getTerminal().getBufferAsData(), as: UTF8.self)
                }.joined(separator: "\n")
                try? text.write(toFile: String(s.dropFirst(5)), atomically: true, encoding: .utf8)
            } else if s.hasPrefix("term:") {
                commander.dock?.run(String(s.dropFirst(5)))
            } else if s.hasPrefix("text:") {
                for c in s.dropFirst(5) { commander.key(Key(code: .char(c))) }
            } else if let k = parseKey(s) {
                commander.key(k)
            }
            term.refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
    }

    private func parseKey(_ s: String) -> Key? {
        var mods: Mods = []
        var name = Substring(s)
        while name.count > 2, name.dropFirst().first == "-" {
            switch name.first! {
            case "S": mods.insert(.shift)
            case "C": mods.insert(.ctrl)
            case "A": mods.insert(.alt)
            case "M": mods.insert(.cmd)
            default: break
            }
            name = name.dropFirst(2)
        }
        let map: [String: Key.Code] = ["Up": .up, "Down": .down, "Left": .left, "Right": .right, "Home": .home, "End": .end,
                                       "PgUp": .pageUp, "PgDn": .pageDown, "Enter": .enter, "Esc": .escape, "Tab": .tab,
                                       "Bksp": .backspace, "Del": .delete, "Ins": .insert, "Space": .char(" ")]
        if let c = map[String(name)] { return Key(code: c, mods: mods) }
        if name.first == "F", let n = Int(name.dropFirst()) { return Key(code: .f(n), mods: mods) }
        if name.count == 1, mods == [.cmd], let n = Int(String(name)), n > 0 { return Key(code: .f(n), mods: [], cmdDigit: n) }
        if name.count == 1 { return Key(code: .char(name.first!), mods: mods) }
        return nil
    }
}

/// One-time copy of preferences saved under the app's previous name (MacCommander).
func migrateOldSettings() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: "migratedFromMacCommander"),
          let old = UserDefaults(suiteName: "com.ehsanhaque.maccommander")?.persistentDomain(forName: "com.ehsanhaque.maccommander") else { return }
    for (k, v) in old where d.object(forKey: k) == nil {
        d.set(v, forKey: k.replacingOccurrences(of: "MacCommanderMain", with: "RetroDirMain"))
    }
    d.set(true, forKey: "migratedFromMacCommander")
}
migrateOldSettings()

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
