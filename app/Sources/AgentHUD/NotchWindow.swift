import AppKit
import Combine
import SwiftUI

/// The HUD floats above another app without activating it. Its first click
/// must reach the content instead of being consumed to focus the panel.
final class HUDHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Where the HUD lives. The notch when a screen has one; otherwise a side
/// edge — the notch turned on its side — because on a wide external display
/// the top-centre is exactly where every browser keeps its tabs.
enum Placement: Equatable {
    case notch
    /// The old fallback: a pill hung from the top-centre. Kept as an opt-out.
    case topPill
    case edge(EdgeSide)
}

/// The side notch's resting and active sizes, in points. At rest it is a
/// sliver in the scrollbar gutter; it only grows when there is news.
enum EdgeGeometry {
    static let hidden = NSSize(width: 3, height: 96)      // idle, indicator off: hoverable, invisible
    static let resting = NSSize(width: 5, height: 80)     // idle, indicator on
    static let active = NSSize(width: 14, height: 104)    // running / done / music / copied
    static let attention = NSSize(width: 18, height: 112) // needs you
    /// The bar grip: the side-bars identity moved to the edge.
    static let barHidden = NSSize(width: 3, height: 60)
    static let barResting = NSSize(width: 4, height: 64)
    static let barActive = NSSize(width: 7, height: 76)
    static let barAttention = NSSize(width: 8, height: 84)
    /// Vertical anchor, as a fraction of the screen height from the top:
    /// well clear of tab strips and toolbars, above the dock.
    static let anchorFraction: CGFloat = 0.42
}

/// The panel window is a fixed, invisible canvas pinned under the notch (or
/// against a side edge); the black shape animates freely inside it with
/// SwiftUI springs. Mouse tracking flips `ignoresMouseEvents` so the
/// transparent canvas never intercepts clicks meant for windows underneath.
@MainActor
final class NotchWindowController {
    struct Metrics: Equatable {
        let notchWidth: CGFloat
        let notchHeight: CGFloat
        let hasNotch: Bool
        /// Set when the HUD hangs from a side edge instead of the top.
        var edge: EdgeSide? = nil
    }

    nonisolated static let canvasWidth: CGFloat = 800
    nonisolated static let canvasHeight: CGFloat = 600

    private let panel = NotchPanel()
    private let state: AppState
    private(set) var metrics: Metrics
    private var mouseTimer: Timer?
    private var hoverGate = HoverGate()
    private var ignoringMouse = true
    private var subscriptions: [AnyCancellable] = []

