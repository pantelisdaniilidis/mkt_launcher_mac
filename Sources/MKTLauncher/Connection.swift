import Foundation
import CoreFoundation
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// Character set the host uses on the wire. The terminal itself works in Unicode,
/// so bytes are translated in both directions.
enum TermEncoding: String, Codable, CaseIterable, Identifiable {
    case isoGreek = "iso-8859-7"
    case windowsGreek = "windows-1253"
    case dosGreek = "cp737"
    case dosLatin = "cp437"
    case latin1 = "iso-8859-1"
    case utf8 = "utf-8"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .isoGreek: return "Greek ISO-8859-7 (ELOT 928)"
        case .windowsGreek: return "Greek Windows-1253"
        case .dosGreek: return "Greek DOS CP737"
        case .dosLatin: return "DOS CP437"
        case .latin1: return "Western ISO-8859-1"
        case .utf8: return "UTF-8"
        }
    }

    var stringEncoding: String.Encoding {
        func cf(_ e: CFStringEncodings) -> String.Encoding {
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
        }
        switch self {
        case .isoGreek: return cf(.isoLatinGreek)
        case .windowsGreek: return .windowsCP1253
        case .dosGreek: return cf(.dosGreek)
        case .dosLatin: return cf(.dosLatinUS)
        case .latin1: return .isoLatin1
        case .utf8: return .utf8
        }
    }
}

enum TermTheme: String, Codable, CaseIterable, Identifiable {
    case dark, light, green
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark: return "Dark (white on black)"
        case .light: return "Light (black on white)"
        case .green: return "Green phosphor"
        }
    }
}

struct Connection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 23
    /// Sent automatically when the host asks for "login:" / "name:" (optional).
    var username: String = ""
    var terminalType: String = "vt220"
    var encoding: TermEncoding = .isoGreek
    var columns: Int = 80
    var rows: Int = 25
    var fontSize: Double = 14
    var theme: TermTheme = .dark
    var backspaceSendsCtrlH: Bool = false
    var macros: [KeyMacro] = KeyMacro.koalaCommon

    static let terminalTypes = ["vt220", "vt100", "vt320", "xterm", "ansi"]

    /// Default connections bundled into the app by build.sh from Config/connections.json
    /// (kept out of git because it holds internal host names), or the example file.
    static var defaults: [Connection] {
        guard let url = Bundle.main.url(forResource: "default-connections", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Connection].self, from: data) else { return [] }
        return list.map { var c = $0; c.id = UUID(); return c }
    }

    // Tolerant decoding so files written by older versions keep working.
    init(name: String, host: String) {
        self.name = name
        self.host = host
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Connection(name: "", host: "")
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? d.username
        terminalType = try c.decodeIfPresent(String.self, forKey: .terminalType) ?? d.terminalType
        encoding = (try? c.decodeIfPresent(TermEncoding.self, forKey: .encoding)) ?? d.encoding
        columns = try c.decodeIfPresent(Int.self, forKey: .columns) ?? d.columns
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? d.rows
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        theme = (try? c.decodeIfPresent(TermTheme.self, forKey: .theme)) ?? d.theme
        backspaceSendsCtrlH = try c.decodeIfPresent(Bool.self, forKey: .backspaceSendsCtrlH) ?? d.backspaceSendsCtrlH
        macros = (try? c.decodeIfPresent([KeyMacro].self, forKey: .macros)) ?? d.macros
    }
}

