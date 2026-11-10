import Foundation
import Network

/// Minimal telnet client (RFC 854) with the options a VT session needs:
/// ECHO, SUPPRESS-GO-AHEAD, BINARY, TERMINAL-TYPE (RFC 1091) and NAWS (RFC 1073).
/// All callbacks and state changes happen on the main thread.
final class TelnetClient {
    enum Event {
        case connected
        case data([UInt8])
        case closed(String?)
    }

    var onEvent: ((Event) -> Void)?
    var terminalType = "VT220"
    private(set) var isConnected = false

    private var conn: NWConnection?
    private let queue = DispatchQueue(label: "gr.kotsovolos.mktlauncher.telnet")
    private var cols = 80
    private var rows = 25
    private var connectTimer: DispatchWorkItem?

    // Telnet protocol constants
    private enum Cmd {
        static let SE: UInt8 = 240, NOP: UInt8 = 241, SB: UInt8 = 250
        static let WILL: UInt8 = 251, WONT: UInt8 = 252, DO: UInt8 = 253, DONT: UInt8 = 254, IAC: UInt8 = 255
    }
    private enum Opt {
        static let BINARY: UInt8 = 0, ECHO: UInt8 = 1, SGA: UInt8 = 3, TTYPE: UInt8 = 24, NAWS: UInt8 = 31
    }
    private let weWill: Set<UInt8> = [Opt.BINARY, Opt.SGA, Opt.TTYPE, Opt.NAWS]
    private let weDo: Set<UInt8> = [Opt.BINARY, Opt.ECHO, Opt.SGA]
    private var localOn = Set<UInt8>()
    private var remoteOn = Set<UInt8>()

    private enum ParseState { case data, iac, option(UInt8), sb, sbIac }
    private var state = ParseState.data
    private var sbBuffer = [UInt8]()
    private var lastWasCR = false

    // MARK: Connection

