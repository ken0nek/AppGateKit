import AppGateClient
import AppGateCore
import SwiftUI

/// How the notice is presented. The wall is always a `fullScreenCover`,
/// because the user must not be able to dismiss it. The notice varies between
/// apps. Some show a short sheet and some show a full-screen "what's new", so
/// the host chooses.
public enum AppGateNoticePresentation: Equatable, Sendable {
    /// A sheet. Size it from your own view with `presentationDetents`.
    case sheet
    /// Full screen, as a release-notes screen is usually shown.
    case fullScreenCover
}

/// The value passed to the wall's builder.
///
/// It is empty in a Release build. The only thing a wall needs from the
/// package is the DEBUG release, and that must not exist in a shipped binary.
/// The builder's signature is the same in both configurations, so the host's
/// call site compiles in both. Only the members it can use differ.
@MainActor
public struct AppGateWallContext {
    #if DEBUG
        /// Takes the wall down and returns to the app.
        ///
        /// Call this from a control on your wall. The switch that forces a
        /// wall is behind the wall, and a forced wall persists across
        /// relaunches, so without this control nothing can reach the switch.
        /// The control can be hidden or labelled. Prefer a labelled one,
        /// because it cannot be mistaken for the shipping wall in a screenshot.
        ///
        /// It clears the forced state and returns to the live host, because
        /// either one can be the cause of the wall. It also keeps the wall
        /// down for the rest of this session, so it returns to the app even
        /// when the live config sets a wall. The wall can show again after a
        /// relaunch.
        public let releaseDebugWall: () -> Void

        init(releaseDebugWall: @escaping () -> Void) {
            self.releaseDebugWall = releaseDebugWall
        }
    #else
        init() {}
    #endif
}

/// The value passed to the notice's builder.
@MainActor
public struct AppGateNoticeContext {
    /// The version being announced, in dotted form, ready to display.
    public let version: String

    /// Call when the user accepts the update, before your view dismisses
    /// itself.
    ///
    /// It does not dismiss the view, and it does not change what is recorded.
    /// The dismissal is written however the user closes the notice. It only
    /// sets whether `onNoticeDismissed` reports this close as accepted or
    /// declined.
    public let accept: () -> Void

    init(version: String, accept: @escaping () -> Void) {
        self.version = version
        self.accept = accept
    }
}

/// Handles a closed notice. It records the dismissal however the user closed
/// the notice, and the report says whether they accepted or declined.
///
/// A withdrawn notice records nothing and reports nothing. The gate withdraws
/// a notice when a floor rises and the wall replaces it, when a host flag
/// reports another modal this session, or when the lookup releases it. The
/// sheet then closes without the user doing anything. Recording that would
/// stop the notice for a version the user may not have seen, and reporting it
/// would count a decline nobody made.
///
/// This is a free function and not an inline closure, because a SwiftUI
/// `onDismiss` cannot be unit-tested and these rules need tests. A notice
/// that did not record its dismissal would present again as soon as it closed.
@MainActor
func resolveNoticeDismissal(
    store: AppGateStore,
    version: String,
    accepted: Bool,
    withdrawn: Bool,
    report: ((String, Bool) -> Void)?
) {
    guard !withdrawn else { return }
    report?(version, accepted)
    // Dismiss the version that was on screen, and do not call
    // `dismissCurrentNotice()`. A refresh that finishes while the sheet is up
    // can change the store's notice to a newer version, and dismissing that
    // one would stop the notice for a version the user never saw.
    guard let shown = AppVersion(version) else { return }
    store.dismiss(version: shown)
}

private struct AppGateModifier<Wall: View, Notice: View>: ViewModifier {
    let store: AppGateStore
    let capturingScreenshots: Bool
    let hasCompletedOnboarding: Bool
    let promptShownThisSession: Bool
    let noticePresentation: AppGateNoticePresentation
    let onNoticeDismissed: ((String, Bool) -> Void)?
    let wall: (AppGateWallContext) -> Wall
    let notice: (AppGateNoticeContext) -> Notice

    @Environment(\.scenePhase) private var scenePhase

    /// The version the notice is announcing, copied into local state so the
    /// presentation binding can clear it. The version string is the item's
    /// identity, so a different version presents a new sheet.
    @State private var presentedNotice: PresentedNotice?
    /// The last version shown on screen. Stored separately because `onDismiss`
    /// runs after a swipe has already cleared `presentedNotice`, and the
    /// dismissal must be recorded against the version the user saw.
    @State private var shownVersion: String?
    /// Set by the notice's `accept`, read once by `onDismiss`.
    @State private var noticeAccepted = false
    /// The gate withdrew the notice while the sheet was up, so the user did
    /// not cause the close that follows. Read once by `onDismiss` and cleared
    /// there.
    @State private var noticeWithdrawn = false

