import AppKit
import SwiftTerm

/// One terminal window connected to one host.
final class TerminalSession: NSObject, NSWindowDelegate, TerminalViewDelegate {
    private static var sessions: [TerminalSession] = []

    static func start(_ connection: Connection) {
        let s = TerminalSession(connection)
        sessions.append(s)
        s.show()
        s.connect()
    }

    /// Session of the frontmost terminal window, if any.
    static var current: TerminalSession? {
        sessions.first { $0.window === NSApp.keyWindow }
    }

    static var connectedCount: Int { sessions.filter { $0.telnet.isConnected }.count }

    static func closeAll() {
        for s in sessions { s.telnet.close() }
    }

    let connection: Connection
    let window: NSWindow
    private let termView: TerminalView
    private let container: FitContainer
    private let telnet = TelnetClient()
    private let codec: CharsetCodec
    private var loginSent = false
    private var recentOutput = ""
    private var waitingForReconnect = false
    private var keyMonitor: Any?

    private init(_ c: Connection) {
        connection = c
        codec = CharsetCodec(c.encoding)

        let font = NSFont(name: "Menlo", size: c.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: c.fontSize, weight: .regular)
        termView = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: font)
        termView.getTerminal().resize(cols: c.columns, rows: c.rows)
        let size = termView.getOptimalFrameSize().size
        termView.frame = NSRect(origin: .zero, size: size)
        container = FitContainer(content: termView, naturalSize: size)

        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        termView.terminalDelegate = self
        termView.backspaceSendsControlH = c.backspaceSendsCtrlH
        termView.optionAsMetaKey = false
        applyTheme(c.theme)
        container.fillColor = termView.nativeBackgroundColor

        window.contentView = container
        window.contentMinSize = NSSize(width: size.width * 0.5, height: size.height * 0.5)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.title = c.name
        window.subtitle = "\(c.host):\(c.port)"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("MKTSession-\(c.id.uuidString)")

        telnet.terminalType = c.terminalType
        telnet.onEvent = { [weak self] in self?.handle($0) }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    // MARK: Keyboard: ⌘V paste and KoalaTerm-style macros

    static let commandAsControlKey = "commandAsControl"
    static var commandAsControl: Bool {
        UserDefaults.standard.object(forKey: commandAsControlKey) as? Bool ?? true
    }

