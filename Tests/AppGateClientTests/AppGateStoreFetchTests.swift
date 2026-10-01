import AppGateCore
import Foundation
import Testing

@testable import AppGateClient

@MainActor
final class AppGateStoreFetchTests {
    private let fixture: StoreFixture
    private let clock = TestClock()

    init() throws {
        fixture = try StoreFixture()
    }

    private func store(_ transport: StubTransport, current: String = "1.0.0") -> AppGateStore {
        AppGateStore(
            configURL: URL(string: "https://example.invalid/app-config.json")!,
            appStoreID: "123456789",
            currentVersion: current,
            osVersion: "26.0",
            defaults: fixture.defaults,
            keyPrefix: StoreFixture.keyPrefix,
            fetch: transport.fetching,
            now: clock.provider
        )
    }

    private func store(fetch: @escaping AppGateFetching, current: String = "1.0.0") -> AppGateStore
    {
        AppGateStore(
            configURL: URL(string: "https://example.invalid/app-config.json")!,
            appStoreID: "123456789",
            currentVersion: current,
            osVersion: "26.0",
            defaults: fixture.defaults,
            keyPrefix: StoreFixture.keyPrefix,
            fetch: fetch,
            now: clock.provider
        )
    }

    @Test("a refresh reads both sources, and both are in flight at once")
    func bothSourcesConcurrently() async {
        let transport = StubTransport(
            config: .ok(#"{"min_supported":"2.0.0"}"#),
            lookup: .ok(#"{"results":[{"version":"3.0.0","minimumOsVersion":"26.0"}]}"#)
        )
        let subject = store(transport)
        await subject.refresh()

        #expect(transport.requested.count == 2)
        #expect(
            transport.overlapped,
            "the two sources are independent; one being slow must not delay the other")
        #expect(subject.minSupported == "2.0.0")
        #expect(subject.latestVersion == "3.0.0")
        #expect(subject.state == .blocked)
    }

    @Test("a failed refresh never clobbers a good cache")
    func failedRefreshKeepsLastGood() async {
        let good = store(StubTransport(config: .ok(#"{"min_supported":"2.0.0"}"#), lookup: nil))
        await good.refresh()
        #expect(good.minSupported == "2.0.0")

        let offline = store(StubTransport(config: nil, lookup: nil))
        await offline.refresh()
        #expect(
            offline.minSupported == "2.0.0",
            "an unreachable source lapses on its TTL, it is not cleared")
        #expect(offline.state == .blocked)
    }

    @Test("a non-200 is not an answer, and leaves the cache alone")
    func nonSuccessIsNotAnAnswer() async {
        let good = store(StubTransport(config: .ok(#"{"min_supported":"2.0.0"}"#), lookup: nil))
        await good.refresh()

        let broken = store(StubTransport(config: .status(503), lookup: nil))
        await broken.refresh()
        #expect(broken.minSupported == "2.0.0")
    }

    @Test("a 200 carrying a malformed body is not an answer")
    func malformedBodyIsNotAnAnswer() async {
        let good = store(StubTransport(config: .ok(#"{"min_supported":"2.0.0"}"#), lookup: nil))
        await good.refresh()

        let garbage = store(StubTransport(config: .ok("<html>maintenance</html>"), lookup: nil))
        await garbage.refresh()
        #expect(garbage.minSupported == "2.0.0")
    }

    @Test("an empty results array carries no version, so nothing is cached")
    func emptyResultsIsNotAnAnswer() async {
        let subject = store(StubTransport(config: nil, lookup: .ok(#"{"results":[]}"#)))
        await subject.refresh()
        #expect(subject.latestVersion == nil)
        #expect(subject.cacheAge(.lookup) == nil)
    }

    @Test("a lookup result with an empty version string is not an answer")
    func emptyVersionIsNotAnAnswer() async {
        let subject = store(
            StubTransport(config: nil, lookup: .ok(#"{"results":[{"version":""}]}"#)))
        await subject.refresh()
        #expect(subject.latestVersion == nil)
    }

    @Test("a config that decodes but carries no floor is still a good answer")
    func emptyConfigIsAnAnswer() async {
        let subject = store(StubTransport(config: .ok("{}"), lookup: nil))
        await subject.refresh()
        #expect(subject.minSupported == nil)
        #expect(subject.cacheAge(.config) == 0, "the blob cached, it simply carries no floor")
    }

    @Test("a good answer that drops the floor lowers the wall, stamp and all")
    func goodAnswerLowersTheWall() async {
        // The timestamp is in the past and inside the TTL, so the cache is in
        // use now. The refresh has to update the timestamp too. Otherwise the
        // wall stays up after the server drops the floor.
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now - 3600)
        let subject = store(StubTransport(config: .ok("{}"), lookup: nil))
        #expect(subject.state == .blocked)
        #expect(subject.cacheAge(.config) == 3600)

        await subject.refresh()

        #expect(subject.minSupported == nil, "the server dropped the floor, so the floor is gone")
        #expect(subject.state == .open)
        #expect(subject.cacheAge(.config) == 0, "and the stamp moved, or the old body outlives it")
    }

    @Test("one stale source is enough to be due, whichever one it is")
    func eitherSourceStaleIsDue() {
        let subject = store(StubTransport(config: nil, lookup: nil))

        fixture.write(config: "{}", at: clock.now)
        fixture.write(lookup: #"{"results":[]}"#, at: clock.now - 7 * 60 * 60)
        #expect(subject.isStale, "the lookup is past the interval, so a refresh is due")

        fixture.write(config: "{}", at: clock.now - 7 * 60 * 60)
        fixture.write(lookup: #"{"results":[]}"#, at: clock.now)
        #expect(subject.isStale, "and the config alone is enough — it carries the kill switch")
    }

    @Test("a stamp in the future is unusable, not fresh, so a refresh stays due")
    func futureStampIsDue() {
        let subject = store(StubTransport(config: nil, lookup: nil))
        fixture.write(config: "{}", at: clock.now + 3600)
        fixture.write(lookup: #"{"results":[]}"#, at: clock.now)
        #expect(subject.isStale, "one clock skew must not stop activation refreshing forever")
    }

    @Test("a source that has never answered is always due")
    func neverFetchedIsStale() {
        #expect(store(StubTransport(config: nil, lookup: nil)).isStale)
    }

    @Test("a source refreshed inside the interval is not due, and refreshIfStale does not refetch")
    func freshIsNotDue() async {
        let transport = StubTransport(
            config: .ok(#"{"min_supported":"2.0.0"}"#),
            lookup: .ok(#"{"results":[{"version":"3.0.0"}]}"#)
        )
        let subject = store(transport)
        await subject.refresh()
        #expect(transport.requested.count == 2)
        #expect(subject.isStale == false)

        await subject.refreshIfStale()
        #expect(transport.requested.count == 2, "still fresh, so nothing was refetched")
    }

    @Test("past the foreground interval, refreshIfStale refetches")
    func staleRefetches() async {
        let transport = StubTransport(
            config: .ok(#"{"min_supported":"2.0.0"}"#),
            lookup: .ok(#"{"results":[{"version":"3.0.0"}]}"#)
        )
        let subject = store(transport)
        await subject.refresh()

        clock.advance(by: AppGateStore.foregroundRefreshInterval + 1)
        #expect(subject.isStale)
        await subject.refreshIfStale()
        #expect(transport.requested.count == 4)
    }

    @Test("refreshIfStale still recomputes when nothing is due")
    func notDueStillRecomputes() async {
        let transport = StubTransport(
            config: .ok("{}"),
            lookup: .ok(#"{"results":[{"version":"2.0.0"}]}"#)
        )
        let subject = store(transport)
        await subject.refresh()
        #expect(subject.state == .notice(latest: AppVersion("2.0.0")!))
        #expect(subject.isStale == false)

        // Writing the dismissal directly to the suite stands in for any change
        // the store did not make. Nothing is stale, so nothing is fetched
        // again. The recompute still has to run, because a cache can expire
        // without a fetch.
        fixture.write(dismissed: "2.0.0")
        await subject.refreshIfStale()
        #expect(transport.requested.count == 2, "nothing was due, so nothing was refetched")
        #expect(subject.state == .open, "but it recomputed")
    }

    @Test("a second refresh joins the one in flight rather than starting its own")
    func concurrentRefreshIsSingleFlight() async {
        let transport = GatedTransport(
            config: .ok(#"{"min_supported":"2.0.0"}"#),
            lookup: .ok(#"{"results":[{"version":"3.0.0"}]}"#)
        )
        let subject = store(fetch: transport.fetching)

        let first = Task { await subject.refresh() }
        await transport.waitForRequests(2)

        let second = Task { await subject.refresh() }
        // Yield the main actor so `second` starts awaiting the running
        // refresh before the transport releases anything.
        await Task.yield()
        await Task.yield()

        transport.release()
        await first.value
        await second.value

        #expect(
            transport.requested.count == 2,
            "the second caller joined the refresh in flight, rather than fetching both again")
        #expect(subject.minSupported == "2.0.0", "and it got the result of the one it joined")
        #expect(subject.latestVersion == "3.0.0")
    }
}
