import Foundation

/// Minimal JSON value that keeps object key order and number lexemes, so rewriting
/// ChatGPT's keybindings.json keeps entries and unknown fields as they were.
/// Serialization matches JavaScript's `JSON.stringify(value, null, 2)`, which is how
/// ChatGPT writes the file itself.
enum OrderedJSON: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        var key: String
        var value: OrderedJSON
    }

    case null
    case bool(Bool)
    case number(String) // raw lexeme
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    subscript(key: String) -> OrderedJSON? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    struct ParseError: Error, CustomStringConvertible {
        let message: String
        let offset: Int
        var description: String { "\(message) at byte \(offset)" }
    }

    // MARK: Parsing (strict RFC 8259, like JSON.parse; a BOM is rejected as JSON.parse does)

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("Unexpected trailing data") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        func error(_ message: String) -> ParseError { ParseError(message: message, offset: index) }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let lit = Array(literal.utf8)
            guard index + lit.count <= bytes.count, Array(bytes[index..<index + lit.count]) == lit else {
                throw error("Invalid literal")
            }
            index += lit.count
        }

        mutating func parseValue(depth: Int) throws -> OrderedJSON {
            guard depth < 512 else { throw error("Nesting too deep") }
            guard index < bytes.count else { throw error("Unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "n"): try expect("null"); return .null
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "["):
                index += 1
                var items: [OrderedJSON] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try parseValue(depth: depth + 1))
                    skipWhitespace()
                    guard index < bytes.count else { throw error("Unterminated array") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    throw error("Expected , or ]")
                }
            case UInt8(ascii: "{"):
                index += 1
                var members: [Member] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected key") }
                    let key = try parseString()
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected :") }
                    index += 1
                    skipWhitespace()
                    let value = try parseValue(depth: depth + 1)
                    // JSON.parse keeps the last duplicate key, in the first key's position.
                    if let i = members.firstIndex(where: { $0.key == key }) {
                        members[i].value = value
                    } else {
                        members.append(Member(key: key, value: value))
                    }
                    skipWhitespace()
                    guard index < bytes.count else { throw error("Unterminated object") }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                    throw error("Expected , or }")
                }
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try parseNumber())
            default:
                throw error("Unexpected character")
            }
        }

        mutating func parseNumber() throws -> String {
            let start = index
            func digits() -> Int {
                let s = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - s
            }
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { throw error("Invalid number") }
            if bytes[index] == UInt8(ascii: "0") { index += 1 } else if digits() == 0 { throw error("Invalid number") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("Invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("Invalid number") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func parseHex4() throws -> UInt32 {
            guard index + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("Invalid \\u escape")
            }
            index += 4
            return v
        }

        mutating func parseString() throws -> String {
            index += 1 // opening quote
            var out = [UInt8]()
            while true {
                guard index < bytes.count else { throw error("Unterminated string") }
                let b = bytes[index]
                index += 1
                switch b {
                case UInt8(ascii: "\""):
                    return String(decoding: out, as: UTF8.self) // input came from a valid Swift String
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { throw error("Unterminated escape") }
                    let e = bytes[index]
                    index += 1
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22)
                    case UInt8(ascii: "\\"): out.append(0x5C)
                    case UInt8(ascii: "/"): out.append(0x2F)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try parseHex4()
                        if (0xD800...0xDBFF).contains(scalar) {
                            guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
                                  bytes[index + 1] == UInt8(ascii: "u") else {
                                throw error("Lone surrogate (unsupported)")
                            }
                            index += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("Lone surrogate (unsupported)") }
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            throw error("Lone surrogate (unsupported)")
                        }
                        guard let u = Unicode.Scalar(scalar) else { throw error("Invalid scalar") }
                        out.append(contentsOf: Array(String(Character(u)).utf8))
                    default:
                        throw error("Invalid escape")
                    }
                default:
                    guard b >= 0x20 else { throw error("Control character in string") }
                    out.append(b)
                }
            }
        }
    }

    // MARK: Serialization (JSON.stringify(value, null, 2))

    func stringified(indent: String = "") -> String {
        let inner = indent + "  "
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return Self.quote(s)
        case .array(let items):
            if items.isEmpty { return "[]" }
            return "[\n" + items.map { inner + $0.stringified(indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case .object(let members):
            if members.isEmpty { return "{}" }
            return "{\n" + members.map { inner + Self.quote($0.key) + ": " + $0.value.stringified(indent: inner) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        }
    }

    /// Single-line form (used for log/backup storage).
    var compact: String {
        switch self {
        case .array(let items): return "[" + items.map(\.compact).joined(separator: ",") + "]"
        case .object(let members): return "{" + members.map { Self.quote($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
        default: return stringified()
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}