    /// Returns true when the key was consumed.
    ///
    /// The rule: ⌘ on the Mac = Ctrl on Windows. ⌘Z sends Ctrl-Z, ⌘A sends Ctrl-A, …
    /// Exceptions: ⌘V pastes, ⌘C copies when text is selected (otherwise sends Ctrl-C),
    /// and ⌘Q ⌘W ⌘H ⌘M keep their usual Mac meaning. Real Ctrl keeps working too.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Backspace: send exactly what the connection wants (Unixfor/AIX erase with ^H, ignore DEL).
        if event.keyCode == 51, flags.isSubset(of: [.shift]),
           !connection.macros.contains(where: { $0.matches(event) }) {
            if telnet.isConnected { telnet.send([connection.backspaceSendsCtrlH ? 0x08 : 0x7F]) }
            return true
        }
        if flags == .command, let letter = KeyMacro.letter(forKeyCode: event.keyCode) {
            switch letter {
            case "V":
                pasteClipboard()
                return true
            case "C" where termView.getSelection() != nil:
                return false // Edit > Copy
            case "Q", "W", "H", "M":
                return false
            default:
                guard TerminalSession.commandAsControl else { return false }
                sendControl(letter)
                return true
            }
        }
        guard let macro = connection.macros.first(where: { $0.matches(event) }) else { return false }
        send(macro)
        return true
    }

    private func send(_ macro: KeyMacro) {
        guard telnet.isConnected else { return }
        let codec = self.codec
        let bytes = macro.bytes(applicationCursor: termView.getTerminal().applicationCursor,
                                encodeText: { codec.encode(Array($0.utf8)) })
        telnet.send(bytes)
    }

    /// Sends Ctrl+letter, honouring a macro on that Ctrl key (e.g. Ctrl-S disabled).
    private func sendControl(_ letter: String) {
        if let macro = connection.macros.first(where: {
            $0.key == letter && $0.control && !$0.shift && !$0.option
        }) {
            send(macro)
        } else if telnet.isConnected, let a = letter.unicodeScalars.first?.value {
            telnet.send([UInt8(a - 64)])
        }
    }

    @objc func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        guard telnet.isConnected else { NSSound.beep(); return }
        // The host expects Return (CR) at line ends, not LF.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        var bytes = codec.encode(Array(normalized.utf8))
        if termView.getTerminal().bracketedPasteMode {
            bytes = Array("\u{1b}[200~".utf8) + bytes + Array("\u{1b}[201~".utf8)
        }
        termView.scroll(toPosition: 1)
        telnet.send(bytes)
    }

    private func show() {
        if !window.setFrameUsingName("MKTSession-\(connection.id.uuidString)") {
            window.center()
        }
        // Offset windows of the same connection so they don't stack exactly.
        if TerminalSession.sessions.filter({ $0.connection.id == connection.id }).count > 1 {
            window.setFrameOrigin(NSPoint(x: window.frame.minX + 24, y: window.frame.minY - 24))
        }
        #if MKT_DEBUG
        if let s = ProcessInfo.processInfo.environment["MKT_WINDOW_SIZE"]?.split(separator: "x"),
           s.count == 2, let w = Double(s[0]), let h = Double(s[1]) {
            window.setContentSize(NSSize(width: w, height: h))
        }
        if ProcessInfo.processInfo.environment["MKT_KEY_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runKeyTest() }
        }
        if let mode = ProcessInfo.processInfo.environment["MKT_RESIZE_TEST"] {
            // Resize the visible window repeatedly, then go full screen and back.
            let sizes: [NSSize] = [.init(width: 900, height: 600), .init(width: 1400, height: 900),
                                   .init(width: 500, height: 300), .init(width: 1200, height: 700)]
            for (i, s) in sizes.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.5) { [weak self] in
                    self?.window.setContentSize(s)
                    NSLog("MKT_RESIZE_TEST size \(s)")
                }
            }
            if mode == "fs" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in self?.window.toggleFullScreen(nil) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { [weak self] in
                NSLog("MKT_RESIZE_TEST fullscreen frame \(self?.window.frame ?? .zero)")
            }
        }
        #endif
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(termView)
    }

    #if MKT_DEBUG
    /// Posts synthetic key presses through the normal event path (monitor + terminal view).
    private func runKeyTest() {
        let pb = NSPasteboard.general
        let savedClipboard = pb.string(forType: .string)
        pb.clearContents()
        pb.setString("Γειά\nx", forType: .string)
        let f5 = String(Character(UnicodeScalar(UInt32(NSF5FunctionKey))!))
        let keys: [(UInt16, NSEvent.ModifierFlags, String)] = [
            (0, [], "a"), (11, [], "b"), (51, [], "\u{7f}"),     // a b Backspace
            (6, [.command], "z"),                                // ⌘Z
            (48, [.shift], "\u{19}"),                            // ⇧Tab
            (96, [.function], f5),                               // F5
            (0, [], "α"),                                        // Greek alpha
            (9, [.command], "v"),                                // ⌘V
        ]
        for (code, flags, chars) in keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: code) {
                    NSApp.postEvent(e, atStart: false)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            pb.clearContents()
            if let s = savedClipboard { pb.setString(s, forType: .string) }
            NSLog("MKT_KEY_TEST done")
        }
    }
    #endif

    private func applyTheme(_ theme: TermTheme) {
        switch theme {
        case .dark:
            termView.nativeBackgroundColor = .black
            termView.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
            termView.caretColor = NSColor(white: 0.85, alpha: 1)
        case .light:
            termView.nativeBackgroundColor = .white
            termView.nativeForegroundColor = .black
            termView.caretColor = .darkGray
        case .green:
            termView.nativeBackgroundColor = NSColor(red: 0.0, green: 0.07, blue: 0.0, alpha: 1)
            termView.nativeForegroundColor = NSColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)
            termView.caretColor = NSColor(red: 0.2, green: 1.0, blue: 0.4, alpha: 1)
        }
    }

    // MARK: Connection

    func connect() {
        loginSent = false
        recentOutput = ""
        waitingForReconnect = false
        window.subtitle = "\(connection.host):\(connection.port) — connecting…"
        status("Connecting to \(connection.host):\(connection.port)…")
        let t = termView.getTerminal()
        telnet.setWindowSize(cols: t.cols, rows: t.rows)
        telnet.connect(host: connection.host, port: connection.port)
    }

    func reconnect() {
        telnet.close()
        termView.getTerminal().resetToInitialState()
        connect()
    }

    func disconnect() {
        guard telnet.isConnected else { return }
        telnet.close()
        handle(.closed("Disconnected by user"))
    }

    private func status(_ text: String) {
        termView.feed(text: "\u{1b}[0m\r\n\u{1b}[7m \(text) \u{1b}[0m\r\n")
    }

    private func handle(_ event: TelnetClient.Event) {
        switch event {
        case .connected:
            window.subtitle = "\(connection.host):\(connection.port)"
            status("Connected.")
        case .data(let bytes):
            let utf8 = codec.decode(bytes)
            termView.feed(byteArray: utf8[...])
            autoLogin(utf8)
        case .closed(let reason):
            window.subtitle = "\(connection.host):\(connection.port) — disconnected"
            let why = reason.map { ": \($0)" } ?? ""
            status("Disconnected\(why). Press Enter or ⇧⌘R to reconnect.")
            waitingForReconnect = true
        }
    }

    /// Mirrors the KoalaTerm login script: when the host asks for the user name, type it.
    private func autoLogin(_ utf8: [UInt8]) {
        let user = connection.username.trimmingCharacters(in: .whitespaces)
        guard !loginSent, !user.isEmpty else { return }
        recentOutput += String(decoding: utf8, as: UTF8.self).lowercased()
        if recentOutput.count > 256 { recentOutput = String(recentOutput.suffix(128)) }
        if recentOutput.contains("login:") || recentOutput.contains("name:") {
            loginSent = true
            telnet.send(codec.encode(Array(user.utf8)) + [13])
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if telnet.isConnected {
            telnet.send(codec.encode(data))
        } else if waitingForReconnect && (data.contains(13) || data.contains(10)) {
            reconnect()
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        telnet.setWindowSize(cols: newCols, rows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func bell(source: TerminalView) { NSSound.beep() }
    func clipboardRead(source: TerminalView) -> Data? { nil }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard telnet.isConnected else { return true }
        let alert = NSAlert()
        alert.messageText = "Disconnect from \(connection.name)?"
        alert.informativeText = "Closing this window ends the telnet session."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.telnet.close()
            self.window.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        telnet.onEvent = nil
        telnet.close()
        TerminalSession.sessions.removeAll { $0 === self }
    }
}
