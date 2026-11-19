import AppGateCore
import Testing

@testable import AppGateUI

struct AppGateSurfaceTests {
    @Test("an open gate asks for nothing")
    func openShowsNothing() {
        #expect(AppGateSurface.resolve(.open, debugWallReleased: false) == .none)
    }

    @Test("a blocked gate asks for the wall")
    func blockedShowsWall() {
        #expect(AppGateSurface.resolve(.blocked, debugWallReleased: false) == .wall)
    }

    @Test("a notice carries the version it announces, dotted")
    func noticeCarriesVersion() throws {
        let state = GateState.notice(latest: try #require(AppVersion("1.5.0")))
        #expect(
            AppGateSurface.resolve(state, debugWallReleased: false) == .notice(version: "1.5.0"))
    }

    /// The DEBUG release takes the wall down. Without this rule the release
    /// would clear the store's overrides and leave the cover up whenever the
    /// live config still sets a wall, and the developer could not get back to
    /// the app.
    @Test("a released wall stays down even while the state still blocks")
    func releasedWallStaysDown() {
        #expect(AppGateSurface.resolve(.blocked, debugWallReleased: true) == .none)
    }

    /// The release applies to the wall only. A notice is dismissed and never
    /// released. If the flag suppressed both, closing a forced wall would also
    /// hide the notice for the rest of the session.
    @Test("releasing the wall does not touch the notice")
    func releaseDoesNotSuppressNotice() throws {
        let state = GateState.notice(latest: try #require(AppVersion("2.0")))
        #expect(AppGateSurface.resolve(state, debugWallReleased: true) == .notice(version: "2.0"))
    }

    private static let wall = GateDecision(
        state: .blocked, diagnosis: .belowMinimumSupported(floor: AppVersion("2.0.0")!))
    private static let notice = GateDecision(
        state: .notice(latest: AppVersion("1.5.0")!),
        diagnosis: .newerVersionAvailable(latest: AppVersion("1.5.0")!))

    @Test("unfinished onboarding hides the notice and not the wall")
    func onboardingReachesTheNoticeRule() {
        #expect(
            AppGateSurface.resolve(
                Self.notice, capturingScreenshots: false, hasCompletedOnboarding: false,
                promptShownThisSession: false, debugWallReleased: false) == .none)
        #expect(
            AppGateSurface.resolve(
                Self.wall, capturingScreenshots: false, hasCompletedOnboarding: false,
                promptShownThisSession: false, debugWallReleased: false) == .wall)
    }

    @Test("a prompt shown this session hides the notice and not the wall")
    func promptReachesTheNoticeRule() {
        #expect(
            AppGateSurface.resolve(
                Self.notice, capturingScreenshots: false, hasCompletedOnboarding: true,
                promptShownThisSession: true, debugWallReleased: false) == .none)
        #expect(
            AppGateSurface.resolve(
                Self.wall, capturingScreenshots: false, hasCompletedOnboarding: true,
                promptShownThisSession: true, debugWallReleased: false) == .wall)
    }

    @Test("a screenshot run hides the wall too")
    func captureReachesBothRules() {
        #expect(
            AppGateSurface.resolve(
                Self.wall, capturingScreenshots: true, hasCompletedOnboarding: true,
                promptShownThisSession: false, debugWallReleased: false) == .none)
    }

    @Test("with nothing suppressing it, the notice shows")
    func unsuppressedNoticeShows() {
        #expect(
            AppGateSurface.resolve(
                Self.notice, capturingScreenshots: false, hasCompletedOnboarding: true,
                promptShownThisSession: false, debugWallReleased: false)
                == .notice(version: "1.5.0"))
    }
}
