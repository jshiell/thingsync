import CryptoKit
import Foundation

/// Everything thingsync writes onto a reminder.
public struct ReminderPayload: Hashable, Sendable {
    public let title: String
    public let notes: String
    public let url: String
    public let dueDate: YearMonthDay?
    public let startDate: YearMonthDay?

    public init(
        title: String,
        notes: String,
        url: String,
        dueDate: YearMonthDay? = nil,
        startDate: YearMonthDay? = nil
    ) {
        self.title = title
        self.notes = notes
        self.url = url
        self.dueDate = dueDate
        self.startDate = startDate
    }

    /// A stable digest of the payload, used to detect that nothing changed.
    ///
    /// Must byte-for-byte match Python's `json.dumps({...}, sort_keys=True,
    /// ensure_ascii=False)` material — a mismatch would make the first Swift
    /// run rewrite every mirrored reminder. `JSONEncoder` does not reproduce
    /// this: it uses compact separators and does not sort with Python's
    /// escaping rules, so the serialization below is hand-rolled instead.
    public func contentHash() -> String {
        let material = ReminderPayload.canonicalJSON([
            ("due_date", dueDate?.iso),
            ("notes", notes),
            ("start_date", startDate?.iso),
            ("title", title),
            ("url", url),
        ])
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalJSON(_ fields: [(String, String?)]) -> String {
        let parts = fields.map { key, value in
            "\"\(key)\": \(value.map(jsonString) ?? "null")"
        }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    /// Matches Python's `json.dumps` string escaping with `ensure_ascii=False`:
    /// only `\ " \b \f \n \r \t` and other C0 control characters are escaped;
    /// everything else, including non-ASCII text, passes through literally.
    private static func jsonString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}
