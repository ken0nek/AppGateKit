import Testing

@testable import AppGateCore

struct AppGateEvaluatorTests {
    @Test("an unparseable running version gates nothing, whatever the sources say")
    func unparseableCurrentFailsOpen() {
        let decision = AppGate.evaluate(
            minSupported: "99.0.0", latest: "99.0.0", current: "not-a-version")
        #expect(decision.state == .open)
        #expect(decision.diagnosis == .currentVersionUnparseable)
    }

    @Test("an empty running version gates nothing — an absent Info.plist reads as this")
    func emptyCurrentFailsOpen() {
        #expect(AppGate.evaluate(minSupported: "99.0.0", latest: nil, current: "").state == .open)
    }

    @Test("below the floor is blocked, and the wall supersedes the notice")
    func floorBlocks() throws {
        let floor = try #require(AppVersion("2.0.0"))
        let decision = AppGate.evaluate(minSupported: "2.0.0", latest: "3.0.0", current: "1.0.0")
        #expect(decision.state == .blocked)
        #expect(decision.diagnosis == .belowMinimumSupported(floor: floor))
    }

    @Test("at the floor is not below it")
    func atTheFloorIsOpen() {
        #expect(AppGate.evaluate(minSupported: "2.0.0", latest: nil, current: "2.0").state == .open)
    }

    @Test("an absent or unparseable floor never walls")
    func floorFailsOpen() {
        #expect(AppGate.evaluate(minSupported: nil, latest: nil, current: "1.0.0").state == .open)
        #expect(AppGate.evaluate(minSupported: "2.x", latest: nil, current: "1.0.0").state == .open)
    }

    @Test("a newer version raises the notice")
    func newerRaisesNotice() throws {
        let latest = try #require(AppVersion("1.5.0"))
        let decision = AppGate.evaluate(minSupported: nil, latest: "1.5.0", current: "1.4.0")
        #expect(decision.state == .notice(latest: latest))
        #expect(decision.diagnosis == .newerVersionAvailable(latest: latest))
    }

    @Test("an unparseable or absent latest never raises a notice")
    func latestFailsOpen() {
        #expect(AppGate.evaluate(minSupported: nil, latest: nil, current: "1.4.0").state == .open)
        #expect(AppGate.evaluate(minSupported: nil, latest: "1.x", current: "1.4.0").state == .open)
    }

    @Test("a dismissal compares parsed versions, so dismissing 1.4 also covers 1.4.0")
    func dismissalComparesParsed() throws {
        let latest = try #require(AppVersion("1.4.0"))
        let decision = AppGate.evaluate(
            minSupported: nil, latest: "1.4.0", current: "1.3.0", dismissedVersion: "1.4"
        )
        #expect(decision.state == .open)
        #expect(decision.diagnosis == .newerVersionDismissed(latest: latest))
    }

    @Test("dismissing an older version does not silence a newer one")
    func staleDismissalDoesNotSilence() {
        let decision = AppGate.evaluate(
            minSupported: nil, latest: "1.5.0", current: "1.3.0", dismissedVersion: "1.4.0"
        )
        #expect(decision.state == .notice(latest: AppVersion("1.5.0")!))
    }

    @Test("an unparseable dismissal does not silence the notice")
    func unparseableDismissalDoesNotSilence() {
        let decision = AppGate.evaluate(
            minSupported: nil, latest: "1.5.0", current: "1.3.0", dismissedVersion: "garbage"
        )
        #expect(decision.state == .notice(latest: AppVersion("1.5.0")!))
    }

    @Test("a dismissal never releases a wall")
    func dismissalNeverReleasesWall() {
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: "2.0.0", current: "1.0.0", dismissedVersion: "2.0.0"
        )
        #expect(decision.state == .blocked)
    }

    @Test("nothing applying is open, and says so")
    func nothingApplies() {
        let decision = AppGate.evaluate(minSupported: "1.0.0", latest: "1.4.0", current: "1.4.0")
        #expect(decision.state == .open)
        #expect(decision.diagnosis == .noGateApplies)
    }
}
