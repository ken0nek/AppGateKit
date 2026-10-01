extension GateDecision {
    /// Applies the presentation rules to an already-evaluated decision.
    ///
    /// These rules are not in the evaluator because none of them concern
    /// versions. They concern what else is on screen. They are here, and not
    /// inline in a view, so they are unit-tested.
    ///
    /// The host supplies the inputs. The package never reads a launch argument
    /// or a defaults key to find them.
    ///
    /// - Parameters:
    ///   - capturingScreenshots: a screenshot run is in progress. Suppresses
    ///     the wall and the notice, because either one appearing mid-capture
    ///     corrupts a locale × device run.
    ///   - hasCompletedOnboarding: when `false`, suppresses the notice only.
    ///     The wall still shows, because a walled build must not be usable and
    ///     onboarding is use.
    ///   - promptShownThisSession: another prompt has already used this
    ///     session's modal. Suppresses the notice only. Two modals must never
    ///     stack, and the notice yields because the other prompt is harder to
    ///     reschedule.
    public func suppressed(
        capturingScreenshots: Bool,
        hasCompletedOnboarding: Bool,
        promptShownThisSession: Bool
    ) -> GateDecision {
        if capturingScreenshots {
            guard state != .open else { return self }
            return GateDecision(
                state: .open,
                diagnosis: .suppressed(released: state, reason: .capturingScreenshots)
            )
        }

        // The remaining rules apply to the notice only.
        guard case .notice = state else { return self }

        if !hasCompletedOnboarding {
            return GateDecision(
                state: .open,
                diagnosis: .suppressed(released: state, reason: .onboardingIncomplete)
            )
        }
        if promptShownThisSession {
            return GateDecision(
                state: .open,
                diagnosis: .suppressed(released: state, reason: .promptShownThisSession)
            )
        }
        return self
    }
}
