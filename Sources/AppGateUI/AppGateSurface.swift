import AppGateCore

/// Which view the gate asks for, after the suppression rules have run.
///
/// Internal, and separate from the modifier, because a SwiftUI body cannot be
/// unit-tested and this branch needs tests.
enum AppGateSurface: Equatable {
    case none
    case wall
    case notice(version: String)
}

extension AppGateSurface {
    /// The view to show for an already-suppressed state.
    ///
    /// This is an exhaustive `switch` on purpose. The evaluator's three checks
    /// on `GateState` are inequality and pattern checks, which would compile
    /// unchanged against a fourth `maintenance` case. This `switch` will not
    /// compile, so the compiler names it as a site that must decide what
    /// maintenance looks like on screen.
    ///
    /// - Parameter debugWallReleased: the DEBUG release has been used this
    ///   session. Always `false` in a Release build, which has no control that
    ///   can set it.
    static func resolve(_ state: GateState, debugWallReleased: Bool) -> AppGateSurface {
        switch state {
        case .open:
            return .none
        case .blocked:
            return debugWallReleased ? .none : .wall
        case .notice(let latest):
            return .notice(version: latest.description)
        }
    }
}
