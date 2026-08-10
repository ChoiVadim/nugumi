import SwiftUI

/// How full something is, read off one of a row's values.
///
/// Two accepted spellings and no third. A script's author is a model, and the
/// question "does 48.8 mean a fraction or a percent" has no answer a host can
/// guess right every time — so both forms are stated outright and everything
/// else is refused at build time, by `SurfaceLayoutCheck`, using this same
/// parser. One parser rather than two is the point: a value the check accepts
/// and the renderer cannot draw would be the worst of both.
enum SurfaceMeter {
    /// `0…1` as a bare number, or `0…100` written with a `%`. Out-of-range
    /// values are refused rather than clamped: a script printing 4880 meant
    /// something, and a bar pinned at full would hide that it meant it wrongly.
    static func fraction(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            guard let percent = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)),
                  (0...100).contains(percent) else { return nil }
            return percent / 100
        }
        guard let fraction = Double(trimmed), (0...1).contains(fraction) else { return nil }
        return fraction
    }
}

/// A series of numbers read off one of a row's values.
///
/// Comma-separated text, because `SurfaceRow` is flat by construction — its
/// values are strings, and `SurfaceRows` refuses a JSON array outright since
/// there is no shape in a binding for one to land in. So a series makes the
/// same trade `file:$path` already makes: the string promises a shape, and the
/// host checks the promise against a real run rather than trusting it.
enum SurfaceSeries {
    /// Fewer than two points is not a graph, and a hundred and twenty is more
    /// than a strip on a screen edge can resolve anyway.
    static let minimumCount = 2
    static let maximumCount = 120

    static func values(from value: String) -> [Double]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard (minimumCount...maximumCount).contains(parts.count) else { return nil }
        var numbers: [Double] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard let number = Double(part.trimmingCharacters(in: .whitespaces)),
                  number.isFinite else { return nil }
            numbers.append(number)
        }
        return numbers
    }
}

/// How full something is, as a shape rather than a shade.
///
/// The track is drawn even at zero, so an empty bar still says "this is a
/// measurement that happens to read zero" instead of looking like a row that
/// failed to load.
struct SurfaceMeterBar: View {
    let fraction: Double

    private static let height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(FlowTheme.subtleFill)
                Capsule()
                    .fill(FlowTheme.ink.opacity(0.55))
                    .frame(width: geometry.size.width * fraction.clamped(to: 0...1))
            }
        }
        .frame(height: Self.height)
    }
}

/// A series as a filled line, at the size a screen-edge strip can spare.
///
/// Normalised to its own minimum and maximum rather than to zero: a CPU that
/// idles between 18% and 22% is a flat line against a 0–100 axis, and the
/// whole reason to draw a graph beside a number is to see the shape the number
/// alone doesn't show. A flat series gets a flat line through the middle,
/// which is honest — there is no shape to show.
struct SurfaceSparkline: View {
    let values: [Double]

    private static let height: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let points = points(in: geometry.size)
            ZStack {
                filled(points, height: geometry.size.height)
                    .fill(FlowTheme.ink.opacity(0.16))
                line(points)
                    .stroke(FlowTheme.ink.opacity(0.65), style: .init(lineWidth: 1.5, lineJoin: .round))
            }
        }
        .frame(height: Self.height)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let lowest = values.min() ?? 0
        let highest = values.max() ?? 0
        let span = highest - lowest
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            // A zero span means every point is the same; halfway up is the
            // only honest place to put a line with no shape to it.
            let unit = span == 0 ? 0.5 : (value - lowest) / span
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - unit))
        }
    }

    private func line(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    private func filled(_ points: [CGPoint], height: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: height))
            path.addLine(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.closeSubpath()
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
