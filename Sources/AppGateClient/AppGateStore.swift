import AppGateCore
import Foundation
import Observation

/// The gate's client. It owns both fetches, both last-good caches and the
/// dismissal, and publishes one ``GateDecision`` for the app root to render.
///
/// Every path fails open. A network error, a non-200, a malformed body, an
/// absent cache and a cache past its TTL all read as "that source is absent",
/// and an absent source gates nothing. A failed refresh never overwrites a
/// good cache. It leaves the existing cache to expire on its own TTL.
///
/// ``AppGateCore/AppGate`` makes the decision. This class does not repeat any
/// precedence or version-comparison logic.
///
/// The store emits no analytics. A store that emitted on state change would
/// count walls nobody saw. Fire signals from the presenting layer, when a view
/// appears.
///
/// The store applies no suppression. It publishes the unsuppressed state, and
/// the host calls `suppressed(...)` on the decision in the presenting layer,
/// which is the only place that knows what else is on screen.
@MainActor
@Observable
public final class AppGateStore {

    /// Which of the two sources a caller is asking about.
    public enum Source: Sendable {
        case config
        case lookup
    }

    /// What to show right now, and which input decided it. `init` seeds it
    /// synchronously from the caches, so a cold launch has a value before any
    /// fetch returns.
    public private(set) var decision: GateDecision = .open

    public var state: GateState { decision.state }
    public var diagnosis: GateDiagnosis { decision.diagnosis }

    /// The floor currently in force, or `nil` when the config is absent or its
    /// cache has expired. Published for a diagnostics screen and for a host's
    /// analytics payload, because ``GateState`` does not carry it.
    public private(set) var minSupported: String?
    /// The per-feature floors from the same config, `nil` under the same
    /// conditions.
    public private(set) var featureFloors: [String: String]?
    /// The App Store's version at the last good lookup, or `nil` when the
    /// lookup is absent or its cache has expired.
    public private(set) var latestVersion: String?
    /// The OS that version requires, from the same lookup.
    public private(set) var minimumOSVersion: String?
    /// An observed copy of the persisted dismissal, so dismissing updates the
    /// UI. SwiftUI does not observe a `UserDefaults` read.
    ///
    /// `internal(set)` and not `private(set)`, because the DEBUG extension
    /// that clears it is in another file.
    public internal(set) var dismissedVersion: String?

    /// This build's marketing version, as the gate sees it.
    public let currentVersion: String
    /// The OS this build is running on, as the gate sees it.
    public let osVersion: String

    @ObservationIgnored let configURL: URL
    @ObservationIgnored let lookupURL: URL?
    @ObservationIgnored let defaults: UserDefaults?
    @ObservationIgnored let keyPrefix: String
    @ObservationIgnored let fetch: AppGateFetching
    @ObservationIgnored let now: @Sendable () -> Date

    #if DEBUG
        // Both DEBUG switches are stored copies of their defaults keys and not
        // computed reads. `@Observable` tracks stored properties only, so
        // SwiftUI cannot see a computed `UserDefaults` getter. The control
        // would write the value and then show its old value again.
        // `dismissedVersion` is a stored copy for the same reason.

        // `internal(set)` and not `private(set)`, because the methods that
        // write them are in `AppGateStore+Debug.swift`.

        /// The state a diagnostics screen is holding the gate in, if any.
        public internal(set) var debugForcedState: DebugForcedState?

        /// The host the config fetch is pointed at, or `nil` for live.
        public internal(set) var debugConfigURL: URL?
    #endif

    /// Last-good caches last one day. After that, an unreachable source reads
    /// as absent, so the store stops enforcing a rule it can no longer
    /// confirm. A raised floor therefore cannot outlast the site that served
    /// it by more than a day.
    public static let cacheTTL: TimeInterval = 24 * 60 * 60

    /// How old a cache may be before a foreground refresh fetches again.
    /// Shorter than the TTL, because iOS suspends apps for days instead of
    /// cold-launching them. Refreshing only at launch would deliver a raised
    /// floor last to the long-running installs a wall is aimed at.
    public static let foregroundRefreshInterval: TimeInterval = 6 * 60 * 60

