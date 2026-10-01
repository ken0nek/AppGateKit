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
}
