import Testing

@testable import AppGateCore

struct SuppressionTests {
    private let wall = GateDecision(
        state: .blocked, diagnosis: .belowMinimumSupported(floor: AppVersion("2.0.0")!)
    )
    private let notice = GateDecision(
        state: .notice(latest: AppVersion("1.5.0")!),
        diagnosis: .newerVersionAvailable(latest: AppVersion("1.5.0")!)
    )

    @Test("a screenshot run suppresses the wall")
    func screenshotsSuppressWall() {
        let result = wall.suppressed(
            capturingScreenshots: true, hasCompletedOnboarding: true, promptShownThisSession: false
        )
        #expect(result.state == .open)
        #expect(result.diagnosis == .suppressed(released: .blocked, reason: .capturingScreenshots))
    }

    @Test("a screenshot run suppresses the notice")
    func screenshotsSuppressNotice() {
        let result = notice.suppressed(
            capturingScreenshots: true, hasCompletedOnboarding: true, promptShownThisSession: false
        )
        #expect(result.state == .open)
        #expect(
            result.diagnosis
                == .suppressed(
                    released: .notice(latest: AppVersion("1.5.0")!), reason: .capturingScreenshots
                )
        )
    }

    @Test("unfinished onboarding suppresses the notice")
    func onboardingSuppressesNotice() {
        let result = notice.suppressed(
            capturingScreenshots: false, hasCompletedOnboarding: false,
            promptShownThisSession: false
        )
        #expect(result.state == .open)
        #expect(
            result.diagnosis
                == .suppressed(
                    released: .notice(latest: AppVersion("1.5.0")!), reason: .onboardingIncomplete
                )
        )
    }

    @Test("unfinished onboarding does NOT suppress the wall — a walled build must not be usable")
    func onboardingDoesNotSuppressWall() {
        let result = wall.suppressed(
            capturingScreenshots: false, hasCompletedOnboarding: false,
            promptShownThisSession: false
        )
        #expect(result == wall)
    }

    @Test("a prompt already shown this session suppresses the notice")
    func promptSuppressesNotice() {
        let result = notice.suppressed(
            capturingScreenshots: false, hasCompletedOnboarding: true, promptShownThisSession: true
        )
        #expect(result.state == .open)
        #expect(
            result.diagnosis
                == .suppressed(
                    released: .notice(latest: AppVersion("1.5.0")!), reason: .promptShownThisSession
                )
        )
    }

    @Test("a prompt already shown this session does NOT suppress the wall")
    func promptDoesNotSuppressWall() {
        let result = wall.suppressed(
            capturingScreenshots: false, hasCompletedOnboarding: true, promptShownThisSession: true
        )
        #expect(result == wall)
    }

    @Test("nothing to suppress is returned untouched, diagnosis and all")
    func openIsUntouched() {
        let open = GateDecision(state: .open, diagnosis: .noGateApplies)
        #expect(
            open.suppressed(
                capturingScreenshots: true, hasCompletedOnboarding: false,
                promptShownThisSession: true) == open)
    }

    @Test("a released wall is not re-diagnosed as suppressed")
    func releasedDecisionKeepsItsDiagnosis() {
        let released = GateDecision(
            state: .open,
            diagnosis: .releasedOSCannotInstall(
                released: .blocked, minimumOSVersion: AppVersion("26.0")!)
        )
        #expect(
            released.suppressed(
                capturingScreenshots: true, hasCompletedOnboarding: false,
                promptShownThisSession: true) == released)
    }

    @Test("a clear notice passes through untouched")
    func clearNoticeSurvives() {
        #expect(
            notice.suppressed(
                capturingScreenshots: false, hasCompletedOnboarding: true,
                promptShownThisSession: false
            ) == notice
        )
    }
}