    func connect(host: String, port: Int, timeout: TimeInterval = 15) {
        close()
        guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            onEvent?(.closed("Invalid port \(port)"))
            return
        }
        resetProtocolState()
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 60
        }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
        conn = c

        c.stateUpdateHandler = { [weak self, weak c] st in
            DispatchQueue.main.async {
                guard let self, let c, c === self.conn else { return }
                switch st {
                case .ready:
                    self.connectTimer?.cancel()
                    self.isConnected = true
                    self.onEvent?(.connected)
                    self.receive(on: c)
                case .waiting(let err):
                    // Unreachable host / refused: report instead of retrying forever.
                    self.fail(Self.describe(err))
                case .failed(let err):
                    self.fail(Self.describe(err))
                case .cancelled:
                    break
                default:
                    break
                }
            }
        }
        c.start(queue: queue)

        let timer = DispatchWorkItem { [weak self, weak c] in
            guard let self, let c, c === self.conn, !self.isConnected else { return }
            self.fail("Connection timed out")
        }
        connectTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timer)
    }

    func close() {
        connectTimer?.cancel()
        connectTimer = nil
        let c = conn
        conn = nil
        isConnected = false
        c?.stateUpdateHandler = nil
        c?.cancel()
    }

    /// "Connection reset by peer" instead of "The operation couldn't be completed. (Network.NWError …)".
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code): return String(cString: strerror(code.rawValue))
        case .dns(let code): return "Host not found (DNS error \(code))"
        default: return error.localizedDescription
        }
    }

    private func fail(_ reason: String?) {
        guard conn != nil else { return }
        close()
        onEvent?(.closed(reason))
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak c] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, let c, c === self.conn else { return }
                if let data, !data.isEmpty {
                    let out = self.parse(data)
                    if !out.isEmpty { self.onEvent?(.data(out)) }
                }
                if let error {
                    self.fail(Self.describe(error))
                } else if isComplete {
                    self.fail(nil)
                } else {
                    self.receive(on: c)
                }
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let c = conn, !bytes.isEmpty else { return }
        c.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    // MARK: Sending user data

    /// Sends keyboard / paste data, applying telnet escaping (IAC doubling and CR NUL).
    func send(_ bytes: [UInt8]) {
        guard isConnected else { return }
        let binary = localOn.contains(Opt.BINARY)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + 4)
        for b in bytes {
            if b == Cmd.IAC {
                out += [Cmd.IAC, Cmd.IAC]
            } else if b == 13 && !binary {
                out += [13, 0]
            } else {
                out.append(b)
            }
        }
        write(out)
    }

    func setWindowSize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        if isConnected && localOn.contains(Opt.NAWS) { sendNAWS() }
    }

    // MARK: Protocol

    private func resetProtocolState() {
        localOn.removeAll()
        remoteOn.removeAll()
        state = .data
        sbBuffer.removeAll()
        lastWasCR = false
    }

    private func parse(_ input: Data) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        for b in input {
            switch state {
            case .data:
                if b == Cmd.IAC {
                    state = .iac
                } else {
                    // NVT: a CR followed by NUL means a bare CR; drop the NUL.
                    if b == 0 && lastWasCR && !remoteOn.contains(Opt.BINARY) {
                        lastWasCR = false
                        continue
                    }
                    lastWasCR = (b == 13)
                    out.append(b)
                }
            case .iac:
                switch b {
                case Cmd.IAC:
                    out.append(Cmd.IAC)
                    state = .data
                case Cmd.WILL, Cmd.WONT, Cmd.DO, Cmd.DONT:
                    state = .option(b)
                case Cmd.SB:
                    sbBuffer.removeAll()
                    state = .sb
                default:
                    state = .data // NOP, GA, AYT, etc.
                }
            case .option(let verb):
                negotiate(verb, b)
                state = .data
            case .sb:
                if b == Cmd.IAC { state = .sbIac } else if sbBuffer.count < 1024 { sbBuffer.append(b) }
            case .sbIac:
                if b == Cmd.SE {
                    subnegotiation(sbBuffer)
                    state = .data
                } else if b == Cmd.IAC {
                    sbBuffer.append(Cmd.IAC)
                    state = .sb
                } else {
                    state = .data
                }
            }
        }
        return out
    }

    private func negotiate(_ verb: UInt8, _ opt: UInt8) {
        switch verb {
        case Cmd.DO:
            if weWill.contains(opt) {
                if !localOn.contains(opt) {
                    localOn.insert(opt)
                    write([Cmd.IAC, Cmd.WILL, opt])
                }
                if opt == Opt.NAWS { sendNAWS() }
            } else {
                write([Cmd.IAC, Cmd.WONT, opt])
            }
        case Cmd.DONT:
            if localOn.contains(opt) {
                localOn.remove(opt)
                write([Cmd.IAC, Cmd.WONT, opt])
            }
        case Cmd.WILL:
            if weDo.contains(opt) {
                if !remoteOn.contains(opt) {
                    remoteOn.insert(opt)
                    write([Cmd.IAC, Cmd.DO, opt])
                }
            } else {
                write([Cmd.IAC, Cmd.DONT, opt])
            }
        case Cmd.WONT:
            if remoteOn.contains(opt) {
                remoteOn.remove(opt)
                write([Cmd.IAC, Cmd.DONT, opt])
            }
        default:
            break
        }
    }

    private func subnegotiation(_ sb: [UInt8]) {
        // TERMINAL-TYPE SEND -> IS <type>
        if sb.count >= 2 && sb[0] == Opt.TTYPE && sb[1] == 1 {
            var msg: [UInt8] = [Cmd.IAC, Cmd.SB, Opt.TTYPE, 0]
            msg += Array(terminalType.uppercased().utf8)
            msg += [Cmd.IAC, Cmd.SE]
            write(msg)
        }
    }

    private func sendNAWS() {
        var msg: [UInt8] = [Cmd.IAC, Cmd.SB, Opt.NAWS]
        for v in [UInt16(clamping: cols), UInt16(clamping: rows)] {
            for byte in [UInt8(v >> 8), UInt8(v & 0xff)] {
                msg.append(byte)
                if byte == Cmd.IAC { msg.append(Cmd.IAC) }
            }
        }
        msg += [Cmd.IAC, Cmd.SE]
        write(msg)
    }
}
