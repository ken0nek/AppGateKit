/// What the app should do about updating right now.
///
/// A fourth `maintenance` case will be added later, in a major version. Adding
/// a case breaks every exhaustive switch, and that is intended. The compiler
/// then names each site that must decide what maintenance looks like.
public enum GateState: Equatable, Sendable {
    /// No gate. Every fail-open path resolves here.
    case open
    /// A newer build exists and has not been dismissed. Carries the version it
    /// announces, so the view can name it and persist a dismissal against that
    /// version.
    case notice(latest: AppVersion)
    /// The running build is below the configured floor and must not be used.
    case blocked
}

extension GateState {
    /// Whether an OS that cannot install the newer build is a reason to drop
    /// this gate.
    ///
    /// This is an exhaustive `switch` and not `!= .open`. The two give the
    /// same answer today and different answers once a fourth case exists. The
    /// wall and the notice both point at an App Store build, so an OS that
    /// cannot install that build makes both pointless. `maintenance` will be
    /// different. A server outage has nothing to do with what this device can
    /// download, and releasing it would let an old OS out of a state the
    /// server put the app in.
    ///
    /// This is the one place in `Sources/` where a new case must answer a
    /// question it cannot answer by default. The two `guard`s in
    /// `suppressed(...)` already give the right answer for a fourth case. A
    /// capture run must not photograph any gate, and unfinished onboarding
    /// suppresses only the notice.
    var isReleasedByOSInstallCheck: Bool {
        switch self {
        case .open: false
        case .blocked, .notice: true
        }
    }
}
