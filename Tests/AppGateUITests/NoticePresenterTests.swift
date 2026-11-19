import Testing

@testable import AppGateUI

/// The sequences a SwiftUI body cannot be asked about: which sheet is up, and
/// which close is recorded.
struct NoticePresenterTests {
    /// A presenter whose sheet for `version` is on screen.
    private func showing(_ version: String) -> NoticePresenter {
        var presenter = NoticePresenter()
        presenter.gateChanged(to: version)
        presenter.appeared(version: version)
        return presenter
    }

    @Test("a notice the gate asks for is presented")
    func presents() {
        var presenter = NoticePresenter()
        presenter.gateChanged(to: "1.5")
        #expect(presenter.item?.id == "1.5")
    }

    @Test("a close the user made is recorded against the sheet that was up")
    func userCloseRecords() {
        var presenter = showing("1.5")
        presenter.userClosed()
        #expect(presenter.item == nil)
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.5", accepted: false))
        #expect(presenter.sheetDismissed() == nil, "one close is recorded once")
    }

    @Test("accepting marks the close as accepted")
    func acceptMarksTheClose() {
        var presenter = showing("1.5")
        presenter.accept(version: "1.5")
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.5", accepted: true))
    }

    @Test("a notice the gate withdraws records nothing")
    func withdrawalRecordsNothing() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: nil)
        #expect(presenter.item == nil)
        #expect(presenter.sheetDismissed() == nil)
    }

    @Test("a swipe that lands before a withdrawal is still the user's close")
    func swipeThenWithdrawalRecords() {
        var presenter = showing("1.5")
        presenter.userClosed()
        presenter.gateChanged(to: nil)
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.5", accepted: false))
    }

    @Test("a newer version replacing the sheet records nothing for either version")
    func replacementRecordsNothing() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: "1.6")
        #expect(presenter.item?.id == "1.6")
        #expect(presenter.sheetDismissed() == nil, "the user did not close the 1.5 sheet")
        #expect(presenter.item?.id == "1.6", "the 1.6 sheet is still asked for")
    }

    @Test("a cleared binding during a replacement is not the user's close")
    func clearedBindingDuringReplacementIsIgnored() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: "1.6")
        presenter.userClosed()
        #expect(presenter.item?.id == "1.6", "the 1.6 sheet has not appeared, so nobody closed it")
        #expect(presenter.sheetDismissed() == nil)
    }

    @Test("after a replacement, the user's close records the version that replaced it")
    func closeAfterReplacementRecordsTheNewVersion() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: "1.6")
        _ = presenter.sheetDismissed()
        presenter.appeared(version: "1.6")
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.6", accepted: false))
    }

    @Test("the same holds when the replaced sheet's dismissal is never delivered")
    func closeAfterSilentReplacementRecordsTheNewVersion() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: "1.6")
        presenter.appeared(version: "1.6")
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.6", accepted: false))
    }

    @Test("a withdrawal whose dismissal is never delivered does not silence the next notice")
    func undeliveredWithdrawalLeavesNoFlag() {
        var presenter = showing("1.5")
        presenter.gateChanged(to: nil)
        presenter.gateChanged(to: "1.6")
        presenter.appeared(version: "1.6")
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.6", accepted: false))
    }

    @Test("an accept on a replaced sheet does not carry to the sheet that replaced it")
    func acceptDoesNotCarryOver() {
        var presenter = showing("1.5")
        presenter.accept(version: "1.5")
        presenter.gateChanged(to: "1.6")
        presenter.appeared(version: "1.6")
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.6", accepted: false))
    }

    @Test("a close the user made survives a newer version arriving before the dismissal")
    func closeThenNewerVersion() {
        var presenter = showing("1.5")
        presenter.accept(version: "1.5")
        presenter.userClosed()
        presenter.gateChanged(to: "1.6")
        #expect(presenter.sheetDismissed() == NoticeClose(version: "1.5", accepted: true))
        #expect(presenter.item?.id == "1.6")
    }

    @Test("a close with no sheet up records nothing")
    func strayCloseRecordsNothing() {
        var presenter = NoticePresenter()
        presenter.userClosed()
        #expect(presenter.sheetDismissed() == nil)
    }
}