/// Persists the connection list as JSON in ~/Library/Application Support/MKTLauncher.
final class ConnectionStore: ObservableObject {
    @Published var connections: [Connection] = [] {
        didSet { save() }
    }

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MKTLauncher", isDirectory: true)
            .appendingPathComponent("connections.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = Self.migrate(list)
        } else {
            connections = Connection.defaults
        }
    }

    /// v2: entries that share a name with a bundled default take its host, keys and macros
    /// (e.g. a host that moved). Runs once per Mac.
    private static func migrate(_ list: [Connection]) -> [Connection] {
        let key = "migratedV2"
        guard !UserDefaults.standard.bool(forKey: key) else { return list }
        UserDefaults.standard.set(true, forKey: key)
        let defaults = Connection.defaults
        return list.map { c in
            guard let d = defaults.first(where: { $0.name.caseInsensitiveCompare(c.name) == .orderedSame }) else {
                return c
            }
            var c = c
            c.host = d.host
            c.port = d.port
            c.macros = d.macros
            c.backspaceSendsCtrlH = d.backspaceSendsCtrlH
            return c
        }
    }

    func upsert(_ c: Connection) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) {
            connections[i] = c
        } else {
            connections.append(c)
        }
    }

    func delete(_ c: Connection) {
        connections.removeAll { $0.id == c.id }
    }

    func move(from: IndexSet, to: Int) {
        connections.move(fromOffsets: from, toOffset: to)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(connections).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MKTLauncher: could not save connections: \(error)")
        }
    }
}

/// Reads the connection details out of a KoalaTerm (MKT V3.00) setup file.
///
/// The file is a header string followed by tagged fields: [field id][group][type][value].
/// We only need a handful of them, so we look each tag up directly:
///   group 6 / field 1  HostName (string)    group 6 / field 4  Port (int32)
///   group 3 / field 7  Columns  (int32)     group 3 / field 8  Lines (int32)
///   group 9 / field 13 Title    (string)
enum MKTImporter {
    static func load(_ url: URL) -> Connection? {
        guard let data = try? Data(contentsOf: url), data.count > 32 else { return nil }
        let bytes = [UInt8](data)
        guard String(decoding: bytes.prefix(32), as: UTF8.self).contains("MKT") else { return nil }

        guard let host = string(bytes, field: 1, group: 6), !host.isEmpty else { return nil }
        let fileName = url.deletingPathExtension().lastPathComponent
        var c = Connection(name: fileName.uppercased(), host: host)
        if let port = int(bytes, field: 4, group: 6), port > 0, port < 65536 { c.port = port }
        if let cols = int(bytes, field: 7, group: 3), (40...200).contains(cols) { c.columns = cols }
        if let rows = int(bytes, field: 8, group: 3), (10...100).contains(rows) { c.rows = rows }
        if let title = string(bytes, field: 13, group: 9), !title.isEmpty {
            c.name = title.replacingOccurrences(of: " 2.0", with: "")
        }
        // Key map entries: [PC virtual key][modifiers: 2 = Ctrl, 4 = Shift][0xFF = send][len][bytes]
        if find(bytes, [0x08, 0x00, 0xFF, 0x01, 0x08]) != nil { c.backspaceSendsCtrlH = true }
        if find(bytes, [0x55, 0x02, 0xFF, 0x00]) != nil {
            c.macros.append(KeyMacro("U", control: true, ""))
        }
        return c
    }

    private static func find(_ b: [UInt8], _ tag: [UInt8]) -> Int? {
        guard b.count > tag.count else { return nil }
        // Skip the header string (length-prefixed).
        let start = 1 + Int(b[0])
        var i = start
        while i + tag.count <= b.count {
            if b[i] == tag[0] && Array(b[i..<i + tag.count]) == tag { return i + tag.count }
            i += 1
        }
        return nil
    }

    private static func string(_ b: [UInt8], field: UInt8, group: UInt8) -> String? {
        guard let p = find(b, [field, group, 1]), p < b.count else { return nil }
        let len = Int(b[p])
        guard p + 1 + len <= b.count else { return nil }
        let raw = Data(b[(p + 1)..<(p + 1 + len)])
        return String(data: raw, encoding: .windowsCP1253) ?? String(decoding: raw, as: UTF8.self)
    }

    private static func int(_ b: [UInt8], field: UInt8, group: UInt8) -> Int? {
        guard let p = find(b, [field, group, 0]), p + 4 <= b.count else { return nil }
        return Int(Int32(littleEndian: b[p..<p + 4].enumerated().reduce(0) { $0 | Int32($1.element) << (8 * $1.offset) }))
    }
}
