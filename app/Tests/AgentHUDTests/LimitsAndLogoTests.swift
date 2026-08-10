import XCTest
import SwiftUI
@testable import AgentHUD

/// Real account limits: Anthropic's own utilisation numbers, including the
/// per-model weekly cap (Fable) that our token estimates could never see.
final class AccountLimitsTests: XCTestCase {
    private func payload(percent: Double = 100, severity: String = "critical",
                         source: String = "api") -> [String: Any] {
        [
            "source": source,
            "fetched_at": Date().timeIntervalSince1970,
            "account": ["name": "Dhruv", "plan": "Max 20x"],
            "items": [
                ["kind": "session", "label": "5h", "percent": 40.0,
                 "severity": "normal", "resets_at": "2026-08-10T10:20:00.668289+00:00"],
                ["kind": "weekly_scoped", "label": "Fable", "percent": percent,
                 "severity": severity, "resets_at": "2026-08-11T17:59:59.668527+00:00"],
            ],
        ]
    }

    func testParsesItemsAccountAndDates() {
        let l = AccountLimits.from(json: payload())
        XCTAssertEqual(l?.plan, "Max 20x")
        XCTAssertEqual(l?.accountName, "Dhruv")
        XCTAssertEqual(l?.items.count, 2)
        XCTAssertEqual(l?.items.first?.percent, 40)
        XCTAssertNotNil(l?.items.first?.resetsAt, "fractional-second ISO dates must parse")
    }

    func testFableLimitIsSurfacedAsCritical() {
        let fable = AccountLimits.from(json: payload())?.items.last
        XCTAssertEqual(fable?.label, "Fable")
        XCTAssertTrue(fable?.isCritical == true)
    }

    /// A high percentage is critical even if the server didn't say so.
    func testHighPercentIsCriticalRegardless() {
        let item = AccountLimits.from(json: payload(percent: 97, severity: "normal"))?.items.last
        XCTAssertTrue(item?.isCritical == true)
    }

    func testWarningBand() {
        let item = AccountLimits.from(json: payload(percent: 80, severity: "normal"))?.items.last
        XCTAssertTrue(item?.isWarning == true)
        XCTAssertFalse(item?.isCritical == true)
    }

    func testEmptyOrMalformedPayloadIsRejected() {
        XCTAssertNil(AccountLimits.from(json: [:]))
        XCTAssertNil(AccountLimits.from(json: ["items": []]))
        XCTAssertNil(AccountLimits.from(json: ["items": [["nope": 1]]]))
    }

    func testStaleReadingIsFlagged() {
        var p = payload()
        p["fetched_at"] = Date().timeIntervalSince1970 - 7200
        XCTAssertFalse(AccountLimits.from(json: p)?.isLive == true)
        XCTAssertTrue(AccountLimits.from(json: payload())?.isLive == true)
    }
}

@MainActor
final class LimitsSyncTests: XCTestCase {
    private func report(host: String, fetchedAt: Date, percent: Double) -> RegistryReport {
        let limits = AccountLimits.from(json: [
            "source": "api",
            "fetched_at": fetchedAt.timeIntervalSince1970,
            "account": ["name": "Dhruv", "plan": "Max 20x"],
            "items": [["kind": "session", "label": "5h", "percent": percent,
                       "severity": "normal", "resets_at": ""]],
        ])
        return RegistryReport(host: host, entries: [], limits: limits)
    }

    /// Limits are account-wide, so the freshest reading from any machine wins
    /// — an older report from another box must not clobber it.
    func testFreshestReadingWinsAcrossMachines() {
        let s = AppState()
        s.syncRegistry(report(host: "mac", fetchedAt: Date(), percent: 40))
        s.syncRegistry(report(host: "box", fetchedAt: Date(timeIntervalSinceNow: -600), percent: 11))
        XCTAssertEqual(s.accountLimits?.items.first?.percent, 40)

        s.syncRegistry(report(host: "box", fetchedAt: Date(timeIntervalSinceNow: 60), percent: 55))
        XCTAssertEqual(s.accountLimits?.items.first?.percent, 55, "a newer reading must win")
    }

    func testReportWithoutLimitsKeepsPrevious() {
        let s = AppState()
        s.syncRegistry(report(host: "mac", fetchedAt: Date(), percent: 40))
        s.syncRegistry(RegistryReport(host: "box", entries: []))
        XCTAssertEqual(s.accountLimits?.items.first?.percent, 40)
    }
}

