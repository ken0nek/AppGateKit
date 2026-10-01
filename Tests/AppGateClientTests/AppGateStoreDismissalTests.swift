import AppGateCore
import Foundation
import Testing

@testable import AppGateClient

@MainActor
final class AppGateStoreDismissalTests {
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

    @Test("dismissing the current notice silences it, and persists")
    func dismissSilencesAndPersists() {
        fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
        let subject = store()
        #expect(subject.state == .notice(latest: AppVersion("2.0.0")!))

        subject.dismissCurrentNotice()
        #expect(subject.state == .open)
        #expect(subject.dismissedVersion == "2.0.0")
        #expect(store().state == .open, "a relaunch reads the same dismissal")
    }

    @Test("dismissing when there is no notice does nothing")
    func dismissWithoutNoticeIsNoOp() {
        let subject = store()
        subject.dismissCurrentNotice()
        #expect(subject.dismissedVersion == nil)
    }

    @Test("a later version asks again")
    func laterVersionAsksAgain() {
        fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
        store().dismissCurrentNotice()

        fixture.write(lookup: #"{"results":[{"version":"2.1.0"}]}"#, at: clock.now)
        #expect(store().state == .notice(latest: AppVersion("2.1.0")!))
    }

    @Test("a dismissal persists the dotted form, so 2.0 and 2.0.0 are one dismissal")
    func dismissalPersistsDottedForm() {
        let subject = store()
        subject.dismiss(version: AppVersion("2.0")!)
        #expect(subject.dismissedVersion == "2.0")

        fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
        #expect(store().state == .open)
    }

    @Test("a dismissal never releases a wall")
    func dismissalNeverReleasesWall() {
        fixture.write(config: #"{"min_supported":"2.0.0"}"#, at: clock.now)
        fixture.write(lookup: #"{"results":[{"version":"2.0.0"}]}"#, at: clock.now)
        let subject = store()
        subject.dismiss(version: AppVersion("2.0.0")!)
        #expect(subject.state == .blocked)
    }

    @Test("a feature floor blocks a build below it")
    func featureFloorBlocks() {
        fixture.write(
            config: #"{"min_supported":"1.0.0","feature_floors":{"share":"2.2.0"}}"#, at: clock.now
        )
        let subject = store(current: "2.1.0")
        #expect(subject.featureFloors == ["share": "2.2.0"])
        #expect(subject.floor(for: "share") == AppVersion("2.2.0"))
        #expect(subject.isBlocked(feature: "share"))
        #expect(subject.isBlocked(feature: "export") == false)
        #expect(subject.state == .open, "a feature floor is not a wall")
    }

    @Test("a dismissal holds for the session even with no suite to persist it to")
    func dismissalHoldsWithoutDefaults() {
        // A nil `defaults` usually comes from a host that passes the result of
        // a failable App Group initializer without checking it.
        let subject = AppGateStore(
            configURL: URL(string: "https://example.invalid/app-config.json")!,
            appStoreID: "123456789",
            currentVersion: "1.0.0",
            osVersion: "26.0",
            defaults: nil,
            keyPrefix: StoreFixture.keyPrefix,
            fetch: { _ in nil },
            now: clock.provider
        )

        subject.dismiss(version: AppVersion("2.0.0")!)
        #expect(
            subject.dismissedVersion == "2.0.0",
            "the recompute inside `dismiss` has nowhere to re-read from, so it must not clobber")

        subject.recompute()
        #expect(subject.dismissedVersion == "2.0.0", "and no later recompute clobbers it either")
    }

    @Test("a lapsed config ungates every feature")
    func lapsedConfigUngatesFeatures() {
        fixture.write(config: #"{"feature_floors":{"share":"2.2.0"}}"#, at: clock.now)
        clock.advance(by: AppGateStore.cacheTTL + 1)
        let subject = store(current: "2.1.0")
        #expect(subject.isBlocked(feature: "share") == false)
    }
}
