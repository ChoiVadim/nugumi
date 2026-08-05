import Foundation

/// One row a surface script printed: a flat, string-only dictionary, plus the
/// identity the host needs on its own to survive a refresh.
///
/// Flat because a binding in a layout tree renders exactly one string per
/// cell — there is no shape in the render path for a nested value to land in.
struct SurfaceRow: Equatable, Codable {
    /// The script's own `id`, or the row's position when it printed none, or
    /// duplicated one that another row already claimed. Either way this is
    /// what a refresh diffs on, so rows do not reshuffle under the pointer
    /// just because a script re-sorted its output.
    let id: String
    let values: [String: String]

    subscript(key: String) -> String? {
        values[key]
    }
}

enum SurfaceRowsError: LocalizedError {
    case notJSON
    case missingRows
    /// The document parsed as JSON and had a `"rows"` array — this element
    /// of it just wasn't an object. Distinct from `.notJSON` on purpose:
    /// `{"rows":["a.txt"]}` is valid JSON that a model could plausibly write
    /// by mistake, and "your output wasn't JSON" would send it hunting for a
    /// syntax error that was never there.
    case rowNotAnObject(index: Int, kind: String)
    /// Each of these used to be one shared `.tooMany` case naming neither the
    /// key nor the count, which covered three unrelated causes with a single
    /// remedy ("print fewer rows") that misdirected the other two. Splitting
    /// them is the same fix `valueNotAString` already made for a value's
    /// shape: name what actually overflowed.
    case tooMuchOutput(bytes: Int)
    case tooManyRows(count: Int)
    case tooManyKeys(rowIndex: Int, count: Int)
    case valueTooLong(key: String, bytes: Int)
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
        case .rowNotAnObject(let index, let kind):
            return "Row \(index) of \"rows\" has to be an object like {\"id\":\"…\"}; it's \(kind)."
        case .tooMuchOutput(let bytes):
            return "The script printed \(bytes) bytes of output; a surface can hold at most "
                + "\(SurfaceRows.maximumStdoutBytes). Print less of it."
        case .tooManyRows(let count):
            return "The script printed \(count) rows; a surface can hold at most "
                + "\(SurfaceRows.maximumRows). Print fewer rows."
        case .tooManyKeys(let rowIndex, let count):
            return "Row \(rowIndex) has \(count) fields; one row can hold at most "
                + "\(SurfaceRows.maximumKeysPerRow). Print fewer fields on that row."
        case .valueTooLong(let key, let bytes):
            return "\"\(key)\" is \(bytes) bytes; a row's value can hold at most "
                + "\(SurfaceRows.maximumValueBytes). Shorten it."
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
        // Not `.notJSON`: this fires on a script that printed perfectly
        // valid, huge JSON — a real folder with thousands of entries,
        // discovered the first time a surface got validated against a
        // script that actually runs against one. `.notJSON` sends a
        // repairing model hunting for a syntax bug that was never there.
        guard stdout.utf8.count <= maximumStdoutBytes else {
            throw SurfaceRowsError.tooMuchOutput(bytes: stdout.utf8.count)
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
        guard rawRows.count <= maximumRows else { throw SurfaceRowsError.tooManyRows(count: rawRows.count) }

        let decoded: [(id: String?, values: [String: String])] = try rawRows.enumerated().map { index, raw in
            guard let object = raw as? [String: Any] else {
                throw SurfaceRowsError.rowNotAnObject(index: index, kind: kind(of: raw))
            }
            guard object.count <= maximumKeysPerRow else {
                throw SurfaceRowsError.tooManyKeys(rowIndex: index, count: object.count)
            }

            var values: [String: String] = [:]
            for (key, value) in object {
                values[key] = try string(from: value, key: key)
            }
            return (id: values["id"], values: values)
        }

        // `SurfaceRow.id`'s only consumer is `ForEach(rows, id: \.id)`, which
        // requires every id in the batch to be unique — a script printing
        // the same id twice, or `""` for every row, or `id` on some rows and
        // not others, all reach here. Falling back to position for the
        // *whole* batch rather than patching just the collisions keeps `id`
        // meaning one thing: either every row's own identity, or none of
        // them — never a mix where one row's synthetic "0" happens to equal
        // another row's real one.
        let explicitIDs = decoded.compactMap(\.id)
        let idsAreUsable = explicitIDs.count == decoded.count && Set(explicitIDs).count == explicitIDs.count
        return decoded.enumerated().map { index, entry in
            SurfaceRow(id: idsAreUsable ? entry.id! : String(index), values: entry.values)
        }
    }

    /// What `raw` actually is, for a diagnostic that names the shape instead
    /// of just saying "wrong" — `valueNotAString` set this pattern for one
    /// of a row's values; this is the same reasoning applied to a row itself.
    private static func kind(of raw: Any) -> String {
        switch raw {
        case is NSNull: return "null"
        case is String: return "a string"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return "a boolean"
        case is NSNumber: return "a number"
        case is [Any]: return "an array"
        default: return "not an object"
        }
    }

    /// Numbers and booleans are one honest string; arrays and objects are
    /// not, because there's no shape in a layout binding for them to land
    /// in — silently picking a representation would be worse than saying
    /// no. `NSNull` means the script had nothing to say for this key, which
    /// reads the same as not printing the key at all.
    ///
    /// `JSONSerialization` hands a JSON boolean back as an `NSNumber` —
    /// there is no separate `Bool` case to switch on — so a boolean has to
    /// be told apart from a real number by its `CFTypeID` before the
    /// generic `NSNumber` branch runs, or `true` renders as `"1"`. The host
    /// must show exactly what the script printed; `"1"` is a different
    /// value from `true`, not a rendering of it.
    private static func string(from value: Any, key: String) throws -> String? {
        let described: String
        switch value {
        case is NSNull:
            return nil
        case let string as String:
            described = string
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            described = number.boolValue ? "true" : "false"
        case let number as NSNumber:
            described = String(describing: number)
        case is [Any]:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "an array")
        case is [String: Any]:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "an object")
        default:
            throw SurfaceRowsError.valueNotAString(key: key, kind: "not plain text")
        }
        guard described.utf8.count <= maximumValueBytes else {
            throw SurfaceRowsError.valueTooLong(key: key, bytes: described.utf8.count)
        }
        return described
    }
}