    init(state: AppState) {
        self.state = state
        self.metrics = Self.computeMetrics(for: Self.targetScreen(), placement: Self.placement(for: state))
        let hosting = HUDHostingView(rootView: NotchRootView(state: state, metrics: metrics))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.ignoresMouseEvents = true
        state.frameUpdater = { _ in }  // sizes are view-driven now
        state.dismissHandler = { [weak self] in self?.suppressHoverUntilExit() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
        // Edge preferences change the placement the same way plugging a
        // display in does.
        state.$edgeSide.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.screensChanged() }.store(in: &subscriptions)
        state.$edgePlacement.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.screensChanged() }.store(in: &subscriptions)
        // Moving the notch only moves the canvas; the view inside is untouched.
        state.$edgeAnchor.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in self?.fixFrame() }.store(in: &subscriptions)
        state.$hudState.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] target in
            // A dismissed peripheral must give keyboard focus back too.
            if target.isCollapsed, self?.panel.isKeyWindow == true { self?.panel.resignKey() }
        }.store(in: &subscriptions)
        fixFrame()
        panel.orderFrontRegardless()
        startMouseTracking()
    }

    private func screensChanged() {
        let fresh = Self.computeMetrics(for: Self.targetScreen(), placement: Self.placement(for: state))
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
        let canvas = NSSize(width: Self.canvasWidth, height: Self.canvasHeight)
        panel.setFrame(Self.anchorRect(for: canvas, screen: metrics.edge == nil ? screen.frame : screen.visibleFrame, metrics: metrics,
                                       anchor: state.edgeAnchor), display: true)
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
    nonisolated static let enterMargin: CGFloat = 4
    nonisolated static let exitMargin: CGFloat = 32

    /// Where a shape of this size sits on screen: hung from the top-centre,
    /// or pressed against a side edge at the anchor height. The same rule
    /// places the canvas, so the SwiftUI alignment inside it lines up.
    nonisolated static func anchorRect(for size: NSSize, screen frame: NSRect, metrics m: Metrics,
                                       anchor: Double = Double(EdgeGeometry.anchorFraction),
                                       dropY: CGFloat = Playground.dropY,
                                       offsetX: CGFloat = Playground.offsetX) -> NSRect {
        if let edge = m.edge {
            // Use one clamped canvas centre for every stage, including hover
            // hit testing. Opening cannot move the content away from the grip.
            let half = min(canvasHeight, frame.height) / 2
            let requested = frame.maxY - frame.height * CGFloat(anchor) - dropY
            let centerY = min(frame.maxY - half, max(frame.minY + half, requested))
            let x = edge == .right ? frame.maxX - size.width : frame.minX
            return NSRect(x: x, y: centerY - size.height / 2, width: size.width, height: size.height)
        }
        return NSRect(x: frame.midX - size.width / 2 + offsetX,
                      y: frame.maxY - size.height - dropY,
                      width: size.width, height: size.height)
    }

    private func hoverRect(_ sz: NSSize, on screen: NSScreen, margin: CGFloat) -> NSRect {
        Self.anchorRect(for: sz, screen: metrics.edge == nil ? screen.frame : screen.visibleFrame, metrics: metrics, anchor: state.edgeAnchor)
            .insetBy(dx: -margin, dy: -margin)
    }

    private func suppressHoverUntilExit() {
        guard let screen = Self.targetScreen() else { hoverGate.suppressUntilExit(); return }
        let size = Self.contentSize(for: state.hudState, metrics: metrics,
                                   aggregate: state.aggregate, sideBars: state.sideBars,
                                   peekPreview: state.peekPreviewSize,
                                   idleIndicator: state.alwaysShowIndicator,
                                   edgeBar: state.edgeGripBar)
        // Freeze the click location too: a deliberate move back to the notch
        // re-arms hover even while still inside the old popup bounds.
        hoverGate.suppressUntilExit(within: hoverRect(size, on: screen, margin: Self.exitMargin),
                                   at: NSEvent.mouseLocation)
    }

    fileprivate func pollMouse() {
        // Mid-drag the notch is wherever the pointer is; leave the mouse
        // routing as it was (accepting) and don't let the gate open anything.
        if state.edgeDragging { return }
        guard let screen = Self.targetScreen() else { return }
        let sz = Self.contentSize(for: state.hudState, metrics: metrics,
                                  aggregate: state.aggregate, sideBars: state.sideBars,
                                  peekPreview: state.peekPreviewSize,
                                  idleIndicator: state.alwaysShowIndicator,
                                  edgeBar: state.edgeGripBar)
        let mouse = NSEvent.mouseLocation
        // Clicks pass through anywhere outside the black shape itself, so the
        // looser hover boundary never steals a click from the window beneath.
        let contentRect = hoverRect(sz, on: screen, margin: Self.enterMargin)
        let overContent = contentRect.contains(mouse)
        if overContent == ignoringMouse {
            ignoringMouse = !overContent
            panel.ignoresMouseEvents = !overContent
        }
        let margin = hoverGate.engaged ? Self.exitMargin : Self.enterMargin
        let inside = hoverRect(sz, on: screen, margin: margin).contains(mouse)
        if let engaged = hoverGate.update(point: mouse, inside: inside) {
            state.hoverChanged(engaged)
        }
    }

    /// Pure geometry — no state touched, so it stays callable (and testable)
    /// from anywhere.
    nonisolated static func contentSize(for target: HUDState, metrics m: Metrics,
                                        aggregate: EventKind, sideBars: Bool,
                                        peekPreview: CGSize? = nil,
                                        idleIndicator: Bool = false,
                                        edgeBar: Bool = false) -> NSSize {
        if m.edge != nil, case .collapsed = target {
            // Nothing to hide inside on a plain edge, so rest is a sliver that
            // stays hoverable, and news is what earns the full silhouette.
            let idle = aggregate == .info
            if edgeBar {
                if idle { return idleIndicator ? EdgeGeometry.barResting : EdgeGeometry.barHidden }
                return aggregate == .attention ? EdgeGeometry.barAttention : EdgeGeometry.barActive
            }
            if idle { return idleIndicator ? EdgeGeometry.resting : EdgeGeometry.hidden }
            return aggregate == .attention ? EdgeGeometry.attention : EdgeGeometry.active
        }
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
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
            ?? NSScreen.screens.first
            ?? NSScreen.main
    }

    private static func placement(for state: AppState) -> Placement {
        resolvePlacement(hasNotchedScreen: NSScreen.screens.contains { $0.safeAreaInsets.top > 0 },
                         edgePlacement: state.edgePlacement, side: state.edgeSide,
                         forced: Playground.forceEdge)
    }

    /// Edge mode is what "no notch anywhere" means: the lid is closed or the
    /// only displays are external. Open the lid and the notch wins again.
    nonisolated static func resolvePlacement(hasNotchedScreen: Bool, edgePlacement: Bool,
                                             side: EdgeSide, forced: String?) -> Placement {
        if let forced {
            return .edge(EdgeSide(rawValue: forced) ?? side)
        }
        if hasNotchedScreen { return .notch }
        return edgePlacement ? .edge(side) : .topPill
    }

    nonisolated static func computeMetrics(for screen: NSScreen?, placement: Placement) -> Metrics {
        if case .edge(let side) = placement {
            return Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: side)
        }
        guard let screen, placement == .notch else {
            return Metrics(notchWidth: 210, notchHeight: 8, hasNotch: false)
        }
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
