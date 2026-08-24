import SwiftUI

/// A small SVG path-data parser, so brand marks render as crisp vectors at
/// any size without shipping image assets. Supports the full command set
/// used by real icon sets: M/L/H/V/C/S/Q/T/A/Z, absolute and relative,
/// implicit command repetition, and elliptical arcs (converted to béziers).
enum SVGPath {
    private static var cache: [String: Path] = [:]

    /// Parsed paths are cached — icon data is static and reparsing on every
    /// SwiftUI redraw would be wasteful.
    static func path(_ data: String) -> Path {
        if let hit = cache[data] { return hit }
        let parsed = parse(data)
        cache[data] = parsed
        return parsed
    }

    static func parse(_ data: String) -> Path {
        var path = Path()
        let chars = Array(data)
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        func skipSeparators() {
            while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n"
                || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
        }

        func number() -> CGFloat? {
            skipSeparators()
            var s = ""
            var sawDigit = false
            var sawDot = false
            while i < chars.count {
                let c = chars[i]
                if c == "+" || c == "-" {
                    // A sign only starts a number or follows an exponent.
                    if s.isEmpty || s.last == "e" || s.last == "E" { s.append(c); i += 1; continue }
                    break
                }
                if c == "." {
                    if sawDot { break }  // ".5.5" is two numbers
                    sawDot = true; s.append(c); i += 1; continue
                }
                if c.isNumber { sawDigit = true; s.append(c); i += 1; continue }
                if (c == "e" || c == "E"), sawDigit { s.append(c); i += 1; continue }
                break
            }
            guard sawDigit, let v = Double(s) else { return nil }
            return CGFloat(v)
        }

        func flag() -> Bool? {
            skipSeparators()
            guard i < chars.count else { return nil }
            let c = chars[i]
            guard c == "0" || c == "1" else { return number().map { $0 != 0 } }
            i += 1
            return c == "1"
        }

        func point(_ x: CGFloat, _ y: CGFloat, relative: Bool) -> CGPoint {
            relative ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        while true {
            skipSeparators()
            guard i < chars.count else { break }
            let iterationStart = i
            if chars[i].isLetter {
                cmd = chars[i]
                i += 1
            }
            let relative = cmd.isLowercase
            // Not Character(cmd.uppercased()): letters whose uppercase form
            // expands ("ß" → "SS", "ﬁ" → "FI") are more than one grapheme and
            // trapped instead of falling through to the bail-out below.
            let upper = cmd.uppercased()
            guard upper.count == 1, let op = upper.first else { return path }
            var isCubic = false
            var isQuad = false

            switch op {
            case "M":
                guard let x = number(), let y = number() else { return path }
                cur = point(x, y, relative: relative)
                path.move(to: cur)
                subpathStart = cur
                cmd = relative ? "l" : "L"  // extra pairs after moveto are linetos
            case "L":
                guard let x = number(), let y = number() else { return path }
                cur = point(x, y, relative: relative)
                path.addLine(to: cur)
            case "H":
                guard let x = number() else { return path }
                cur = CGPoint(x: relative ? cur.x + x : x, y: cur.y)
                path.addLine(to: cur)
            case "V":
                guard let y = number() else { return path }
                cur = CGPoint(x: cur.x, y: relative ? cur.y + y : y)
                path.addLine(to: cur)
            case "C":
                guard let x1 = number(), let y1 = number(), let x2 = number(),
                      let y2 = number(), let x = number(), let y = number() else { return path }
                let c1 = point(x1, y1, relative: relative)
                let c2 = point(x2, y2, relative: relative)
                cur = point(x, y, relative: relative)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCubicControl = c2
                isCubic = true
            case "S":
                guard let x2 = number(), let y2 = number(),
                      let x = number(), let y = number() else { return path }
                let c1 = lastCubicControl.map {
                    CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y)
                } ?? cur
                let c2 = point(x2, y2, relative: relative)
                cur = point(x, y, relative: relative)
                path.addCurve(to: cur, control1: c1, control2: c2)
                lastCubicControl = c2
                isCubic = true
            case "Q":
                guard let x1 = number(), let y1 = number(),
                      let x = number(), let y = number() else { return path }
                let c = point(x1, y1, relative: relative)
                cur = point(x, y, relative: relative)
                path.addQuadCurve(to: cur, control: c)
                lastQuadControl = c
                isQuad = true
            case "T":
                guard let x = number(), let y = number() else { return path }
                let c = lastQuadControl.map {
                    CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y)
                } ?? cur
                cur = point(x, y, relative: relative)
                path.addQuadCurve(to: cur, control: c)
                lastQuadControl = c
                isQuad = true
            case "A":
                guard let rx = number(), let ry = number(), let rot = number(),
                      let large = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return path }
                let end = point(x, y, relative: relative)
                addArc(&path, from: cur, to: end, rx: rx, ry: ry,
                       rotationDegrees: rot, largeArc: large, sweep: sweep)
                cur = end
            case "Z":
                path.closeSubpath()
                cur = subpathStart
            default:
                return path  // unknown command: stop rather than misdraw
            }
            if !isCubic { lastCubicControl = nil }
            if !isQuad { lastQuadControl = nil }
            // Z consumes no characters of its own, so any non-letter byte
            // after one ("M0 0 L10 10 Z5") left the index parked and closed
            // the subpath forever — a hard hang on the render thread.
            if i == iterationStart { return path }
        }
        return path
    }

    /// Endpoint-parameterised elliptical arc → cubic béziers (SVG spec F.6).
    private static func addArc(_ path: inout Path, from p1: CGPoint, to p2: CGPoint,
                               rx rxIn: CGFloat, ry ryIn: CGFloat,
                               rotationDegrees: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p1 != p2 else {
            path.addLine(to: p2)
            return
        }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p1.x - p2.x) / 2, dy = (p1.y - p2.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s
            ry *= s
        }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = denominator == 0 ? 0 : sign * sqrt(numerator / denominator)
        let cxp = coef * rx * y1p / ry
        let cyp = -coef * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (p1.x + p2.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p1.y + p2.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let len = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            guard len > 0 else { return 0 }
            var a = acos(max(-1, min(1, (ux * vx + uy * vy) / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        var theta = angle(1, 0, ux, uy)
        var delta = angle(ux, uy, vx, vy)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var from = p1
        for _ in 0..<segments {
            let next = theta + step
            let cosT = cos(theta), sinT = sin(theta)
            let cosN = cos(next), sinN = sin(next)
            let endX = cx + rx * cosPhi * cosN - ry * sinPhi * sinN
            let endY = cy + rx * sinPhi * cosN + ry * cosPhi * sinN
            let d1x = -rx * cosPhi * sinT - ry * sinPhi * cosT
            let d1y = -rx * sinPhi * sinT + ry * cosPhi * cosT
            let d2x = -rx * cosPhi * sinN - ry * sinPhi * cosN
            let d2y = -rx * sinPhi * sinN + ry * cosPhi * cosN
            let end = CGPoint(x: endX, y: endY)
            path.addCurve(to: end,
                          control1: CGPoint(x: from.x + k * d1x, y: from.y + k * d1y),
                          control2: CGPoint(x: end.x - k * d2x, y: end.y - k * d2y))
            from = end
            theta = next
        }
    }
}

/// Which assistant a session belongs to, for the badge on session cards.
enum Provider: String, CaseIterable {
    case claude, openai, gemini, generic

    var pathData: String? {
        switch self {
        case .claude: return BrandPaths.claude
        case .openai: return BrandPaths.openai
        case .gemini: return BrandPaths.gemini
        case .generic: return nil
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.30)   // Claude clay
        case .openai: return Color(white: 0.93)
        case .gemini: return Color(red: 0.40, green: 0.62, blue: 0.98)
        case .generic: return Color(white: 0.75)
        }
    }

    /// Best-effort identification from whatever the session reported.
    static func detect(model: String = "", project: String = "",
                       sessionName: String = "", host: String = "") -> Provider {
        let hay = "\(model) \(project) \(sessionName) \(host)".lowercased()
        if hay.contains("gemini") || hay.contains("bard") { return .gemini }
        if hay.contains("chatgpt") || hay.contains("openai") || hay.contains("codex")
            || hay.contains("gpt") { return .openai }
        if hay.contains("claude") || hay.contains("fable") || hay.contains("opus")
            || hay.contains("sonnet") || hay.contains("haiku") { return .claude }
        return .generic
    }
}

/// Renders SVG path data scaled to fit, preserving the 24×24 viewBox aspect.
struct BrandMark: View {
    let provider: Provider
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let data = provider.pathData {
                SVGShape(data: data)
                    .fill(provider.tint)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(provider.tint)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(provider.rawValue)
    }
}

struct SVGShape: Shape {
    let data: String
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let dx = rect.minX + (rect.width - viewBox * scale) / 2
        let dy = rect.minY + (rect.height - viewBox * scale) / 2
        return SVGPath.path(data).applying(
            CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale))
    }
}

/// Which player the sound comes from, as a small brand glyph — used on the
/// now-playing bar and the music peek.
struct MusicSourceMark: View {
    let app: String
    var size: CGFloat = 9

    var body: some View {
        switch app {
        case "YouTube":
            SVGShape(data: BrandPaths.youtube)
                .fill(Color(red: 1.0, green: 0.23, blue: 0.19))
                .frame(width: size + 1, height: size)
        case "Spotify":
            SVGShape(data: BrandPaths.spotify)
                .fill(Color(red: 0.12, green: 0.84, blue: 0.38))
                .frame(width: size, height: size)
        case "Music":
            Image(systemName: "music.note")
                .font(.system(size: size - 1, weight: .semibold))
                .foregroundStyle(Color(red: 0.98, green: 0.34, blue: 0.42))
        default:
            Image(systemName: "waveform")
                .font(.system(size: size - 1))
                .foregroundStyle(.white.opacity(0.5))
        }
    }
}
