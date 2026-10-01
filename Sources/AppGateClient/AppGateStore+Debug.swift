#if DEBUG
    import AppGateCore
    import Foundation

    /// The developer overrides. None of this is compiled into a Release binary,
    /// so a shipped build contains no override and no alternate host.
    ///
    /// The overrides exist because the gate does nothing until a floor is
    /// raised, so without them nobody exercises it before then.
    extension AppGateStore {

        public enum DebugForcedState: String, CaseIterable, Sendable {
            case open
            case notice
            case blocked
        }

        /// Forces the gate into a state. Pass `nil` to return to the state the
        /// two sources produce. Recomputes immediately, so the change shows
        /// without a relaunch.
        public func setDebugForcedState(_ forced: DebugForcedState?) {
            if let forced {
                defaults?.set(forced.rawValue, forKey: key("debugForcedState"))
            } else {
                defaults?.removeObject(forKey: key("debugForcedState"))
            }
            debugForcedState = forced
            recompute()
        }

        /// Points the config fetch at `url`. Pass `nil` to return to the live
        /// URL.
        ///
        /// Changing the host discards the cached config, which is why this is
        /// a method and not a plain setter. The cache stores the body and not
        /// which host served it. If the switch kept the cache, the next read
        /// would return the previous host's floor while the screen named the
        /// new host.
        ///
        /// Returning to live clears the cache too. Otherwise "live" would show
        /// a floor that production never served.
        public func setDebugConfigURL(_ url: URL?) {
            guard url != debugConfigURL else { return }
            if let url {
                defaults?.set(url.absoluteString, forKey: key("debugConfigURL"))
            } else {
                defaults?.removeObject(forKey: key("debugConfigURL"))
            }
            debugConfigURL = url
            clearCache(.config)
            recompute()
        }

        /// Clears the persisted dismissal, so a notice can show again.
        public func debugClearDismissal() {
            defaults?.removeObject(forKey: key("dismissedVersion"))
            dismissedVersion = nil
            recompute()
        }

        /// Takes down a wall that the diagnostics screen raised.
        ///
        /// A forced wall, or a wall served by a dev host, persists across
        /// relaunches. The control that set it is behind the wall, so without
        /// this method nothing can reach that control.
        ///
        /// Put a control on your DEBUG wall that calls this. You choose the
        /// control. A hidden gesture keeps the wall looking like the shipping
        /// one. A labelled button cannot be mistaken for the shipping wall in a
        /// screenshot, which matters in a build that takes store screenshots.
        ///
        /// It clears the forced state and returns to the live host, because
        /// either one can be the cause of the wall.
        public func releaseDebugWall() {
            setDebugForcedState(nil)
            setDebugConfigURL(nil)
        }

        /// Turns a forced state into a decision. A forced notice needs a
        /// version to announce. It uses the looked-up version if that is newer,
        /// and otherwise the running version with its last component raised by
        /// one.
        func forced(_ forced: DebugForcedState) -> GateDecision {
            switch forced {
            case .open:
                return GateDecision(state: .open, diagnosis: .noGateApplies)
            case .blocked:
                // With no floor to name, keep the wall and report no floor. The
                // diagnostics screen is testing the state, and inventing a
                // floor would need a force-unwrap.
                guard let floor = AppVersion(minSupported ?? "") ?? debugNoticeVersion else {
                    return GateDecision(state: .blocked, diagnosis: .noGateApplies)
                }
                return GateDecision(
                    state: .blocked, diagnosis: .belowMinimumSupported(floor: floor)
                )
            case .notice:
                // A notice has to announce a version. With an unparseable
                // running version and no lookup there is none, and inventing
                // one would need a force-unwrap, so the gate opens.
                guard let latest = debugNoticeVersion else {
                    return GateDecision(state: .open, diagnosis: .noGateApplies)
                }
                return GateDecision(
                    state: .notice(latest: latest),
                    diagnosis: .newerVersionAvailable(latest: latest)
                )
            }
        }

        /// The version a forced notice announces, or `nil` when the running
        /// version does not parse. Nothing in this package may trap, and a
        /// diagnostics screen is where an unparseable running version appears.
        private var debugNoticeVersion: AppVersion? {
            guard let running = AppVersion(currentVersion) else { return nil }
            if let latestVersion, let latest = AppVersion(latestVersion), running < latest {
                return latest
            }
            var components = running.components
            // `+= 1` traps on Int.max, and the caller supplies the running
            // version, so "1.9223372036854775807" can reach here. A version
            // that cannot be raised announces itself.
            let (bumped, overflowed) = components[components.count - 1].addingReportingOverflow(1)
            guard !overflowed else { return running }
            components[components.count - 1] = bumped
            return AppVersion(components.map(String.init).joined(separator: ".")) ?? running
        }
    }
#endif
