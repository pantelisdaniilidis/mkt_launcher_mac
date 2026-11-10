import Foundation

/// Converts between the host's single-byte character set and the UTF-8 the terminal view speaks.
struct CharsetCodec {
    let encoding: TermEncoding
    private var decodeTable: [[UInt8]] = []          // host byte -> UTF-8 bytes
    private var encodeTable: [UInt32: UInt8] = [:]   // unicode scalar -> host byte

    init(_ encoding: TermEncoding) {
        self.encoding = encoding
        guard encoding != .utf8 else { return }
        decodeTable.reserveCapacity(256)
        for b in 0..<256 {
            let byte = UInt8(b)
            if byte < 0x80 {
                decodeTable.append([byte])
                continue
            }
            if let s = String(data: Data([byte]), encoding: encoding.stringEncoding),
               s.unicodeScalars.count == 1, let scalar = s.unicodeScalars.first {
                decodeTable.append(Array(s.utf8))
                if encodeTable[scalar.value] == nil { encodeTable[scalar.value] = byte }
            } else {
                decodeTable.append(Array("?".utf8))
            }
        }
    }

    /// Host bytes -> UTF-8 for the terminal.
    func decode(_ bytes: [UInt8]) -> [UInt8] {
        if encoding == .utf8 || !bytes.contains(where: { $0 >= 0x80 }) { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count * 2)
        for b in bytes { out += decodeTable[Int(b)] }
        return out
    }

    /// UTF-8 from the keyboard / clipboard -> host bytes.
    func encode<S: Sequence>(_ utf8: S) -> [UInt8] where S.Element == UInt8 {
        let bytes = Array(utf8)
        if encoding == .utf8 || !bytes.contains(where: { $0 >= 0x80 }) { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if scalar.value < 0x80 {
                out.append(UInt8(scalar.value))
            } else if let b = encodeTable[scalar.value] {
                out.append(b)
            } else {
                // Not representable (e.g. accented letter in a code page without accents):
                // try the letter without its diacritics before giving up.
                let plain = String(scalar).folding(options: [.diacriticInsensitive], locale: nil)
                if let s = plain.unicodeScalars.first, plain.unicodeScalars.count == 1,
                   let b = s.value < 0x80 ? UInt8(s.value) : encodeTable[s.value] {
                    out.append(b)
                } else {
                    out.append(UInt8(ascii: "?"))
                }
            }
        }
        return out
    }
}
