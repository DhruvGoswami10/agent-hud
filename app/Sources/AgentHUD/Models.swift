import AppKit
import SwiftUI
import CoreImage

/// Prefer the session's real name; if it's still Claude Code's auto-generated
/// "<user>-<xx>" fallback, show the project folder instead when that's more
/// meaningful than the user's home directory.
func sessionDisplayName(_ name: String, project: String) -> String {
    if name.isEmpty { return project }
    let isAuto = name.range(of: #"^[A-Za-z0-9-]+-[0-9a-f]{2}$"#, options: .regularExpression) != nil
        && name.lowercased().hasPrefix(NSUserName().replacingOccurrences(of: ".", with: "-").lowercased())
    if isAuto, !project.isEmpty, project != NSUserName() { return project }
    return name
}

enum HostAliases {
    private(set) static var map: [String: String] = [:]

    static func display(_ h: String) -> String { map[h] ?? h }

    /// Merge aliases recorded by agent-hud-bootstrap for newly seen boxes.
    static func reload() {
        let p = ("~/agent-hud/hosts.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: p),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        for (k, v) in j { map[k] = v }
    }
}

enum EventKind: String {
    case running, attention, done, info

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .running: return NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)
        case .attention: return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.2, alpha: 1)
        case .done: return NSColor(calibratedRed: 0.4, green: 0.85, blue: 0.5, alpha: 1)
        case .info: return NSColor.systemGray
        }
    }

    var symbol: String {
        switch self {
        case .running: return "circle.dashed"
        case .attention: return "exclamationmark.bubble.fill"
        case .done: return "checkmark.circle.fill"
        case .info: return "info.circle"
        }
    }

    var verb: String {
        switch self {
        case .running: return "working…"
        case .attention: return "needs you"
        case .done: return "done"
        case .info: return "info"
        }
    }
}

struct AgentEvent: Identifiable {
    let id = UUID()
    let kind: EventKind
    let host: String
    let project: String
    let sessionId: String
    let sessionName: String
    let message: String
    let hook: String
    let image: NSImage?
    let ts: Date

    var label: String {
        let name = sessionDisplayName(sessionName, project: project)
        let h = HostAliases.display(host)
        return name.isEmpty ? h : "\(h) · \(name)"
    }
    var sourceKey: String { "\(host)#\(sessionId.isEmpty ? project : sessionId)" }

    static func from(json: [String: Any]) -> AgentEvent? {
        guard let raw = json["event"] as? String, let kind = EventKind(rawValue: raw) else { return nil }
        var image: NSImage? = nil
        if let b64 = json["image_b64"] as? String,
           let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]),
           let img = NSImage(data: data) {
            image = img.hudThumbnail(maxDim: 220)
        } else if let p = json["image_path"] as? String {
            let path = (p as NSString).expandingTildeInPath
            if let img = NSImage(contentsOfFile: path) { image = img.hudThumbnail(maxDim: 220) }
        }
        return AgentEvent(
            kind: kind,
            host: (json["host"] as? String) ?? "unknown",
            project: (json["project"] as? String) ?? "",
            sessionId: (json["session_id"] as? String) ?? "",
            sessionName: (json["session_name"] as? String) ?? "",
            message: ((json["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            hook: (json["hook"] as? String) ?? "",
            image: image,
            ts: Date()
        )
    }
}

struct SessionInfo: Identifiable {
    let id: String
    var host: String
    var project: String
    var sessionName: String
    var kind: EventKind
    var message: String
    var updated: Date
    var model: String = ""
    var effort: String = ""
    var ctxUsed: Int = 0
    var ctxLimit: Int = 200_000
    var lastIn: Int = 0
    var lastOut: Int = 0

    /// Sessions on [1m] models exceed the standard 200k window; infer it.
    var effectiveCtxLimit: Int { ctxUsed > 220_000 ? 1_000_000 : ctxLimit }

    var ctxFraction: Double? {
        guard ctxUsed > 0 else { return nil }
        return min(1, Double(ctxUsed) / Double(effectiveCtxLimit))
    }

    var label: String {
        let name = sessionDisplayName(sessionName, project: project)
        let h = HostAliases.display(host)
        return name.isEmpty ? h : "\(h) · \(name)"
    }
}

struct ClipboardItem: Identifiable {
    enum Kind { case text, image, file }
    let id = UUID()
    let kind: Kind
    let text: String
    let image: NSImage?
    let ts = Date()
}

enum PeekContent {
    case event(AgentEvent)
    case clipboard(ClipboardItem)
    case music(NowPlaying)
}

enum HUDState {
    case collapsed
    case peek(PeekContent)
    case open

    var isOpen: Bool { if case .open = self { return true } else { return false } }
    var isCollapsed: Bool { if case .collapsed = self { return true } else { return false } }

    /// Stage discriminator (peek content changes keep the same stage).
    var stage: Int {
        switch self {
        case .collapsed: return 0
        case .peek: return 1
        case .open: return 2
        }
    }
}

/// Fit `size` inside `box` preserving aspect ratio, never upscaling —
/// small snips stay small, wide strips go wide, tall crops go tall.
func hudFitSize(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0 else { return CGSize(width: 56, height: 56) }
    let scale = min(box.width / size.width, box.height / size.height, 1)
    return CGSize(width: max(40, size.width * scale), height: max(28, size.height * scale))
}

extension NSImage {
    /// Dominant/average color, for Dynamic-Island-style ambient glows.
    var averageColor: NSColor? {
        guard let tiff = tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ]), let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(out, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                       blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    func hudThumbnail(maxDim: CGFloat) -> NSImage {
        let s = size
        guard s.width > 0, s.height > 0 else { return self }
        let scale = min(1, maxDim / max(s.width, s.height))
        guard scale < 1 else { return self }
        let newSize = NSSize(width: max(1, s.width * scale), height: max(1, s.height * scale))
        let out = NSImage(size: newSize)
        out.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
