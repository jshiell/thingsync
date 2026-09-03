/// Renders `repr()`-equivalent output for a string: single quotes unless
/// the string contains a `'` but no `"`, in which case double quotes are
/// used instead -- matching Python's `!r` formatting exactly. A naive
/// `"'\(title)'"` interpolation diverges from Python's output on the
/// first apostrophe it meets (a real project title, e.g. "Dave's
/// kitchen"), which the M8.14 dry-run diff would then catch as a false
/// defect.
public func pythonRepr(_ value: String) -> String {
    let hasSingleQuote = value.contains("'")
    let hasDoubleQuote = value.contains("\"")
    let quote: Character = (hasSingleQuote && !hasDoubleQuote) ? "\"" : "'"

    var result = String(quote)
    for character in value {
        if character == "\\" {
            result += "\\\\"
        } else if character == quote {
            result += "\\\(quote)"
        } else if character == "\n" {
            result += "\\n"
        } else if character == "\r" {
            result += "\\r"
        } else if character == "\t" {
            result += "\\t"
        } else {
            result.append(character)
        }
    }
    result.append(quote)
    return result
}

private func rightJustified(_ value: String, width: Int) -> String {
    let padding = max(0, width - value.count)
    return String(repeating: " ", count: padding) + value
}

public func describe(_ action: SyncAction) -> String {
    let title = action.payload?.title ?? action.uuid
    return "\(rightJustified(action.kind.rawValue, width: 8))  \(title)"
}

public func describeListAction(_ action: ListAction) -> String {
    if let reason = action.reason {
        return "  refused  \(pythonRepr(action.title)): \(reason)"
    }
    return "\(rightJustified(action.kind.rawValue, width: 12))  \(pythonRepr(action.title))"
}
