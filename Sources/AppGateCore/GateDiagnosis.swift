/// Why a gate that applied was not shown. The host supplies the inputs,
/// because only the presenting layer knows what else is on screen. The rules
/// live in this module so they are unit-tested.
public enum SuppressionReason: Equatable, Sendable {
    /// A screenshot run is in progress. Suppresses the wall and the notice. A
    /// wall or a sheet that appears mid-capture corrupts a locale × device
    /// run, and the damage shows only in the uploaded screenshots.
    case capturingScreenshots
    /// Onboarding is unfinished. Suppresses the notice only. The wall still
    /// shows, because a walled build must not be usable and onboarding is use.
    case onboardingIncomplete
    /// Another prompt has already used this session's modal. Suppresses the
    /// notice only. Two modals must never stack, and the notice is the one
    /// that yields, because a review prompt is harder to reschedule.
    case promptShownThisSession
}

/// Which input decided the gate. Branch on ``GateState`` for production logic.
/// This type exists to tell "no floor applied" apart from "a floor applied and
/// was released".
///
/// Releasing a wall because the running OS cannot install the newer build
/// leaves a group of installs that can never be gated. A host fires its own
/// signal on ``releasedOSCannotInstall`` so it can count that group.
public enum GateDiagnosis: Equatable, Sendable {
    /// The running version did not parse, so nothing was compared.
    case currentVersionUnparseable
    /// No floor applied and no newer version was available.
    case noGateApplies
    /// The configured floor applied and the running build is below it.
    case belowMinimumSupported(floor: AppVersion)
    /// A newer version exists and has not been dismissed.
    case newerVersionAvailable(latest: AppVersion)
    /// A newer version exists but this one was already dismissed.
    case newerVersionDismissed(latest: AppVersion)
    /// A gate applied and was released, because the running OS cannot install
    /// the build the user would be sent to.
    case releasedOSCannotInstall(released: GateState, minimumOSVersion: AppVersion)
    /// A gate applied and a suppression rule dropped it.
    case suppressed(released: GateState, reason: SuppressionReason)
}
