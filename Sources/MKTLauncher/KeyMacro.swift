import Foundation
import AppKit

/// A key (plus modifiers) that sends a fixed sequence to the host, like KoalaTerm's key mapping.
///
/// Sequence syntax is KoalaTerm's: `<ESC>` `<CR>` `<LF>` `<TAB>` `<CSI>`, `^C` for control
/// characters, `\xNN` for any byte, `\\` `\<` `\^` for literals. `<UP>` `<DOWN>` `<LEFT>` `<RIGHT>`
/// send the cursor key in whatever mode the host has selected. An empty sequence disables the key.
struct KeyMacro: Codable, Hashable, Identifiable {
    var id = UUID()
    var key: String
    var shift = false
    var control = false
    var option = false
    var sequence: String

    init(_ key: String, shift: Bool = false, control: Bool = false, option: Bool = false, _ sequence: String) {
        self.key = key
        self.shift = shift
        self.control = control
        self.option = option
        self.sequence = sequence
    }

    var displayName: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + key
    }

    /// Key names offered in the editor, mapped to macOS virtual key codes (layout independent,
    /// so they work the same with the Greek keyboard layout).
    static let keyCodes: [(name: String, code: UInt16)] = [
        ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118), ("F5", 96), ("F6", 97),
        ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109), ("F11", 103), ("F12", 111),
        ("Tab", 48), ("Backspace", 51), ("Forward Delete", 117), ("Return", 36), ("Escape", 53),
        ("Up", 126), ("Down", 125), ("Left", 123), ("Right", 124),
        ("Home", 115), ("End", 119), ("Page Up", 116), ("Page Down", 121),
        ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3), ("G", 5), ("H", 4),
        ("I", 34), ("J", 38), ("K", 40), ("L", 37), ("M", 46), ("N", 45), ("O", 31), ("P", 35),
        ("Q", 12), ("R", 15), ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
        ("Y", 16), ("Z", 6),
    ]

    static var keyNames: [String] { keyCodes.map(\.name) }

    /// "A"…"Z" for a letter key's virtual key code (any keyboard layout), else nil.
    static func letter(forKeyCode code: UInt16) -> String? {
        guard let name = keyCodes.first(where: { $0.code == code })?.name,
              name.count == 1, name.first!.isLetter else { return nil }
        return name
    }

    var keyCode: UInt16? { Self.keyCodes.first { $0.name == key }?.code }

    func matches(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        return !f.contains(.command)
            && event.keyCode == keyCode
            && f.contains(.shift) == shift
            && f.contains(.control) == control
            && f.contains(.option) == option
    }

    /// Bytes to send. `applicationCursor` selects ESC O A vs ESC [ A for the arrow tokens.
    func bytes(applicationCursor: Bool, encodeText: (String) -> [UInt8]) -> [UInt8] {
        Self.parse(sequence, applicationCursor: applicationCursor, encodeText: encodeText)
    }

    /// `encodeText` converts literal (non-escape) characters to the host's character set.
    static func parse(_ s: String, applicationCursor: Bool = false,
                      encodeText: (String) -> [UInt8] = { Array($0.utf8) }) -> [UInt8] {
        let arrow = applicationCursor ? "\u{1b}O" : "\u{1b}["
        let tokens: [String: String] = [
            "<ESC>": "\u{1b}", "<CR>": "\r", "<LF>": "\n", "<TAB>": "\t", "<CSI>": "\u{1b}[",
            "<UP>": arrow + "A", "<DOWN>": arrow + "B", "<RIGHT>": arrow + "C", "<LEFT>": arrow + "D",
        ]
        var out = [UInt8]()
        let chars = Array(s)
        var i = 0
        outer: while i < chars.count {
            let ch = chars[i]
            if ch == "<" {
                for (tok, val) in tokens {
                    let t = Array(tok)
                    if i + t.count <= chars.count,
                       String(chars[i..<i + t.count]).uppercased() == tok {
                        out += Array(val.utf8)
                        i += t.count
                        continue outer
                    }
                }
            } else if ch == "^", i + 1 < chars.count,
                      let a = chars[i + 1].uppercased().unicodeScalars.first?.value, (64...95).contains(a) {
                out.append(UInt8(a - 64))
                i += 2
                continue
            } else if ch == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if (n == "x" || n == "X"), i + 3 < chars.count,
                   let v = UInt8(String(chars[i + 2...i + 3]), radix: 16) {
                    out.append(v)
                    i += 4
                    continue
                }
                out += encodeText(String(n))
                i += 2
                continue
            }
            out += encodeText(String(ch))
            i += 1
        }
        return out
    }

    // MARK: Defaults ported from THETIS.mkt / newTHISEAS.mkt

    /// Mappings both KoalaTerm profiles share (VT220 template + their own overrides).
    static var koalaCommon: [KeyMacro] {
        var m: [KeyMacro] = [KeyMacro("F5", "<ESC>[16~")]
        // Shift+F1…F10 -> VT220 F11…F20 (F15 = Help, F16 = Do)
        let vt = ["23", "24", "25", "26", "28", "29", "31", "32", "33", "34"]
        for (n, code) in vt.enumerated() {
            m.append(KeyMacro("F\(n + 1)", shift: true, "<ESC>[\(code)~"))
        }
        m.append(KeyMacro("Tab", shift: true, "<UP>"))      // Shift+Tab = previous field
        m.append(KeyMacro("S", control: true, ""))          // Ctrl+S (XOFF) would freeze the screen
        return m
    }

    static var thetis: [KeyMacro] { koalaCommon }

    static var thiseas: [KeyMacro] { koalaCommon + [KeyMacro("U", control: true, "")] }
}
