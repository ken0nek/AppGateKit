import AppGateCore
import Foundation
import Testing

@testable import AppGateClient

@MainActor
final class AppGateStoreCacheTests {
    private let fixture: StoreFixture
    private let clock = TestClock()

    init() throws {
        fixture = try StoreFixture()
    }

    private func store(current: String = "1.0.0", os: String = "26.0") -> AppGateStore {
        AppGateStore(
            configURL: URL(string: "https://example.invalid/app-config.json")!,
            appStoreID: "123456789",
            currentVersion: current,
            osVersion: os,
            defaults: fixture.defaults,
            keyPrefix: StoreFixture.keyPrefix,
            fetch: { _ in nil },
            now: clock.provider
        )
    }

    @Test("a cold launch is seeded from the caches before any fetch")
    func seedsSynchronouslyFromCache() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        #expect(store().state == .blocked)
    }

    @Test("an empty cache gates nothing")
    func emptyCacheIsOpen() {
        let subject = store()
        #expect(subject.state == .open)
        #expect(subject.minSupported == nil)
        #expect(subject.latestVersion == nil)
    }

    @Test("a cache past its 24 h TTL lapses to absent rather than enforcing a stale rule")
    func lapsedCacheIsAbsent() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        clock.advance(by: AppGateStore.cacheTTL + 1)
        let subject = store()
        #expect(subject.minSupported == nil)
        #expect(subject.state == .open)
    }

    @Test("a cache one second inside the TTL still stands")
    func freshCacheStands() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        clock.advance(by: AppGateStore.cacheTTL - 1)
        #expect(store().state == .blocked)
    }

    @Test("a cache stamp in the future reads as unusable, not infinitely fresh")
    func clockSkewGuard() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now.addingTimeInterval(3600))
        let subject = store()
        #expect(subject.minSupported == nil)
        #expect(subject.state == .open)
    }

    @Test("the envelope is re-validated on read, so a blob that no longer decodes is absent")
    func revalidatesOnRead() {
        fixture.write(config: "not json at all", at: clock.now)
        #expect(store().minSupported == nil)
    }

    @Test("a cached lookup supplies both the latest version and the OS floor")
    func lookupCacheSuppliesBothFields() {
        fixture.write(
            lookup: #"{"results":[{"version":"2.0.0","minimumOsVersion":"26.0"}]}"#, at: clock.now)
        let subject = store(current: "1.0.0", os: "26.0")
        #expect(subject.latestVersion == "2.0.0")
        #expect(subject.minimumOSVersion == "26.0")
        #expect(subject.state == .notice(latest: AppVersion("2.0.0")!))
    }

    @Test("a cached lookup whose OS floor is above this device releases the wall")
    func lookupReleasesWallForOldOS() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        fixture.write(
            lookup: #"{"results":[{"version":"2.0.0","minimumOsVersion":"26.0"}]}"#, at: clock.now)
        let subject = store(current: "1.0.0", os: "18.0")
        #expect(subject.state == .open)
        #expect(
            subject.diagnosis
                == .releasedOSCannotInstall(
                    released: .blocked, minimumOSVersion: AppVersion("26.0")!)
        )
    }

    @Test("cacheAge reports each source separately, and nil for one never written")
    func cacheAgeReportsPerSource() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        clock.advance(by: 120)
        let subject = store()
        #expect(subject.cacheAge(.config) == 120)
        #expect(subject.cacheAge(.lookup) == nil)
    }

    @Test("a persisted dismissal is read at init")
    func dismissalIsSeeded() {
        fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
        fixture.write(dismissed: "2.0")
        let subject = store()
        #expect(subject.dismissedVersion == "2.0")
        #expect(subject.state == .open)
    }

    @Test("keys are namespaced by the prefix, so a host's own keys cannot collide")
    func keysAreNamespaced() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        let elsewhere = AppGateStore(
            configURL: URL(string: "https://example.invalid/app-config.json")!,
            appStoreID: "123456789",
            currentVersion: "1.0.0",
            osVersion: "26.0",
            defaults: fixture.defaults,
            keyPrefix: "SomethingElse.",
            fetch: { _ in nil },
            now: clock.provider
        )
        #expect(elsewhere.minSupported == nil)
    }
}