    /// - Parameters:
    ///   - configURL: the config endpoint. It is compiled into the binary, and
    ///     a shipped build cannot be told to look elsewhere. This path must
    ///     stay served for as long as any build that uses it is installed.
    ///   - appStoreID: the App Store id the lookup URL is built from.
    ///   - currentVersion: this build's marketing version.
    ///   - osVersion: the OS this build is running on.
    ///   - defaults: where the caches and the dismissal are stored. Pass an App
    ///     Group suite so extensions read the same gate.
    ///   - keyPrefix: a prefix for every key, so the package's keys cannot
    ///     collide with the host's.
    ///   - fetch: the transport. A test injects one so it needs no network.
    ///   - now: the clock. A test injects one so it controls time.
    public init(
        configURL: URL,
        appStoreID: String,
        currentVersion: String = AppGateStore.bundleVersion,
        osVersion: String = AppGateStore.runningOSVersion,
        defaults: UserDefaults? = .standard,
        keyPrefix: String = "AppGate.",
        fetch: @escaping AppGateFetching = AppGateStore.liveFetch(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.configURL = configURL
        self.lookupURL = AppStoreLookup.url(appStoreID: appStoreID)
        self.currentVersion = currentVersion
        self.osVersion = osVersion
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.fetch = fetch
        self.now = now
        #if DEBUG
            debugForcedState =
                defaults?
                .string(forKey: key("debugForcedState"))
                .flatMap(DebugForcedState.init(rawValue:))
            debugConfigURL =
                defaults?
                .string(forKey: key("debugConfigURL"))
                .flatMap(URL.init(string:))
        #endif
        recompute()
    }

    deinit {
        // The only cancellation the package makes. A refresh may outlive its
        // caller on purpose. A refresh that outlives the store has two live
        // requests and nothing to deliver them to.
        inFlight?.cancel()
    }

    /// This binary's marketing version. An absent or malformed `Info.plist`
    /// yields `""`, which does not parse, so the gate stays open.
    public static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// The running OS, dotted.
    public static var runningOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The age of a cache, or `nil` when it has never been written. A
    /// diagnostics screen displays this.
    public func cacheAge(_ source: Source) -> TimeInterval? {
        cachedAt(stampKey(source)).map { now().timeIntervalSince($0) }
    }

    // MARK: - Refresh

    /// The refresh currently running, if any. Two overlapping refreshes can
    /// finish out of order, and the later write gets a current timestamp. A
    /// floor the server has already dropped would then be restored for another
    /// full TTL. This happens at cold launch, where iOS also delivers an
    /// activation and the host calls both `refresh()` and `refreshIfStale()`.
    @ObservationIgnored private var inFlight: Task<Void, Never>?

    /// Fetches both sources and recomputes. Never throws. On any failure the
    /// last-good cache stays in use. Call at cold launch.
    ///
    /// The two fetches run concurrently, so a slow source does not delay the
    /// other.
    ///
    /// A second caller awaits the refresh already running and does not start
    /// its own. The check-and-set is safe because this class is `@MainActor`.
    ///
    /// Cancelling the caller does not cancel the refresh. The intended call
    /// site is a view's `.task`, and the server may have just raised a floor
    /// when that view goes away. A fetch that started should finish and write
    /// its cache. Releasing the store is the one case that cancels. See
    /// `deinit`.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            await self?.performRefresh()
            self?.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func performRefresh() async {
        // Copy to locals so the child tasks capture values and not the
        // actor-isolated store. That keeps the first `async let` off this
        // actor. The second also needs its callee marked `nonisolated`,
        // because a static member of a `@MainActor` class inherits the
        // isolation and would queue the lookup behind the main actor.
        let fetch = self.fetch
        let effective = effectiveConfigURL
        let lookupURL = self.lookupURL

        async let configResponse = fetch(effective)
        async let lookupResponse = Self.fetchIfPossible(lookupURL, using: fetch)
        let (config, lookup) = await (configResponse, lookupResponse)

        // Each write has its own guard, so a source that did not answer never
        // overwrites a good cache. That cache expires on its own TTL.
        //
        // A DEBUG switch may have changed the config host while this was in
        // flight. The cache stores the body and not which host served it, so a
        // body fetched from the previous host must not be written as the new
        // host's. `setDebugConfigURL` clears the cache for the same reason.
        if effective == effectiveConfigURL, let body = Self.validConfigBody(config) {
            writeCache(.config, body: body)
        }
        if let body = Self.validLookupBody(lookup) {
            writeCache(.lookup, body: body)
        }

        recompute()
    }

    /// Refreshes only if either source is older than
    /// ``foregroundRefreshInterval``. Call it on every foreground activation.
    public func refreshIfStale() async {
        guard isStale else {
            // Still recompute, because a cache can expire without a fetch.
            recompute()
            return
        }
        await refresh()
    }

    /// Whether either source is older than the foreground refresh interval or
    /// has never been fetched. A source that has never answered has no
    /// timestamp, so it is always stale and every activation retries it.
    public var isStale: Bool {
        [Source.config, .lookup].contains { source in
            guard let age = cacheAge(source) else { return true }
            // A negative age is a timestamp in the future. Treat it as stale,
            // as the TTL check does.
            return age < 0 || age >= Self.foregroundRefreshInterval
        }
    }

    /// `nonisolated` is required. A global actor on a type also covers its
    /// static members, so without it this helper is `@MainActor`. The lookup's
    /// child task would then wait for the main actor before it could send its
    /// request, and under the Swift 7 default would run the fetch there.
    nonisolated private static func fetchIfPossible(
        _ url: URL?, using fetch: AppGateFetching
    ) async -> AppGateResponse? {
        guard let url else { return nil }
        return await fetch(url)
    }

    /// The config URL the store fetches from. A diagnostics screen displays
    /// it, so the screen shows which host served the floor.
    ///
    /// In Release this is always the injected URL. The `#if DEBUG` branch is
    /// not compiled into a shipped binary, so the binary contains no override
    /// and no alternate host.
    public var effectiveConfigURL: URL {
        #if DEBUG
            return debugConfigURL ?? configURL
        #else
            return configURL
        #endif
    }

    // MARK: - Dismissal

    /// Records that the user dismissed `version`. The notice does not show
    /// again for that version. It shows again for a later one.
    public func dismiss(version: AppVersion) {
        defaults?.set(version.description, forKey: key("dismissedVersion"))
        dismissedVersion = version.description
        recompute()
    }

    /// Dismisses the version the current notice announces, if the state is a
    /// notice. The caller does not need to know which version that is.
    public func dismissCurrentNotice() {
        guard case .notice(let latest) = decision.state else { return }
        dismiss(version: latest)
    }

    // MARK: - Feature floors

    /// The floor for `feature`, or `nil` when there is none, it does not parse,
    /// or the config cache has expired.
    public func floor(for feature: String) -> AppVersion? {
        currentConfig.floor(for: feature)
    }

    /// Whether this build is below the floor for `feature`. Returns `false` on
    /// every input that would also leave the wall down.
    public func isBlocked(feature: String) -> Bool {
        currentConfig.isBlocked(feature: feature, current: currentVersion)
    }

    private var currentConfig: AppGateConfig {
        AppGateConfig(minSupported: minSupported, featureFloors: featureFloors)
    }

    // MARK: - Wire validation

    /// The body, only if the response was a 200 that decoded as the config
    /// envelope. Anything else returns `nil` and leaves the cache alone. The
    /// store caches the received bytes and not a re-encoding of the decoded
    /// value, so fields this build does not know are kept.
    private static func validConfigBody(_ response: AppGateResponse?) -> Data? {
        guard let response, response.statusCode == 200,
            (try? JSONDecoder().decode(AppGateConfig.self, from: response.data)) != nil
        else {
            return nil
        }
        return response.data
    }

    /// The body, only from a 200 whose first result has a non-empty version.
    /// The lookup returns an empty `results` array for an unknown id, which
    /// gives no version and so no notice.
    private static func validLookupBody(_ response: AppGateResponse?) -> Data? {
        guard let response, response.statusCode == 200,
            let decoded = try? JSONDecoder()
                .decode(AppStoreLookup.Response.self, from: response.data),
            let version = decoded.results.first?.version, !version.isEmpty
        else {
            return nil
        }
        return response.data
    }

    // MARK: - Transport

    /// The production fetcher. It uses an ephemeral session, with no cookie
    /// jar and no on-disk cache, and a short timeout. Neither request carries
    /// anything about the user. One asks the host's own site for a version
    /// floor, and the other asks Apple about a public App Store id.
    public static func liveFetch(timeout: TimeInterval = 5) -> AppGateFetching {
        { url in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                let http = response as? HTTPURLResponse
            else {
                return nil
            }
            return AppGateResponse(data: data, statusCode: http.statusCode)
        }
    }

    // MARK: - Recompute

    /// Recomputes the decision from the two caches and applies both TTLs.
    /// Synchronous, so `init` and every mutation use the same path.
    func recompute() {
        let config = cachedConfig()
        minSupported = config?.minSupported
        featureFloors = config?.featureFloors

        let result = cachedLookup()
        latestVersion = result?.version
        minimumOSVersion = result?.minimumOsVersion

        // Re-read the dismissal only when there is a suite to read from. With
        // a nil suite, which a failed App Group initializer produces, the read
        // would erase a dismissal made earlier on this call stack, and the
        // notice would present again after every dismissal.
        if let defaults {
            dismissedVersion = defaults.string(forKey: key("dismissedVersion"))
        }

        let evaluated = AppGate.evaluate(
            minSupported: minSupported,
            latest: latestVersion,
            current: currentVersion,
            dismissedVersion: dismissedVersion,
            osVersion: osVersion,
            minimumOSVersion: minimumOSVersion
        )
        #if DEBUG
            decision = debugForcedState.map(forced(_:)) ?? evaluated
        #else
            decision = evaluated
        #endif
    }

    // MARK: - Cache

    func key(_ suffix: String) -> String { keyPrefix + suffix }

    private func bodyKey(_ source: Source) -> String {
        key(source == .config ? "config" : "lookup")
    }

    private func stampKey(_ source: Source) -> String {
        key(source == .config ? "configCachedAt" : "lookupCachedAt")
    }

    /// The cached config, or `nil` if the cache is absent, past its TTL, or no
    /// longer decodes. A different build may have written the cache, so this
    /// decodes it again on every read.
    private func cachedConfig() -> AppGateConfig? {
        guard isFresh(.config), let data = defaults?.data(forKey: bodyKey(.config)) else {
            return nil
        }
        return try? JSONDecoder().decode(AppGateConfig.self, from: data)
    }

    private func cachedLookup() -> AppStoreLookup.Response.Result? {
        guard isFresh(.lookup), let data = defaults?.data(forKey: bodyKey(.lookup)) else {
            return nil
        }
        return try? JSONDecoder().decode(AppStoreLookup.Response.self, from: data).results.first
    }

    func cachedAt(_ key: String) -> Date? {
        guard let defaults, defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    private func isFresh(_ source: Source) -> Bool {
        guard let cachedAt = cachedAt(stampKey(source)) else { return false }
        let age = now().timeIntervalSince(cachedAt)
        // A negative age means the timestamp is in the future, because the
        // clock moved backwards or was ahead when the value was written. Treat
        // it as expired. A cache that never expires could keep a wall up
        // permanently.
        return age >= 0 && age < Self.cacheTTL
    }

    func writeCache(_ source: Source, body: Data) {
        defaults?.set(body, forKey: bodyKey(source))
        defaults?.set(now().timeIntervalSince1970, forKey: stampKey(source))
    }

    func clearCache(_ source: Source) {
        defaults?.removeObject(forKey: bodyKey(source))
        defaults?.removeObject(forKey: stampKey(source))
    }
}
