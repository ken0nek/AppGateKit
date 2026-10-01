import AppGateClient
import AppGateCore
import Foundation
import Testing

@testable import AppGateUI

/// Tests the rule that a SwiftUI `onDismiss` cannot be tested for directly.
/// The dismissal is written however the user closes the notice, and only the
/// report says whether they accepted or declined.
@MainActor
struct NoticeDismissalTests {
    /// `defaults: nil` on purpose. A view reads the store's observed
    /// `dismissedVersion` and not the suite. Testing against that property
    /// means this suite needs no per-test `UserDefaults` teardown.
    private let store = AppGateStore(
        configURL: URL(string: "https://example.com/app-config.json")!,
        appStoreID: "123456789",
        currentVersion: "1.0.0",
        osVersion: "18.0",
        defaults: nil,
        fetch: { _ in nil }
    )

    @Test("declining records the dismissal")
    func declineRecords() {
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: false, withdrawn: false, report: nil
        )
        #expect(store.dismissedVersion == "1.5.0")
    }

    @Test("accepting records the dismissal too — the nudge asks once per version")
    func acceptRecords() {
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: true, withdrawn: false, report: nil
        )
        #expect(store.dismissedVersion == "1.5.0")
    }

    @Test("the report distinguishes what the dismissal does not")
    func reportDistinguishes() {
        var reported: [(String, Bool)] = []
        let report: (String, Bool) -> Void = { reported.append(($0, $1)) }

        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: true, withdrawn: false, report: report
        )
        resolveNoticeDismissal(
            store: store, version: "1.6.0", accepted: false, withdrawn: false, report: report
        )

        #expect(reported.map(\.0) == ["1.5.0", "1.6.0"])
        #expect(reported.map(\.1) == [true, false])
    }

    /// The dismissal records the version that was on screen, and not the
    /// version the store announces when the sheet finishes closing. A refresh
    /// that finishes while the sheet is up can change the store's notice to a
    /// newer version, and recording that one would stop the notice for a
    /// version the user never saw.
    @Test("the dismissal is recorded against the version that was shown")
    func recordsTheShownVersion() throws {
        store.dismiss(version: try #require(AppVersion("9.9.9")))
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: false, withdrawn: false, report: nil
        )
        #expect(store.dismissedVersion == "1.5.0")
    }

    /// Nothing here traps. A version string that does not parse cannot be
    /// dismissed, so the notice shows again and the app does not crash when
    /// the sheet closes.
    @Test("an unparseable version records nothing and does not trap")
    func unparseableRecordsNothing() {
        var reported = false
        resolveNoticeDismissal(
            store: store, version: "not-a-version", accepted: false, withdrawn: false,
            report: { _, _ in reported = true }
        )
        #expect(store.dismissedVersion == nil)
        #expect(reported, "the report fires even when the dismissal cannot be written")
    }

    /// A floor that rises mid-session changes the state to `.blocked` and
    /// closes the sheet. If that close recorded a dismissal, the user would
    /// not see the notice after the floor is lowered again.
    @Test("a withdrawn notice records nothing — the user was never asked")
    func withdrawnRecordsNothing() {
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: false, withdrawn: true, report: nil
        )
        #expect(store.dismissedVersion == nil)
    }

    @Test("a withdrawn notice reports nothing — a decline nobody made is worse than silence")
    func withdrawnReportsNothing() {
        var reported = false
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: false, withdrawn: true,
            report: { _, _ in reported = true }
        )
        #expect(!reported)
    }

    /// Checks that the early return in `resolveNoticeDismissal` only returns.
    /// A withdrawal must not erase a dismissal already recorded for a
    /// different version.
    @Test("a withdrawal does not disturb a dismissal already recorded")
    func withdrawalLeavesExistingDismissalAlone() throws {
        store.dismiss(version: try #require(AppVersion("1.4.0")))
        resolveNoticeDismissal(
            store: store, version: "1.5.0", accepted: false, withdrawn: true, report: nil
        )
        #expect(store.dismissedVersion == "1.4.0")
    }
}
