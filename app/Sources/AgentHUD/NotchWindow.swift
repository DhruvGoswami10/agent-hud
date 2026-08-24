import AppKit
import SwiftUI

final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        acceptsMouseMovedEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The panel window is a fixed, invisible canvas pinned under the notch; the
/// black shape animates freely inside it with SwiftUI springs. Mouse tracking
/// flips `ignoresMouseEvents` so the transparent canvas never intercepts
/// clicks meant for windows underneath.
@MainActor
final class NotchWindowController {
    struct Metrics: Equatable {
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        let hasNotch: Bool
    }

    static let canvasWidth: CGFloat = 800
    static let canvasHeight: CGFloat = 600

    private let panel = NotchPanel()
    private let state: AppState
    private(set) var metrics: Metrics
    private var mouseTimer: Timer?
    private var hoverGate = HoverGate()
    private var ignoringMouse = true

    init(state: AppState) {
        self.state = state
        self.metrics = Self.computeMetrics(for: Self.targetScreen())
        let hosting = NSHostingView(rootView: NotchRootView(state: state, metrics: metrics))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.ignoresMouseEvents = true
        state.frameUpdater = { _ in }  // sizes are view-driven now
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        fixFrame()
        panel.orderFrontRegardless()
        startMouseTracking()
    }

    private func screensChanged() {
        let fresh = Self.computeMetrics(for: Self.targetScreen())
        // Rebuilding the root view resets its @State, which blanks the panel's
        // content while it's open. Display sleep/wake and most resolution
        // changes leave the notch geometry identical, so don't pay for it.
        if fresh != metrics {
            metrics = fresh
            if let hosting = panel.contentView as? NSHostingView<NotchRootView> {
                hosting.rootView = NotchRootView(state: state, metrics: metrics)
            }
        }
        fixFrame()
    }

    private func fixFrame() {
        guard let screen = Self.targetScreen() else { return }
        let w = Self.canvasWidth
        let h = Self.canvasHeight
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                       display: true)
    }

    private func startMouseTracking() {
        let t = Timer(timeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in NotchControllerRegistry.shared?.pollMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t
        NotchControllerRegistry.shared = self
    }

    /// Entering is deliberately tight — the notch strip sits on the path
    /// between displays. Leaving is deliberately loose: once the panel is
    /// open the pointer wanders to its edges (the header buttons, the
    /// clipboard chips, the burn strip along the bottom), and a 4pt boundary
    /// snapped it shut mid-read.
    static let enterMargin: CGFloat = 4
    static let exitMargin: CGFloat = 32

    private static func hoverRect(_ sz: NSSize, on screen: NSScreen, margin: CGFloat) -> NSRect {
        NSRect(x: screen.frame.midX - sz.width / 2 - margin,
               y: screen.frame.maxY - sz.height - margin,
               width: sz.width + margin * 2,
               height: sz.height + margin * 2)
    }

    fileprivate func pollMouse() {
        guard let screen = Self.targetScreen() else { return }
        let sz = Self.contentSize(for: state.hudState, metrics: metrics,
                                  aggregate: state.aggregate, sideBars: state.sideBars,
                                  peekPreview: state.peekPreviewSize,
                                  idleIndicator: state.alwaysShowIndicator)
        let mouse = NSEvent.mouseLocation
        // Clicks pass through anywhere outside the black shape itself, so the
        // looser hover boundary never steals a click from the window beneath.
        let contentRect = Self.hoverRect(sz, on: screen, margin: Self.enterMargin)
        let overContent = contentRect.contains(mouse)
        if overContent == ignoringMouse {
            ignoringMouse = !overContent
            panel.ignoresMouseEvents = !overContent
        }
        let margin = hoverGate.engaged ? Self.exitMargin : Self.enterMargin
        let inside = Self.hoverRect(sz, on: screen, margin: margin).contains(mouse)
        if let engaged = hoverGate.update(point: mouse, inside: inside) {
            state.hoverChanged(engaged)
        }
    }

    /// Pure geometry — no state touched, so it stays callable (and testable)
    /// from anywhere.
    nonisolated static func contentSize(for target: HUDState, metrics m: Metrics,
                                        aggregate: EventKind, sideBars: Bool,
                                        peekPreview: CGSize? = nil,
                                        idleIndicator: Bool = false) -> NSSize {
        switch target {
        case .collapsed:
            guard m.hasNotch else { return NSSize(width: 210, height: 30) }
            // Idle is exactly the notch — invisible — unless the resting
            // indicator is on, which needs a sliver to draw into.
            if aggregate == .info && !idleIndicator {
                return NSSize(width: m.notchWidth, height: m.notchHeight)
            }
            if aggregate == .info {
                return sideBars
                    ? NSSize(width: m.notchWidth + 10, height: m.notchHeight)
                    : NSSize(width: m.notchWidth, height: m.notchHeight + 3)
            }
            return sideBars
                ? NSSize(width: m.notchWidth + 16, height: m.notchHeight)
                : NSSize(width: m.notchWidth, height: m.notchHeight + 4)
        case .peek:
            var w = max(m.notchWidth + 240, 470)
            var h = m.hasNotch ? m.notchHeight + 80 : 90
            if let p = peekPreview {
                // Island morphs to the copied image's shape.
                w = max(m.notchWidth + 40, min(720, p.width + 250))
                h = max(h, (m.hasNotch ? m.notchHeight : 12) + p.height + 26)
            }
            return NSSize(width: w, height: h)
        case .open:
            return NSSize(width: 760, height: 520)
        }
    }

    /// The notched screen when there is one, else the primary display.
    /// Deliberately not `NSScreen.main`: that follows keyboard focus, so on a
    /// multi-display setup the HUD would hop screens as you click around.
    private static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    private static func computeMetrics(for screen: NSScreen?) -> Metrics {
        guard let screen else { return Metrics(notchWidth: 210, notchHeight: 8, hasNotch: false) }
        let top = screen.safeAreaInsets.top
        if top > 0 {
            var width = screen.frame.width * 0.18
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = screen.frame.width - left.width - right.width
            }
            return Metrics(notchWidth: width, notchHeight: top, hasNotch: true)
        }
        return Metrics(notchWidth: 210, notchHeight: 8, hasNotch: false)
    }
}

@MainActor
private enum NotchControllerRegistry {
    weak static var shared: NotchWindowController?
}
