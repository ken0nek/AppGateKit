#if DEBUG
    import Foundation
    import Testing

    import AppGateCore
    @testable import AppGateClient

    @MainActor
    final class AppGateStoreDebugTests {
        private let fixture: StoreFixture
        private let clock = TestClock()

        init() throws {
            fixture = try StoreFixture()
        }

        private func store(current: String = "1.0.0") -> AppGateStore {
            AppGateStore(
                configURL: URL(string: "https://example.invalid/app-config.json")!,
                appStoreID: "123456789",
                currentVersion: current,
                osVersion: "26.0",
                defaults: fixture.defaults,
                keyPrefix: StoreFixture.keyPrefix,
                fetch: { _ in nil },
                now: clock.provider
            )
        }

        private func store(fetch: @escaping AppGateFetching) -> AppGateStore {
            AppGateStore(
                configURL: URL(string: "https://example.invalid/app-config.json")!,
                appStoreID: "123456789",
                currentVersion: "1.0.0",
                osVersion: "26.0",
                defaults: fixture.defaults,
                keyPrefix: StoreFixture.keyPrefix,
                fetch: fetch,
                now: clock.provider
            )
        }

        @Test("a forced state applies at once, without a relaunch")
        func forcedStateAppliesImmediately() {
            let subject = store()
            #expect(subject.state == .open)
            subject.setDebugForcedState(.blocked)
            #expect(subject.state == .blocked)
        }

        @Test("the forced state is a stored mirror, so a relaunch comes back where it was left")
        func forcedStateSurvivesRelaunch() {
            store().setDebugForcedState(.blocked)
            let relaunched = store()
            #expect(relaunched.debugForcedState == .blocked)
            #expect(relaunched.state == .blocked)
        }

        @Test("a forced notice announces a plausible version even with no lookup")
        func forcedNoticeSynthesizesAVersion() {
            let subject = store(current: "1.4.0")
            subject.setDebugForcedState(.notice)
            #expect(subject.state == .notice(latest: AppVersion("1.4.1")!))
        }

        @Test("a forced notice prefers the real looked-up version when there is a newer one")
        func forcedNoticePrefersTheRealVersion() {
            fixture.write(lookup: #"{"results":[{"version":"9.0.0"}]}"#, at: clock.now)
            let subject = store(current: "1.4.0")
            subject.setDebugForcedState(.notice)
            #expect(subject.state == .notice(latest: AppVersion("9.0.0")!))
        }

        @Test("clearing the forced state hands the gate back to the two sources")
        func clearingForcedStateRestoresSources() {
            fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
            let subject = store()
            subject.setDebugForcedState(.open)
            #expect(subject.state == .open)
            subject.setDebugForcedState(nil)
            #expect(subject.state == .blocked)
        }

        @Test("pointing at another host discards the cached config, in both directions")
        func hostSwitchDiscardsTheCache() {
            fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
            let subject = store()
            #expect(subject.state == .blocked)

            let dev = URL(string: "https://dev.example.invalid/app-config.json")!
            subject.setDebugConfigURL(dev)
            #expect(subject.effectiveConfigURL == dev)
            #expect(
                subject.minSupported == nil,
                "the previous host's floor must not answer for the new one")

            fixture.write(config: #"{"min_supported":"3.0.0"}"#, at: clock.now)
            subject.setDebugConfigURL(nil)
            #expect(
                subject.effectiveConfigURL == URL(
                    string: "https://example.invalid/app-config.json")!)
            #expect(
                subject.minSupported == nil, "going back to live drops the dev host's bytes too")
        }

        @Test("the host override survives a relaunch")
        func hostOverrideSurvivesRelaunch() {
            let dev = URL(string: "https://dev.example.invalid/app-config.json")!
            store().setDebugConfigURL(dev)
            #expect(store().effectiveConfigURL == dev)
        }

        @Test("clearing the dismissal lets a notice be shown again")
        func clearDismissalRestoresNotice() {
            fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
            let subject = store()
            subject.dismissCurrentNotice()
            #expect(subject.state == .open)

            subject.debugClearDismissal()
            #expect(subject.dismissedVersion == nil)
            #expect(subject.state == .notice(latest: AppVersion("2.0.0")!))
        }

        @Test("releaseDebugWall un-bricks a build the diagnostics screen walled")
        func releaseDebugWallUnbricks() {
            let subject = store()
            subject.setDebugForcedState(.blocked)
            let dev = URL(string: "https://dev.example.invalid/app-config.json")!
            subject.setDebugConfigURL(dev)
            #expect(subject.state == .blocked)

            subject.releaseDebugWall()
            #expect(subject.debugForcedState == nil)
            #expect(subject.debugConfigURL == nil)
            #expect(subject.state == .open)
            #expect(store().state == .open, "and it stays released across a relaunch")
        }

        @Test("a running version whose last component cannot be bumped announces itself")
        func forcedNoticeSurvivesAnUnbumpableVersion() {
            let unbumpable = "1.\(Int.max)"
            let subject = store(current: unbumpable)
            subject.setDebugForcedState(.notice)
            #expect(
                subject.state == .notice(latest: AppVersion(unbumpable)!),
                "the bump overflows, and nothing in the package may trap")
        }

        @Test("a host switched mid-refresh never gets the previous host's body")
        func hostSwitchMidRefreshDiscardsTheBody() async {
            let transport = GatedTransport(
                config: .ok(#"{"min_supported":"2.0.0"}"#), lookup: nil)
            let subject = store(fetch: transport.fetching)

            let refresh = Task { await subject.refresh() }
            await transport.waitForRequests(1)

            let dev = URL(string: "https://dev.example.invalid/app-config.json")!
            subject.setDebugConfigURL(dev)
            transport.release()
            await refresh.value

            #expect(
                subject.minSupported == nil,
                "the previous host's floor must not be written under the new host's name")
            #expect(subject.cacheAge(.config) == nil, "and nothing was cached for it")
        }
    }
#endif