    #if DEBUG
        /// Never reset within a session. The wall stays down for the rest of
        /// the session even if a live source still sets one, so the next
        /// recompute does not present it again.
        @State private var debugWallReleased = false
    #endif

    private struct PresentedNotice: Identifiable, Equatable {
        let id: String
    }

    /// The state after the suppression rules, which `AppGateCore` implements
    /// and tests. This property only gathers the inputs.
    private var surface: AppGateSurface {
        #if DEBUG
            let released = debugWallReleased
        #else
            let released = false
        #endif
        let suppressed = store.decision.suppressed(
            capturingScreenshots: capturingScreenshots,
            hasCompletedOnboarding: hasCompletedOnboarding,
            promptShownThisSession: promptShownThisSession
        )
        return .resolve(suppressed.state, debugWallReleased: released)
    }

    private var noticeVersion: String? {
        guard case .notice(let version) = surface else { return nil }
        return version
    }

    func body(content: Content) -> some View {
        content
            // Cold launch. `refresh` never throws, so there is nothing to
            // handle. On failure the caches stay as they were.
            .task { await store.refresh() }
            .onChange(of: scenePhase) { _, phase in
                // This handles foregrounding, not launch. `onChange` does not
                // fire for the initial value, so it never runs alongside the
                // task above. `.task(id: scenePhase)` would run at launch too,
                // and would cancel the refresh when the view disappears, which
                // the store's `refresh()` documentation rules out.
                // iOS suspends apps for days instead of cold-launching them, so
                // without this a raised floor reaches long-running installs
                // last.
                guard phase == .active else { return }
                Task { await store.refreshIfStale() }
            }
            .onChange(of: noticeVersion, initial: true) { _, version in
                // Assign the flag on every transition and never only set it. A
                // withdrawal may not reach `onDismiss`, because the sheet was
                // still presenting. The next notice then clears the flag, so
                // the flag does not suppress that notice's dismissal.
                noticeWithdrawn = version == nil && presentedNotice != nil
                presentedNotice = version.map(PresentedNotice.init(id:))
                if let version { shownVersion = version }
            }
            .appGateWall(isPresented: surface == .wall) { wallContent }
            .appGateNotice(
                noticePresentation,
                item: $presentedNotice,
                onDismiss: {
                    let withdrawn = noticeWithdrawn
                    noticeWithdrawn = false
                    let accepted = noticeAccepted
                    noticeAccepted = false
                    guard let version = shownVersion else { return }
                    resolveNoticeDismissal(
                        store: store,
                        version: version,
                        accepted: accepted,
                        withdrawn: withdrawn,
                        report: onNoticeDismissed
                    )
                },
                content: noticeContent
            )
    }

    /// The host's wall with interactive dismissal disabled, which is the one
    /// behaviour the package adds to it. Without this, a swipe dismisses the
    /// cover where a `fullScreenCover` is presented like a sheet, as on iPad.
    private var wallContent: some View {
        #if DEBUG
            let context = AppGateWallContext(releaseDebugWall: releaseDebugWall)
        #else
            let context = AppGateWallContext()
        #endif
        return wall(context).interactiveDismissDisabled()
    }

    private func noticeContent(_ item: PresentedNotice) -> Notice {
        notice(AppGateNoticeContext(version: item.id, accept: { noticeAccepted = true }))
    }

    #if DEBUG
        /// Clears the store's overrides and keeps the wall down this session.
        private func releaseDebugWall() {
            store.releaseDebugWall()
            debugWallReleased = true
        }
    #endif
}

