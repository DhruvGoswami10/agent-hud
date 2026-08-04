import AppKit

/// Polls NSPasteboard.changeCount and reports new clipboard contents.
/// Note: on macOS 15+ the first actual content read triggers the system
/// pasteboard-privacy prompt — grant "Always Allow" once.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastCount: Int = NSPasteboard.general.changeCount
    private let onChange: @MainActor (ClipboardItem) -> Void

    init(onChange: @escaping @MainActor (ClipboardItem) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let t = Timer(timeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in ClipboardWatcherRegistry.shared?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        ClipboardWatcherRegistry.shared = self
    }

    fileprivate func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if let item = Self.read(pb) { onChange(item) }
    }

    private static func read(_ pb: NSPasteboard) -> ClipboardItem? {
        if let d = pb.data(forType: .png) ?? pb.data(forType: .tiff), let img = NSImage(data: d) {
            var dims = ""
            if let rep = NSBitmapImageRep(data: d) {
                dims = "\(rep.pixelsWide)×\(rep.pixelsHigh)"
            }
            return ClipboardItem(kind: .image, text: dims, image: img.hudThumbnail(maxDim: 320))
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClipboardItem(kind: .file, text: urls.map(\.lastPathComponent).joined(separator: ", "), image: nil)
        }
        if let s = pb.string(forType: .string) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return ClipboardItem(kind: .text, text: String(trimmed.prefix(800)), image: nil)
        }
        return nil
    }
}

/// Weak global so the timer closure doesn't retain the watcher.
@MainActor
private enum ClipboardWatcherRegistry {
    weak static var shared: ClipboardWatcher?
}
