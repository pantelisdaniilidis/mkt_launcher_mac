import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherView: View {
    @EnvironmentObject var store: ConnectionStore
    @State private var selection: Connection.ID?
    @State private var editing: Connection?
    @State private var pendingDelete: Connection?
    @State private var importMessage: String?

    private var selected: Connection? {
        store.connections.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.connections.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            toolbar
        }
        .frame(minWidth: 420, minHeight: 300)
        .sheet(item: $editing) { c in
            ConnectionEditor(connection: c) { saved in
                store.upsert(saved)
                selection = saved.id
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { c in
            Button("Delete", role: .destructive) { store.delete(c) }
        }
        .alert("Import", isPresented: Binding(get: { importMessage != nil },
                                              set: { if !$0 { importMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(store.connections) { c in
                ConnectionRow(connection: c) { TerminalSession.start(c) }
                    .tag(c.id)
            }
            .onMove { store.move(from: $0, to: $1) }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: Connection.ID.self) { ids in
            if let id = ids.first, let c = store.connections.first(where: { $0.id == id }) {
                Button("Connect") { TerminalSession.start(c) }
                Button("Edit…") { editing = c }
                Button("Duplicate") {
                    var copy = c
                    copy.id = UUID()
                    copy.name += " copy"
                    store.upsert(copy)
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = c }
            }
        } primaryAction: { ids in
            for id in ids {
                if let c = store.connections.first(where: { $0.id == id }) { TerminalSession.start(c) }
            }
        }
        .onDeleteCommand { if let c = selected { pendingDelete = c } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No connections")
                .font(.headline)
            if !Connection.defaults.isEmpty {
                Button("Restore default connections") { store.connections = Connection.defaults }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { editing = Connection(name: "", host: "") } label: { Image(systemName: "plus") }
                .help("Add connection")
            Button { if let c = selected { pendingDelete = c } } label: { Image(systemName: "minus") }
                .help("Delete connection")
                .disabled(selected == nil)
            Button { editing = selected } label: { Image(systemName: "pencil") }
                .help("Edit connection")
                .disabled(selected == nil)
            Button("Import .mkt…", action: importMKT)
                .help("Import KoalaTerm (.mkt) setup files")
            Spacer()
            Button("Connect") { if let c = selected { TerminalSession.start(c) } }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
        }
        .padding(10)
    }

    private func importMKT() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "mkt") ?? .data]
        panel.message = "Choose KoalaTerm setup files (.mkt)"
        guard panel.runModal() == .OK else { return }
        var added: [String] = []
        var failed: [String] = []
        for url in panel.urls {
            if let c = MKTImporter.load(url) {
                store.upsert(c)
                added.append(c.name)
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        var msg = added.isEmpty ? "" : "Added: \(added.joined(separator: ", "))."
        if !failed.isEmpty { msg += (msg.isEmpty ? "" : "\n") + "Could not read: \(failed.joined(separator: ", "))." }
        importMessage = msg
    }
}

struct ConnectionRow: View {
    let connection: Connection
    let connect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name).font(.headline)
                Text(verbatim: "\(connection.host):\(connection.port)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect", action: connect)
        }
        .padding(.vertical, 6)
    }
}

struct ConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var connection: Connection
    let onSave: (Connection) -> Void

    private var isValid: Bool {
        !connection.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !connection.host.trimmingCharacters(in: .whitespaces).isEmpty
            && (1...65535).contains(connection.port)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Name", text: $connection.name, prompt: Text("e.g. THETIS"))
                    TextField("Host", text: $connection.host, prompt: Text("hostname or IP"))
                    TextField("Port", value: $connection.port, format: .number.grouping(.never))
                    TextField("Auto-login user", text: $connection.username, prompt: Text("optional"))
                }
                Section("Terminal") {
                    Picker("Terminal type", selection: $connection.terminalType) {
                        ForEach(Connection.terminalTypes, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Character set", selection: $connection.encoding) {
                        ForEach(TermEncoding.allCases) { Text($0.label).tag($0) }
                    }
                    Stepper("Columns: \(connection.columns)", value: $connection.columns, in: 40...200)
                    Stepper("Rows: \(connection.rows)", value: $connection.rows, in: 10...100)
                    Stepper("Font size: \(Int(connection.fontSize))", value: $connection.fontSize, in: 9...28)
                    Picker("Colors", selection: $connection.theme) {
                        ForEach(TermTheme.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Backspace sends Ctrl-H", isOn: $connection.backspaceSendsCtrlH)
                }
                Section {
                    ForEach($connection.macros) { $m in
                        MacroRow(macro: $m) {
                            connection.macros.removeAll { $0.id == m.id }
                        }
                    }
                    HStack {
                        Button("Add macro") {
                            connection.macros.append(KeyMacro("F1", ""))
                        }
                        Spacer()
                        Button("Reset to KoalaTerm defaults") {
                            connection.macros = KeyMacro.koalaCommon
                        }
                    }
                } header: {
                    Text("Keys & macros")
                } footer: {
                    Text("Sequence syntax: <ESC> <CR> <LF> <TAB> <UP> <DOWN> <LEFT> <RIGHT>, ^C for Ctrl-C, \\x1B for any byte. Leave empty to disable the key. ⌘V always pastes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    connection.name = connection.name.trimmingCharacters(in: .whitespaces)
                    connection.host = connection.host.trimmingCharacters(in: .whitespaces)
                    onSave(connection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
    }
}

struct MacroRow: View {
    @Binding var macro: KeyMacro
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("⌃", isOn: $macro.control).toggleStyle(.button).help("Control")
            Toggle("⌥", isOn: $macro.option).toggleStyle(.button).help("Option")
            Toggle("⇧", isOn: $macro.shift).toggleStyle(.button).help("Shift")
            Picker("", selection: $macro.key) {
                ForEach(KeyMacro.keyNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            TextField("", text: $macro.sequence, prompt: Text("disabled"))
                .font(.system(.body, design: .monospaced))
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}