extension View {
    /// Presents the wall and the notice, and handles what is the same in every
    /// app: when the two sources are fetched again, which of the two views
    /// shows, and what is recorded when a notice closes.
    ///
    /// You draw both views. The package ships no wall, no sheet and no text,
    /// because those belong to your design system and differ between apps. It
    /// ships these ordering rules:
    ///
    /// - The wall covers everything, including tabs and onboarding, because a
    ///   walled build must not be usable and onboarding is use.
    /// - Two modals never stack. The notice gives way to another prompt, and
    ///   the wall never gives way.
    /// - Swiping the notice away counts as a decline, so the user cannot make
    ///   it repeat by swiping instead of tapping.
    /// - The sources are fetched again on foreground as well as at launch.
    ///
    /// Apply it to the app root and not to one screen. The wall has to cover
    /// everything, and the notice must not depend on a tab the user may never
    /// visit.
    ///
    /// Send analytics from the views you return. A `.task` inside your builder
    /// runs when the view appears, which is the event to count. A store that
    /// emitted on state change would count walls nobody saw.
    ///
    /// ```swift
    /// ContentView()
    ///     .appGate(
    ///         store,
    ///         hasCompletedOnboarding: hasOnboarded,
    ///         onNoticeDismissed: { version, accepted in
    ///             if !accepted { analytics.noticeDeclined(version) }
    ///         },
    ///         wall: { context in
    ///             UpdateWallView(debugDismiss: context.releaseDebugWall)
    ///                 .task { analytics.wallShown() }
    ///         },
    ///         notice: { context in
    ///             UpdateNoticeSheet(latest: context.version, onUpdate: context.accept)
    ///                 .task { analytics.noticeShown(context.version) }
    ///         }
    ///     )
    /// ```
    ///
    /// - Parameters:
    ///   - store: the gate. Use one per app. A second store over the same suite
    ///     writes the same keys, and the first store's views do not update.
    ///   - capturingScreenshots: a screenshot run is in progress. Suppresses
    ///     the wall and the notice. Either one appearing mid-capture corrupts
    ///     a locale × device run, and the damage shows only in the uploaded
    ///     screenshots.
    ///   - hasCompletedOnboarding: when `false`, suppresses the notice only.
    ///     Leave it at `true` if you have no onboarding.
    ///   - promptShownThisSession: another prompt has already used this
    ///     session's modal. Suppresses the notice only. Pass `true` when any
    ///     prompt of yours has shown, whichever one it was.
    ///   - noticePresentation: sheet or full screen. The wall is always full
    ///     screen.
    ///   - onNoticeDismissed: called when the user closes the notice, however
    ///     they close it. `accepted` is `true` when they accepted the update.
    ///     Not called when the gate withdraws the notice, which also records
    ///     nothing.
    ///   - wall: your blocking screen. Give it one button, which opens the App
    ///     Store. Any other way out defeats the wall.
    ///   - notice: your update prompt. Dismiss it yourself, and call
    ///     `context.accept()` first if the user accepted the update.
    public func appGate<Wall: View, Notice: View>(
        _ store: AppGateStore,
        capturingScreenshots: Bool = false,
        hasCompletedOnboarding: Bool = true,
        promptShownThisSession: Bool = false,
        noticePresentation: AppGateNoticePresentation = .sheet,
        onNoticeDismissed: ((String, Bool) -> Void)? = nil,
        @ViewBuilder wall: @escaping (AppGateWallContext) -> Wall,
        @ViewBuilder notice: @escaping (AppGateNoticeContext) -> Notice
    ) -> some View {
        modifier(
            AppGateModifier(
                store: store,
                capturingScreenshots: capturingScreenshots,
                hasCompletedOnboarding: hasCompletedOnboarding,
                promptShownThisSession: promptShownThisSession,
                noticePresentation: noticePresentation,
                onNoticeDismissed: onNoticeDismissed,
                wall: wall,
                notice: notice
            )
        )
    }
}

extension View {
    /// The wall's presentation.
    ///
    /// The binding is `.constant` on purpose, so nothing the user does can
    /// set it to `false`. The wall comes down when the config lowers the
    /// floor.
    ///
    /// macOS has no `fullScreenCover`, and macOS is not a supported platform.
    /// The macOS floor in `Package.swift` exists so `swift test` runs on the
    /// host. The sheet below only keeps this module compiling there.
    @ViewBuilder
    fileprivate func appGateWall<Wall: View>(
        isPresented: Bool,
        @ViewBuilder content: @escaping () -> Wall
    ) -> some View {
        #if os(iOS)
            fullScreenCover(isPresented: .constant(isPresented), content: content)
        #else
            sheet(isPresented: .constant(isPresented), content: content)
        #endif
    }

    /// The notice's presentation.
    ///
    /// Uses `item` and not `isPresented`. A swipe sets the item to `nil`, so
    /// the binding agrees with what is on screen. A read-only `isPresented`
    /// binding would still read `true` between the swipe and `onDismiss`
    /// recording the dismissal, and the sheet would present again.
    @ViewBuilder
    fileprivate func appGateNotice<Item: Identifiable, Notice: View>(
        _ style: AppGateNoticePresentation,
        item: Binding<Item?>,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping (Item) -> Notice
    ) -> some View {
        switch style {
        case .sheet:
            sheet(item: item, onDismiss: onDismiss, content: content)
        case .fullScreenCover:
            #if os(iOS)
                fullScreenCover(item: item, onDismiss: onDismiss, content: content)
            #else
                sheet(item: item, onDismiss: onDismiss, content: content)
            #endif
        }
    }
}
