#if DEBUG
    import AppGateClient
    import AppGateCore
    import SwiftUI

    /// A config host the diagnostics picker can point the fetch at.
    public struct AppGateConfigSource: Hashable, Sendable {
        /// The label the picker shows. You choose it, and it is not localized,
        /// because this screen is not compiled into a Release build.
        public let name: String
        /// The host, or `nil` for the live URL the store was created with.
        public let url: URL?

        public init(name: String, url: URL?) {
            self.name = name
            self.url = url
        }

        /// The live host, with the label you give it.
        public static func live(named name: String = "Live") -> AppGateConfigSource {
            AppGateConfigSource(name: name, url: nil)
        }
    }

    /// A screen that shows both remote inputs, the running version, the
    /// computed state, the dismissal and both cache ages, with switches that
    /// force the wall and the notice.
    ///
    /// The gate does nothing until a floor is raised, and by then the build is
    /// already shipped. This screen lets you exercise the wall and the notice
    /// before that.
    ///
    /// Pass it the store the app is using, and never a second store over the
    /// same suite. A second store writes the same keys, and the app does not
    /// show the change until the next relaunch.
    ///
    /// It uses the `Form` styling and tint it inherits. Every string is
    /// `verbatim`, so nothing here enters your string catalog. Put it behind
    /// your own developer menu.
    ///
    /// This whole type is inside `#if DEBUG`, so your call site must be too.
    public struct AppGateDiagnosticsView: View {
        private let store: AppGateStore
        private let configSources: [AppGateConfigSource]

        /// - Parameters:
        ///   - store: the store the app is using.
        ///   - configSources: the hosts the picker offers. The default is the
        ///     live host only. Add a dev host that you can redeploy without a
        ///     production release. Forcing a state skips the network, so it
        ///     does not test the fetch, the decode or the cache. Pointing the
        ///     store at a dev host tests all three.
        public init(
            store: AppGateStore,
            configSources: [AppGateConfigSource] = [.live()]
        ) {
            self.store = store
            self.configSources = configSources
        }

        public var body: some View {
            Form {
                verdict
                configSection
                lookupSection
                dismissalSection
                forceSection
            }
            .navigationTitle(Text(verbatim: "App gate"))
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
        }

        private var verdict: some View {
            Section {
                row("State", value: description(of: store.state), highlighted: store.state != .open)
                row("Running version", value: store.currentVersion)
                row("Running OS", value: store.osVersion)
                row("Diagnosis", value: description(of: store.diagnosis))
            } header: {
                Text(verbatim: "Verdict")
            } footer: {
                Text(
                    verbatim: """
                        The wall supersedes the notice, and both fail open: a source that is \
                        absent, malformed, or past its 24 h TTL gates nothing. A user is walled \
                        only when the config explicitly says so and the app could reach it.
                        """
                )
            }
        }

        private var configSection: some View {
            Section {
                // Show the host above the floor it served, so the screen says
                // where the floor came from when the store points at a dev host.
                row("URL", value: store.effectiveConfigURL.absoluteString, wrapping: true)
                row("min_supported", value: store.minSupported ?? "—")
                row("Fetched", value: age(store.cacheAge(.config)))

                if configSources.count > 1 {
                    Picker(selection: configSourceBinding) {
                        ForEach(configSources, id: \.self) { source in
                            Text(verbatim: source.name).tag(source.url)
                        }
                    } label: {
                        Text(verbatim: "Source")
                    }
                }

                // The only refresh control. It is here and not beside the force
                // switch, because refreshing reads the two sources and forcing
                // ignores them.
                Button {
                    Task { await store.refresh() }
                } label: {
                    Text(verbatim: "Refresh Both Sources Now")
                }
            } header: {
                Text(verbatim: "Config source")
            } footer: {
                Text(
                    verbatim: """
                        Forcing a state below skips the network entirely, so it proves nothing \
                        about the fetch, the decode or the cache. Pointing at another host \
                        exercises the real path — same refresh, same decoder, same cache keys. \
                        Switching source discards the cached config, so the floor you see always \
                        came from the URL above it.
                        """
                )
            }
        }

        private var lookupSection: some View {
            Section {
                row("Latest on the App Store", value: store.latestVersion ?? "—")
                row("Minimum OS for it", value: store.minimumOSVersion ?? "—")
                row("Fetched", value: age(store.cacheAge(.lookup)))
            } header: {
                Text(verbatim: "Lookup · itunes.apple.com")
            } footer: {
                Text(
                    verbatim: """
                        The lookup can only ever release a gate, never raise one. If it says this \
                        OS cannot install the newer build, the wall comes down — nudging someone \
                        toward a binary they cannot install is worse than silence.
                        """
                )
            }
        }

        private var dismissalSection: some View {
            Section {
                row("Dismissed version", value: store.dismissedVersion ?? "—")
                Button(role: .destructive) {
                    store.debugClearDismissal()
                } label: {
                    Text(verbatim: "Clear Dismissal")
                }
                .disabled(store.dismissedVersion == nil)
            } header: {
                Text(verbatim: "Notice dismissal")
            } footer: {
                Text(
                    verbatim: """
                        Declining writes the announced version here and that version never asks \
                        again; its successor does. Clearing it re-arms the notice.
                        """
                )
            }
        }

        private var forceSection: some View {
            Section {
                Picker(selection: forcedStateBinding) {
                    Text(verbatim: "Off (live sources)").tag(AppGateStore.DebugForcedState?.none)
                    ForEach(AppGateStore.DebugForcedState.allCases, id: \.rawValue) { forced in
                        Text(verbatim: forced.rawValue).tag(Optional(forced))
                    }
                } label: {
                    Text(verbatim: "Force State")
                }
            } header: {
                Text(verbatim: "Force (DEBUG)")
            } footer: {
                Text(
                    verbatim: """
                        Forcing takes effect immediately — the wall covers the app from wherever \
                        you are, including this screen. Pick "blocked" to verify the wall renders, \
                        and "notice" to verify the nudge and its dismissal. Whatever your wall \
                        wires `releaseDebugWall` to is the way back here, and it sets this picker \
                        to Off for you. A Release build has neither.
                        """
                )
            }
        }

        // MARK: - Bindings

        /// Writes through the store's setter and not the defaults key. Switching
        /// host has to discard the cached config. Otherwise the next read
        /// returns the previous host's floor while this screen names the new
        /// host.
        private var configSourceBinding: Binding<URL?> {
            Binding(get: { store.debugConfigURL }, set: { store.setDebugConfigURL($0) })
        }

        private var forcedStateBinding: Binding<AppGateStore.DebugForcedState?> {
            Binding(get: { store.debugForcedState }, set: { store.setDebugForcedState($0) })
        }

        // MARK: - Rendering

        private func row(
            _ title: String,
            value: String,
            highlighted: Bool = false,
            wrapping: Bool = false
        ) -> some View {
            LabeledContent {
                Text(verbatim: value)
                    .foregroundStyle(highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .monospaced()
                    // Wrap a URL and never truncate it. Two hosts can share a
                    // prefix.
                    .font(wrapping ? .caption2 : nil)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(wrapping ? 3 : 1)
            } label: {
                Text(verbatim: title)
            }
        }

        private func description(of state: GateState) -> String {
            switch state {
            case .open: "open"
            case .blocked: "wall"
            case .notice(let latest): "notice · \(latest.description)"
            }
        }

        /// Gives each case its own text, because the diagnosis exists to tell
        /// "no floor applied" apart from "a floor applied and was released".
        private func description(of diagnosis: GateDiagnosis) -> String {
            switch diagnosis {
            case .currentVersionUnparseable: "running version unparseable"
            case .noGateApplies: "no gate applies"
            case .belowMinimumSupported(let floor): "below floor \(floor.description)"
            case .newerVersionAvailable(let latest): "newer: \(latest.description)"
            case .newerVersionDismissed(let latest): "newer dismissed: \(latest.description)"
            case .releasedOSCannotInstall(let released, let minimum):
                "released \(description(of: released)) · needs OS \(minimum.description)"
            case .suppressed(let released, let reason):
                "suppressed \(description(of: released)) · \(description(of: reason))"
            }
        }

        private func description(of reason: SuppressionReason) -> String {
            switch reason {
            case .capturingScreenshots: "screenshot run"
            case .onboardingIncomplete: "onboarding"
            case .promptShownThisSession: "prompt this session"
            }
        }

        /// A cache age in whole minutes, hours or days. The screen shows how
        /// stale a cache is, not the exact time it was written.
        private func age(_ interval: TimeInterval?) -> String {
            guard let interval else { return "never" }
            let minutes = Int(interval / 60)
            if minutes < 1 { return "just now" }
            if minutes < 60 { return "\(minutes) min ago" }
            let hours = minutes / 60
            return hours < 48 ? "\(hours) h ago" : "\(hours / 24) d ago"
        }
    }
#endif
