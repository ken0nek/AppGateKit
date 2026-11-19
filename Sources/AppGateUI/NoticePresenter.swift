/// The sheet item for a notice. The version string is the identity, so a
/// different version presents a new sheet.
struct PresentedNotice: Identifiable, Equatable, Sendable {
    let id: String
}

/// A close the user made, and the version of the sheet they closed.
struct NoticeClose: Equatable, Sendable {
    let version: String
    let accepted: Bool
}

/// Which notice sheet is up, and which close is recorded.
///
/// A value type and not `@State` fields in the modifier, because a SwiftUI
/// body cannot be unit-tested and these sequences need tests.
///
/// Only a close the user made is recorded, against the version of the sheet
/// that was on screen when they closed it. A sheet the gate takes away, or
/// replaces with a newer version, records nothing.
struct NoticePresenter: Equatable, Sendable {
    /// The sheet the gate asks for, or `nil` for none.
    private(set) var item: PresentedNotice?
    private var appearedVersion: String?
    private var acceptedVersion: String?
    private var closedByUser: NoticeClose?

    /// The gate now asks for `version`, or for no notice.
    mutating func gateChanged(to version: String?) {
        if item?.id != version {
            appearedVersion = nil
            acceptedVersion = nil
        }
        item = version.map(PresentedNotice.init(id:))
    }

    /// The sheet for `version` is on screen.
    mutating func appeared(version: String) {
        appearedVersion = version
    }

    /// The host's notice reported that the user accepted `version`.
    mutating func accept(version: String) {
        acceptedVersion = version
    }

    /// SwiftUI cleared the sheet's item.
    ///
    /// Counted as the user's close only when the sheet had appeared. A sheet
    /// that has not appeared cannot have been closed by anyone, so a cleared
    /// binding at that point is SwiftUI tidying up after the gate changed the
    /// item, and treating it as a close would record a version nobody saw.
    mutating func userClosed() {
        guard let item, appearedVersion == item.id else { return }
        closedByUser = NoticeClose(version: item.id, accepted: acceptedVersion == item.id)
        appearedVersion = nil
        acceptedVersion = nil
        self.item = nil
    }

    /// A sheet finished closing. Returns the close to record, or `nil` when
    /// the user did not close it.
    mutating func sheetDismissed() -> NoticeClose? {
        defer { closedByUser = nil }
        return closedByUser
    }
}
