import AppKit
import SwiftTerm

/// One shell session in the bottom terminal.
final class TermTab {
    let view: LocalProcessTerminalView
    var customName: String?
    var oscTitle = ""
    let shellName: String

    init(view: LocalProcessTerminalView, shellName: String) {
        self.view = view
        self.shellName = shellName
    }

    var pid: pid_t { view.process?.shellPid ?? 0 }

    /// Current directory of the shell process (works without any shell integration).
    var cwd: String? {
        let p = pid
        guard p > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(p, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    var title: String {
        if let n = customName, !n.isEmpty { return n }
        if !oscTitle.isEmpty { return oscTitle }
        let dir = cwd.map { abbreviatePath($0) } ?? ""
        let last = dir == "~" || dir == "/" ? dir : (dir as NSString).lastPathComponent
        return last.isEmpty ? shellName : "\(shellName): \(last)"
    }
}

/// Hosts the embedded terminal tabs. Each tab is a SwiftTerm view running the user's login shell in a PTY.
final class TerminalDock: NSView, LocalProcessTerminalViewDelegate {
    unowned let app: Commander
    private(set) var tabs: [TermTab] = []
    private(set) var current = 0
    var onEmpty: (() -> Void)?

    init(app: Commander) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true
        autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var currentTab: TermTab? { tabs.indices.contains(current) ? tabs[current] : nil }

    var isFocused: Bool {
        guard let r = window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: self)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        for t in tabs { t.view.frame = bounds }
    }

    // MARK: Shell

    /// The user's login shell from the directory service (falls back to $SHELL, then zsh).
    static var loginShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if FileManager.default.isExecutableFile(atPath: s) { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Full user environment (keeps SSH_AUTH_SOCK, PATH, LANG, etc.) plus terminal settings.
    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["TERM_SESSION_ID", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"] { env.removeValue(forKey: k) }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "RetroDir"
        env["TERM_PROGRAM_VERSION"] = "1.0"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOME"] = NSHomeDirectory()
        if let pw = getpwuid(getuid()) {
            env["USER"] = String(cString: pw.pointee.pw_name)
            env["LOGNAME"] = env["USER"]
        }
        env["SHELL"] = loginShell
        return env.map { "\($0.key)=\($0.value)" }
    }

    @discardableResult
    func newTab(cwd: URL) -> TermTab {
        let v = LocalProcessTerminalView(frame: bounds)
        v.autoresizingMask = [.width, .height]
        v.processDelegate = self
        v.optionAsMetaKey = true
        applyStyle(v)
        let shell = TerminalDock.loginShell
        let name = (shell as NSString).lastPathComponent
        let tab = TermTab(view: v, shellName: name)
        tabs.append(tab)
        addSubview(v)
        // A leading "-" in argv[0] makes zsh/bash/fish run as a login shell, so ~/.zprofile,
        // ~/.zshrc, ~/.bash_profile, /etc/paths (path_helper) etc. are all loaded.
        v.startProcess(executable: shell, args: [], environment: TerminalDock.environment(),
                       execName: "-" + name, currentDirectory: cwd.path)
        select(tabs.count - 1)
        return tab
    }

    func select(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        current = i
        for (j, t) in tabs.enumerated() { t.view.isHidden = j != i }
        tabs[i].view.frame = bounds
        focus()
        app.view?.refresh()
    }

    func next(_ d: Int) {
        guard !tabs.isEmpty else { return }
        select((current + d + tabs.count) % tabs.count)
    }

    func close(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let t = tabs.remove(at: i)
        t.view.processDelegate = nil
        t.view.terminate()
        t.view.removeFromSuperview()
        if tabs.isEmpty {
            current = 0
            onEmpty?()
        } else {
            select(min(i, tabs.count - 1))
        }
        app.view?.refresh()
    }

    func move(_ from: Int, by d: Int) {
        let to = from + d
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        tabs.swapAt(from, to)
        current = to
        app.view?.refresh()
    }

    func focus() {
        guard let t = currentTab, !isHidden else { return }
        window?.makeFirstResponder(t.view)
    }

    /// Type text into the current shell.
    func send(_ s: String) { currentTab?.view.send(txt: s) }

    /// Run a command line in the current shell.
    func run(_ cmd: String) { send(cmd + "\r") }

    // MARK: Style

    func applyStyle(_ v: LocalProcessTerminalView? = nil) {
        let views = v.map { [$0] } ?? tabs.map(\.view)
        let pal = app.theme.palette
        let font = NSFont(name: "Menlo", size: app.fontSize) ?? .monospacedSystemFont(ofSize: app.fontSize, weight: .regular)
        for tv in views {
            tv.font = font
            tv.nativeBackgroundColor = NSColor(cgColor: pal[0]) ?? .black
            tv.nativeForegroundColor = NSColor(cgColor: pal[7]) ?? .lightGray
            tv.caretColor = NSColor(cgColor: pal[11]) ?? .cyan
            tv.selectedTextBackgroundColor = (NSColor(cgColor: pal[3]) ?? .darkGray).withAlphaComponent(0.6)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        if let t = tabs.first(where: { $0.view === source }) { t.oscTitle = title }
        app.view?.refresh()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let i = self.tabs.firstIndex(where: { $0.view === source }) else { return }
            self.close(i)
        }
    }
}
