import Foundation

/// The remote config, served at a URL that every shipped build has compiled
/// in.
///
///     { "min_supported": "1.3.0",
///       "feature_floors": { "share": "2.2.0" } }
///
/// Four rules follow from that fixed URL.
///
/// 1. Every field is `Optional`, on the server and in this type, permanently.
///    A shipped build has to decode a cached blob that a different shape
///    wrote. Synthesized `Decodable` ignores property defaults, so only an
///    `Optional` survives a missing field.
/// 2. Unknown fields are ignored, so a field added later cannot break an older
///    build's decode. This type ignores them by not declaring them.
/// 3. The config carries no user-facing text. A string here could only be in
///    one language, so every user-facing word stays in the app's string
///    catalog.
/// 4. `maintenance` is reserved and unread. No other field may take the name.
///    When it is added, its shape will be machine-readable only,
///    `{"until": "<ISO8601>"}`. The app then renders the time in the viewer's
///    locale, and the config still carries no prose.
public struct AppGateConfig: Decodable, Equatable, Sendable {
    /// The floor below which a build must not run. `nil` means no floor and so
    /// no wall.
    public let minSupported: String?
    /// Per-feature floors, keyed by a name the app and the config agree on. A
    /// dictionary and not named fields, because feature names belong to the
    /// app.
    public let featureFloors: [String: String]?

    enum CodingKeys: String, CodingKey {
        case minSupported = "min_supported"
        case featureFloors = "feature_floors"
    }

    public init(minSupported: String? = nil, featureFloors: [String: String]? = nil) {
        self.minSupported = minSupported
        self.featureFloors = featureFloors
    }

    /// The floor for `feature`, or `nil` when there is none or it does not
    /// parse. Either way the feature is not gated.
    public func floor(for feature: String) -> AppVersion? {
        featureFloors?[feature].flatMap(AppVersion.init)
    }

    /// Whether `current` is below the floor for `feature`. Returns `false`
    /// when there is no floor, the floor does not parse, or the running
    /// version does not parse.
    public func isBlocked(feature: String, current: String) -> Bool {
        guard let floor = floor(for: feature), let running = AppVersion(current) else {
            return false
        }
        return running < floor
    }
}
