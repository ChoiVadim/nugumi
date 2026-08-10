import Foundation
import GizmateToolAgentCore

/// Whether a layout's bindings can actually be drawn from the rows a surface
/// script's stdout produced — checked against a real validation run, never a
/// fixture the model wrote to suit itself. `CandidateValidation` and this
/// file's tests both call it.
///
/// No `FileManager` access: a validation run and the moment the user docks
/// the gizmo are two different points in time, and a check that depended on
/// what's on disk right now would answer a question that changes underneath
/// it. "Looks like an absolute path" is the shape a `file:` binding
/// promises; whether that path is still reachable is the renderer's
/// problem, not the build's.
///
/// The SF Symbol check below is a different kind of environment dependency,
/// and an acceptable one: which glyphs exist is a property of the OS this
/// process is running on, not of a particular run, so it can't go stale
/// between one validation and the next the way a file on disk does. The one
/// case it can't rule out — a later OS upgrade retiring a glyph a past
/// validation approved — isn't silent either: `ToolIcons.resolved` falls
/// back to a known-good symbol at render time rather than draw a blank.
enum SurfaceLayoutCheck {
    static func diagnostic(for layout: ToolAgentLayoutV1, against rows: [SurfaceRow]) -> String? {
        // Checked before the rows guard below, on purpose: a `symbol:` name
        // is either a real SF Symbol on this OS or it isn't, regardless of
        // what today's run printed, so a script with nothing to show yet
        // must not let a bad icon name through uncaught.
        for name in layout.iconSymbols.sorted() where !ToolIcons.resolves(name) {
            return "The layout uses icon \"symbol:\(name)\", but \"\(name)\" isn't a real SF Symbol name."
        }

        // A script that legitimately has nothing to show today — an empty
        // Downloads folder — cannot be checked against its own keys. Failing
        // the build over that would refuse a gizmo that works the moment it
        // has something to show; this grades as a smoke run instead, the
        // same as any other output whose fixture carries no expected value.
        guard !rows.isEmpty else { return nil }

        let available = Set(rows.flatMap(\.values.keys)).sorted()
        for key in layout.referencedKeys.sorted() where !available.contains(key) {
            return "The layout binds \"\(key)\", but no row the script printed has that key. "
                + "The rows have: \(available.isEmpty ? "nothing" : available.joined(separator: ", "))."
        }

        // A `drag: file`, `icon: file`, or `tap` key promises its value is a
        // path the Finder can act on. Checked by shape — does it start with
        // "/" — not by asking the filesystem, for the reason in this type's
        // doc comment.
        for key in layout.fileKeys.sorted() {
            if let notAPath = rows.compactMap({ $0[key] }).first(where: { !$0.hasPrefix("/") }) {
                return "The layout uses \"\(key)\" as a file, but a row's value for it — "
                    + "\"\(notAPath)\" — isn't an absolute path."
            }
        }

        // A `symbol:$key` promises the script prints a real glyph name. The
        // renderer falls back to `sparkles` when it doesn't, which is a silent
        // failure of exactly the kind this whole gizmo was built to avoid: the
        // surface still draws, every card just wears the same wrong icon. The
        // literal `symbol:` check at the top of this function catches the same
        // mistake in the layout; this catches it in the data.
        for key in layout.symbolKeys.sorted() {
            if let notAGlyph = rows.compactMap({ $0[key] }).first(where: { !ToolIcons.resolves($0) }) {
                return "The layout uses \"\(key)\" as an icon, but a row's value for it — "
                    + "\"\(notAGlyph)\" — isn't a real SF Symbol name."
            }
        }

        return nil
    }
}