final class ProviderTests: XCTestCase {
    func testDetectsFromModelName() {
        XCTAssertEqual(Provider.detect(model: "claude-fable-5"), .claude)
        XCTAssertEqual(Provider.detect(model: "gpt-5-codex"), .openai)
        XCTAssertEqual(Provider.detect(model: "gemini-3-pro"), .gemini)
    }

    func testDetectsBrowserTabsFromProject() {
        XCTAssertEqual(Provider.detect(project: "ChatGPT", host: "web"), .openai)
        XCTAssertEqual(Provider.detect(project: "Claude", host: "web"), .claude)
    }

    func testUnknownIsGeneric() {
        XCTAssertEqual(Provider.detect(model: "llama-9"), .generic)
    }

    /// Registry/hook sessions are Claude Code even before a model is known.
    func testSessionsDefaultToClaudeExceptOnWeb() {
        let local = SessionInfo(id: "1", host: "mac", project: "repo", sessionName: "n",
                                kind: .running, message: "", updated: Date())
        XCTAssertEqual(local.provider, .claude)
        let web = SessionInfo(id: "2", host: "web", project: "Mystery", sessionName: "n",
                              kind: .running, message: "", updated: Date())
        XCTAssertEqual(web.provider, .generic)
    }

    func testEveryBrandHasRenderablePathData() {
        for provider in Provider.allCases where provider != .generic {
            let data = try! XCTUnwrap(provider.pathData)
            XCTAssertFalse(SVGPath.parse(data).isEmpty, "\(provider) path failed to parse")
        }
    }
}

final class SVGPathTests: XCTestCase {
    private func bounds(_ d: String) -> CGRect { SVGPath.parse(d).boundingRect }

    func testAbsoluteAndRelativeLinesAgree() {
        XCTAssertEqual(bounds("M0 0 L10 0 L10 10 Z"), bounds("M0 0 l10 0 l0 10 z"))
    }

    func testHorizontalAndVerticalCommands() {
        let r = bounds("M0 0 H10 V10 Z")
        XCTAssertEqual(r.width, 10, accuracy: 0.001)
        XCTAssertEqual(r.height, 10, accuracy: 0.001)
    }

    func testImplicitRepeatedCommands() {
        // A moveto followed by extra pairs means lineto.
        XCTAssertEqual(bounds("M0 0 5 0 5 5"), bounds("M0 0 L5 0 L5 5"))
    }

    func testCubicAndSmoothCurvesStayInBounds() {
        let r = bounds("M0 0 C0 5 5 5 5 0 S10 -5 10 0")
        XCTAssertEqual(r.minX, 0, accuracy: 0.01)
        XCTAssertEqual(r.maxX, 10, accuracy: 0.01)
    }

    func testArcProducesACircle() {
        // Two half-arcs of radius 5 make a circle of diameter 10.
        let r = bounds("M0 0 a5 5 0 1 0 10 0 a5 5 0 1 0 -10 0 z")
        XCTAssertEqual(r.width, 10, accuracy: 0.1)
        XCTAssertEqual(r.height, 10, accuracy: 0.1)
    }

    func testDegenerateArcFallsBackToLine() {
        XCTAssertEqual(bounds("M0 0 a0 0 0 0 0 10 0").width, 10, accuracy: 0.001)
    }

    func testNumbersWithExponentsAndPackedDecimals() {
        XCTAssertEqual(bounds("M0 0 L1e1 0").width, 10, accuracy: 0.001)
        // ".5.5" is two numbers, not one.
        XCTAssertEqual(bounds("M0 0 L.5.5").width, 0.5, accuracy: 0.001)
    }

    func testGarbageDoesNotCrash() {
        XCTAssertTrue(SVGPath.parse("").isEmpty)
        _ = SVGPath.parse("M0 0 X9 9 L5 5")  // unknown command: stops cleanly
        _ = SVGPath.parse("M")
    }

    func testRealBrandMarksHaveSensibleGeometry() {
        for data in [BrandPaths.claude, BrandPaths.openai, BrandPaths.gemini] {
            let r = bounds(data)
            XCTAssertGreaterThan(r.width, 5, "icon should fill its 24pt viewBox")
            XCTAssertLessThanOrEqual(r.maxX, 24.5)
            XCTAssertLessThanOrEqual(r.maxY, 24.5)
            XCTAssertGreaterThanOrEqual(r.minX, -0.5)
        }
    }
}
