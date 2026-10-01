import Foundation

/// Decides the gate in one place, so no call site reasons about precedence.
///
/// It reads two inputs. A person sets the configured floor, versions it as
/// code and raises it on purpose, and it produces the wall. The App Store's
/// current version is whatever is downloadable right now, and it produces the
/// notice.
///
/// The gate fails open. It walls a build only when the config sets a floor,
/// the config could be read, and both versions parsed. An absent config, an
/// unparseable threshold, an unparseable running version and a lapsed cache
/// all resolve to ``GateState/open``. A bug here can fail to gate. It cannot
/// lock users out of the app.
public enum AppGate {

    /// Decide the gate.
    ///
    /// - Parameters:
    ///   - minSupported: the config's `min_supported`, or `nil` when the config
    ///     is absent, undecodable or past its cache TTL.
    ///   - latest: the App Store's current marketing version, same `nil` rule.
    ///   - current: this build's marketing version.
    ///   - dismissedVersion: the version the user last dismissed. A host that
    ///     asks again after a cooldown, instead of once per version, passes the
    ///     version until the cooldown elapses and `nil` after.
    ///   - osVersion: the OS this build is running on.
    ///   - minimumOSVersion: the OS the App Store build requires, from the same
    ///     lookup `latest` came from.
    public static func evaluate(
        minSupported: String?,
        latest: String?,
        current: String,
        dismissedVersion: String? = nil,
        osVersion: String? = nil,
        minimumOSVersion: String? = nil
    ) -> GateDecision {
        // Nothing can be compared against an unparseable running version. This
        // check runs first, so no later branch reaches a comparison without a
        // parsed version.
        guard let running = AppVersion(current) else {
            return GateDecision(state: .open, diagnosis: .currentVersionUnparseable)
        }

        let decision = gate(
            minSupported: minSupported,
            latest: latest,
            current: running,
            dismissedVersion: dismissedVersion
        )

        // The lookup can release a gate and can never raise one. An unknown or
        // unparseable `minimumOsVersion` leaves the gate standing. If a failed
        // lookup released it, an outage at Apple would disable every wall at
        // once. Sending someone to a binary their OS cannot install is worse
        // than silence, so this releases the notice as well as the wall.
        guard decision.state.isReleasedByOSInstallCheck,
            let minimumOS = minimumOSVersion.flatMap(AppVersion.init),
            let runningOS = osVersion.flatMap(AppVersion.init),
            runningOS < minimumOS
        else {
            return decision
        }

        return GateDecision(
            state: .open,
            diagnosis: .releasedOSCannotInstall(
                released: decision.state, minimumOSVersion: minimumOS
            )
        )
    }

    private static func gate(
        minSupported: String?,
        latest: String?,
        current: AppVersion,
        dismissedVersion: String?
    ) -> GateDecision {
        // The wall wins over the notice here, before any view runs, so a build
        // cannot show both.
        if let minSupported, let floor = AppVersion(minSupported), current < floor {
            return GateDecision(state: .blocked, diagnosis: .belowMinimumSupported(floor: floor))
        }

        guard let latest, let newest = AppVersion(latest), current < newest else {
            return GateDecision(state: .open, diagnosis: .noGateApplies)
        }

        // Compare parsed versions, so dismissing "1.4" also covers "1.4.0". The
        // lookup does not keep the component count stable between reads.
        if let dismissedVersion, let dismissed = AppVersion(dismissedVersion), dismissed == newest {
            return GateDecision(state: .open, diagnosis: .newerVersionDismissed(latest: newest))
        }

        return GateDecision(
            state: .notice(latest: newest), diagnosis: .newerVersionAvailable(latest: newest)
        )
    }
}
