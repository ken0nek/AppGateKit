import Testing

@testable import AppGateCore

/// The lookup can release a gate and can never raise one. Both directions have
/// named tests. If a failed lookup released a wall, an outage at Apple would
/// disable every wall.
struct OSInstallCheckTests {
    @Test("a lookup failure must not release a wall")
    func unknownMinimumOSKeepsWall() {
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: nil, current: "1.0.0",
            osVersion: "18.0", minimumOSVersion: nil
        )
        #expect(decision.state == .blocked)
        #expect(decision.diagnosis == .belowMinimumSupported(floor: AppVersion("2.0.0")!))
    }

    @Test("an unparseable minimumOsVersion must not release a wall")
    func unparseableMinimumOSKeepsWall() {
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: nil, current: "1.0.0",
            osVersion: "18.0", minimumOSVersion: "26.0 or later"
        )
        #expect(decision.state == .blocked)
    }

    @Test("an unknown running OS must not release a wall")
    func unparseableRunningOSKeepsWall() {
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: nil, current: "1.0.0",
            osVersion: nil, minimumOSVersion: "26.0"
        )
        #expect(decision.state == .blocked)
    }

    @Test("an OS that can install keeps the wall standing")
    func osCanInstallKeepsWall() {
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: nil, current: "1.0.0",
            osVersion: "26.0", minimumOSVersion: "26.0"
        )
        #expect(decision.state == .blocked)
    }

    @Test("an OS that cannot install releases the wall, and says why")
    func osTooOldReleasesWall() throws {
        let minimumOS = try #require(AppVersion("26.0"))
        let decision = AppGate.evaluate(
            minSupported: "2.0.0", latest: nil, current: "1.0.0",
            osVersion: "18.0", minimumOSVersion: "26.0"
        )
        #expect(decision.state == .open)
        #expect(
            decision.diagnosis
                == .releasedOSCannotInstall(released: .blocked, minimumOSVersion: minimumOS)
        )
    }

    @Test("an OS that cannot install releases the notice too")
    func osTooOldReleasesNotice() throws {
        let latest = try #require(AppVersion("2.0.0"))
        let minimumOS = try #require(AppVersion("26.0"))
        let decision = AppGate.evaluate(
            minSupported: nil, latest: "2.0.0", current: "1.0.0",
            osVersion: "18.0", minimumOSVersion: "26.0"
        )
        #expect(decision.state == .open)
        #expect(
            decision.diagnosis
                == .releasedOSCannotInstall(
                    released: .notice(latest: latest), minimumOSVersion: minimumOS
                )
        )
    }

    @Test("an already-open state is left alone by the OS check")
    func openIsUntouched() {
        let decision = AppGate.evaluate(
            minSupported: nil, latest: nil, current: "1.0.0",
            osVersion: "18.0", minimumOSVersion: "26.0"
        )
        #expect(decision.state == .open)
        #expect(decision.diagnosis == .noGateApplies)
    }
}
