import Foundation

/// One row a surface script printed: a flat, string-only dictionary, plus the
/// identity the host needs on its own to survive a refresh.
///
/// Flat because a binding in a layout tree renders exactly one string per
/// cell — there is no shape in the render path for a nested value to land in.
struct SurfaceRow: Equatable {
    /// The script's own `id`, or the row's position when it printed none.
    /// Either way this is what a refresh diffs on, so rows do not reshuffle
    /// under the pointer just because a script re-sorted its output.
    let id: String
    let values: [String: String]

    subscript(key: String) -> String? {
        values[key]
    }
}

enum SurfaceRowsError: LocalizedError {
    case notJSON
    case missingRows
    case tooMany
    case valueTooLong
    /// Distinct from `valueTooLong` on purpose: this is fed back to the
    /// model as a repair diagnostic (`CandidateValidation`), and "too long"
    /// sends it shortening a string that was never long — the rerun fails
    /// the same way and burns repair budget on a defect that isn't there.
    /// Naming the key and the shape it actually is repairs itself.
    case valueNotAString(key: String, kind: String)

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "The script's output wasn't JSON."
        case .missingRows:
            return "The script's JSON had no \"rows\" array."
        case .tooMany:
            return "The script printed more rows, or more fields on one row, than a surface can hold."
        case .valueTooLong:
            return "A row's value was too long to show."
        case .valueNotAString(let key, let kind):
            return "A row's values have to be strings, numbers or booleans; \"\(key)\" is \(kind)."
        }
    }
}

/// Turns a surface script's stdout into the rows a layout tree renders.
///
/// A gizmo's script runs on the user's own machine and is free to print
/// whatever it wants before its data — a progress line, a stray warning —
/// so this scans backward and keeps whichever line is the last one that
/// actually parses as JSON, rather than demanding the first line be it.
/// Failing a script that already works just sends the model off to repair
/// something that was never broken.
enum SurfaceRows {
    static let maximumRows = 500
    static let maximumKeysPerRow = 32
    static let maximumValueBytes = 1024
    static let maximumStdoutBytes = 262_144

    static func decode(stdout: String) throws -> [SurfaceRow] {
        // A runaway print loop is a script bug, not a payload to search line
        // by line — reject it up front rather than scanning megabytes of it.
        guard stdout.utf8.count <= maximumStdoutBytes else {
            throw SurfaceRowsError.notJSON
        }

        var sawJSON = false
        for line in stdout.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            // This line parses on its own — that's enough to stop calling
            // the rest of stdout "not JSON", even if this particular line
            // turns out not to be the rows payload.
            sawJSON = true
            guard let object = parsed as? [String: Any], let rawRows = object["rows"] as? [Any] else {
                continue
            }
            return try rows(from: rawRows)
        }
        throw sawJSON ? SurfaceRowsError.missingRows : SurfaceRowsError.notJSON
    }

    private static func rows(from rawRows: [Any]) throws -> [SurfaceRow] {
        guard rawRows.count <= maximumRows else { throw SurfaceRowsError.tooMany }

        return try rawRows.enumerated().map { index, raw in
            guard let object = raw as? [String: Any] else { throw SurfaceRowsError.notJSON }
            guard object.count <= maximumKeysPerRow else { throw SurfaceRowsError.tooMany }

            var values: [String: String] = [:]
            for (key, value) in object {
                values[key] = try string(from: value, key: key)
            }

            // A fallback id is synthetic — it never gets written into
            // `values`, or a script that genuinely omitted `id` would end up
            // with a rendered `id` field it never asked for.
            let id = values["id"] ?? String(index)
            return SurfaceRow(id: id, values: values)
        }
    }

    /// Numbers and booleans are one honest string; arrays and objects are
    /// not, because there's no shape in a layout binding for them to land
    /// in — silently picking a representation would be worse than saying
    /// no. `NSNull` means the script had nothing to say for this key, which
    /// reads the same as not printing the key at all.
    private static func string(from value: Any, key: String) throws -> String? {
        let described: String
        switch value {
        case is NSNull:
            return nil
        case let string as String:
            described = string
        case let number as NSNumber:
            described = String(describing: number)
        case is [Any]:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "an array")
        case is [String: Any]:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "an object")
        default:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "not plain text")
        }
        guard described.utf8.count <= maximumValueBytes else { throw SurfaceRowsError.valueTooLong }
        return described
    }
}
