import Foundation

/// Apple's public lookup. It reports the version that is downloadable right
/// now and the OS that build requires.
public enum AppStoreLookup {
    /// The lookup URL for an App Store id.
    ///
    /// Optional and not force-unwrapped, because the caller supplies the id
    /// and nothing in this package may trap. The store treats a `nil` URL as a
    /// source that never answers, which gates nothing.
    ///
    /// The URL has no `country` parameter. The default storefront reports the
    /// same marketing version as every other, and the notice only needs to
    /// know whether a newer version exists.
    public static func url(appStoreID: String) -> URL? {
        URL(string: "https://itunes.apple.com/lookup?id=\(appStoreID)")
    }

    /// The lookup envelope, reduced to the two fields the gate reads. Both are
    /// `Optional` for the same reason every config field is. A response with
    /// a different shape may have written the cached blob.
    struct Response: Decodable {
        struct Result: Decodable {
            let version: String?
            /// The OS the live build requires. This value can release a wall
            /// and can never raise one.
            ///
            /// Spelled with a lowercase `Os` because the lookup's JSON spells
            /// it that way and synthesized `Decodable` matches keys exactly.
            /// The package's own names for this value use `minimumOSVersion`.
            let minimumOsVersion: String?
        }
        let results: [Result]
    }
}
