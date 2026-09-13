import XCTest
import SwiftUI
@testable import AgentHUD

/// Edge mode: with no notch anywhere (lid closed, external-only) the HUD
/// moves to a side edge — the notch turned on its side — because on a wide
/// display the top-centre is where every browser keeps its tabs.
final class PlacementTests: XCTestCase {
    func testNoNotchAnywhereMeansEdge() {
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: false, edgePlacement: true,
                                                              side: .right, forced: nil), .edge(.right))
    }

    func testTheNotchWinsWhenAScreenHasOne() {
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: true, edgePlacement: true,
                                                              side: .right, forced: nil), .notch)
    }

    func testTheOldTopPillIsAnOptOut() {
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: false, edgePlacement: false,
                                                              side: .right, forced: nil), .topPill)
    }

    func testPreferredSideIsHonoured() {
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: false, edgePlacement: true,
                                                              side: .left, forced: nil), .edge(.left))
    }

    /// AGENT_HUD_EDGE lets the playground try edge mode on the MacBook's own
    /// notched screen; a bare "1" keeps the preferred side.
    func testForcedEdgeOverridesTheNotch() {
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: true, edgePlacement: true,
                                                              side: .right, forced: "left"), .edge(.left))
        XCTAssertEqual(NotchWindowController.resolvePlacement(hasNotchedScreen: true, edgePlacement: false,
                                                              side: .right, forced: "1"), .edge(.right))
    }

    func testEdgeMetricsCarryNoNotch() {
        let m = NotchWindowController.computeMetrics(for: nil, placement: .edge(.left))
        XCTAssertEqual(m.edge, .left)
        XCTAssertFalse(m.hasNotch)
        XCTAssertEqual(m.notchHeight, 0, "nothing to pad content away from on a plain edge")
    }
}

final class EdgeContentSizeTests: XCTestCase {
    private let edge = NotchWindowController.Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .right)

    private func collapsed(_ agg: EventKind, indicator: Bool = false, bar: Bool = false) -> NSSize {
        NotchWindowController.contentSize(for: .collapsed, metrics: edge, aggregate: agg,
                                          sideBars: true, idleIndicator: indicator, edgeBar: bar)
    }

    /// At rest the notch is a sliver; only news earns the full silhouette.
    func testRestIsASliverAndNewsGrowsIt() {
        let hidden = collapsed(.info)
        let resting = collapsed(.info, indicator: true)
        let running = collapsed(.running)
        let review = collapsed(.attention)
        XCTAssertLessThan(hidden.width, resting.width)
        XCTAssertLessThan(resting.width, running.width)
        XCTAssertLessThan(running.width, review.width, "a review is the one state that gets the full depth")
        XCTAssertLessThanOrEqual(review.width, 18)
    }

    /// Even invisible, idle keeps a hover target — the edge is how you open it.
    func testHiddenIdleStillHasAHoverTarget() {
        let hidden = collapsed(.info)
        XCTAssertGreaterThan(hidden.width, 0)
        XCTAssertGreaterThan(hidden.height, 60)
    }

    func testBarGripIsSlimmerThanTheNotch() {
        XCTAssertLessThan(collapsed(.running, bar: true).width, collapsed(.running).width)
        XCTAssertLessThan(collapsed(.attention, bar: true).width, collapsed(.attention).width)
    }

    /// Peeks and the panel are the same objects as on the notch, attached to
    /// the edge instead — nothing lost on a wide screen.
    func testPeekAndPanelKeepTheirSizes() {
        let peek = NotchWindowController.contentSize(for: .peek(.clipboard(ClipboardItem(kind: .text, text: "x", image: nil, signature: "s"))),
                                                     metrics: edge, aggregate: .info, sideBars: true)
        XCTAssertEqual(peek.width, 470)
        XCTAssertEqual(peek.height, 90)
        let open = NotchWindowController.contentSize(for: .open, metrics: edge, aggregate: .info, sideBars: true)
        XCTAssertEqual(open, NSSize(width: 760, height: 520))
    }

    func testEverythingFitsTheCanvas() {
        for agg in [EventKind.info, .running, .attention, .done] {
            let s = collapsed(agg, indicator: true)
            XCTAssertLessThanOrEqual(s.width, NotchWindowController.canvasWidth)
            XCTAssertLessThanOrEqual(s.height, NotchWindowController.canvasHeight)
        }
    }
}

/// Where things land on screen. The same rule places the canvas and the
/// hover target, so they can't disagree.
final class AnchorRectTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 3440, height: 1440)

    func testRightEdgeIsFlushAndMidHeight() {
        let m = NotchWindowController.Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .right)
        let r = NotchWindowController.anchorRect(for: NSSize(width: 18, height: 112), screen: screen,
                                                 metrics: m, dropY: 0, offsetX: 0)
        XCTAssertEqual(r.maxX, 3440, "flush against the right edge")
        // 42% down from the top, in AppKit's bottom-up coordinates.
        XCTAssertEqual(r.midY, 1440 - 1440 * 0.42, accuracy: 0.5)
    }

    func testLeftEdgeMirrors() {
        let m = NotchWindowController.Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .left)
        let r = NotchWindowController.anchorRect(for: NSSize(width: 18, height: 112), screen: screen,
                                                 metrics: m, dropY: 0, offsetX: 0)
        XCTAssertEqual(r.minX, 0)
    }

    /// The panel never reaches the tab strip: on a 1440-tall screen the
    /// 520 pt panel's top stays hundreds of points below the menu bar.
    func testOpenPanelStaysClearOfTheTop() {
        let m = NotchWindowController.Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .right)
        let r = NotchWindowController.anchorRect(for: NSSize(width: 760, height: 520), screen: screen,
                                                 metrics: m, dropY: 0, offsetX: 0)
        XCTAssertLessThan(r.maxY, 1440 - 68 - 200, "tab strip is the top 68 pt; keep well away")
    }

    /// Drag it up or down and it goes exactly there — the same rule moves
    /// the canvas and the hover target, so it stays under the pointer.
    func testAnchorFollowsThePreference() {
        let m = NotchWindowController.Metrics(notchWidth: 0, notchHeight: 0, hasNotch: false, edge: .right)
        let high = NotchWindowController.anchorRect(for: NSSize(width: 18, height: 112), screen: screen,
                                                    metrics: m, anchor: 0.25, dropY: 0, offsetX: 0)
        let low = NotchWindowController.anchorRect(for: NSSize(width: 18, height: 112), screen: screen,
                                                   metrics: m, anchor: 0.75, dropY: 0, offsetX: 0)
        XCTAssertEqual(high.midY, 1440 * 0.75, accuracy: 0.5)
        XCTAssertEqual(low.midY, 1440 * 0.25, accuracy: 0.5)
        XCTAssertGreaterThan(high.midY, low.midY, "smaller fraction = higher on screen")
    }

    func testNotchPlacementIsUnchanged() {
        let m = NotchWindowController.Metrics(notchWidth: 200, notchHeight: 32, hasNotch: true)
        let r = NotchWindowController.anchorRect(for: NSSize(width: 200, height: 32), screen: screen,
                                                 metrics: m, dropY: 0, offsetX: 0)
        XCTAssertEqual(r.midX, 1720)
        XCTAssertEqual(r.maxY, 1440, "hung from the top")
    }
}

final class EdgeShapeTests: XCTestCase {
    func testSilhouetteStaysInsideItsRect() {
        let rect = CGRect(x: 10, y: 20, width: 18, height: 112)
        let box = EdgeShape(side: .right, chamfer: 13, radius: 5).path(in: rect).boundingRect
        XCTAssertGreaterThanOrEqual(box.minX, rect.minX - 0.01)
        XCTAssertLessThanOrEqual(box.maxX, rect.maxX + 0.01)
        XCTAssertGreaterThanOrEqual(box.minY, rect.minY - 0.01)
        XCTAssertLessThanOrEqual(box.maxY, rect.maxY + 0.01)
    }

    /// The outline used for strokes leaves the screen-edge side undrawn: it
    /// starts and ends on that edge and never draws along it.
    func testOutlineStartsAndEndsOnTheScreenEdge() {
        let rect = CGRect(x: 0, y: 0, width: 18, height: 112)
        let right = EdgeOutline(side: .right, chamfer: 13, radius: 5).path(in: rect)
        XCTAssertEqual(right.currentPoint?.x ?? -1, 18, accuracy: 0.01)
        let left = EdgeOutline(side: .left, chamfer: 13, radius: 5).path(in: rect)
        XCTAssertEqual(left.currentPoint?.x ?? -1, 0, accuracy: 0.01, "mirrored for the left edge")
    }

    /// The card variant (no chamfer) is square on the edge, rounded inside —
    /// the peek and panel silhouette.
    func testCardHasNoChamfer() {
        let rect = CGRect(x: 0, y: 0, width: 470, height: 90)
        let p = EdgeShape(side: .right, chamfer: 0, radius: 22).path(in: rect)
        XCTAssertTrue(p.contains(CGPoint(x: 469, y: 1)), "top corner on the edge is square")
        XCTAssertFalse(p.contains(CGPoint(x: 1, y: 1)), "inner corner is rounded away")
    }

    /// Degenerate sizes — a 3 pt hidden sliver — must not produce a broken path.
    func testTinySliverIsStillAPath() {
        let p = EdgeShape(side: .right, chamfer: 2.16, radius: 4).path(in: CGRect(x: 0, y: 0, width: 3, height: 96))
        XCTAssertFalse(p.isEmpty)
        XCTAssertLessThanOrEqual(p.boundingRect.width, 3.01)
    }
}

@MainActor
final class EdgePreferenceTests: XCTestCase {
    func testDefaultsAreRightEdgeNotchGripEdgeOn() {
        let d = UserDefaults.standard
        for k in ["edgeSide", "edgeGripBar", "edgePlacement"] { d.removeObject(forKey: k) }
        let s = AppState()
        XCTAssertEqual(s.edgeSide, .right)
        XCTAssertFalse(s.edgeGripBar)
        XCTAssertTrue(s.edgePlacement)
    }

    /// The anchor is clamped so the open panel always fits below the menu
    /// bar and above the bottom, wherever the drag ends.
    func testAnchorIsClampedAndPersisted() {
        let s = AppState()
        s.edgeAnchor = 0.02
        XCTAssertEqual(s.edgeAnchor, AppState.edgeAnchorRange.lowerBound)
        s.edgeAnchor = 0.99
        XCTAssertEqual(s.edgeAnchor, AppState.edgeAnchorRange.upperBound)
        s.edgeAnchor = 0.6
        XCTAssertEqual(UserDefaults.standard.double(forKey: "edgeAnchor"), 0.6, accuracy: 0.0001)
        s.edgeAnchor = Double(EdgeGeometry.anchorFraction)
    }

    func testPreferencesPersist() {
        let s = AppState()
        s.edgeSide = .left
        s.edgeGripBar = true
        XCTAssertEqual(UserDefaults.standard.string(forKey: "edgeSide"), "left")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "edgeGripBar"))
        s.edgeSide = .right
        s.edgeGripBar = false
    }
}
