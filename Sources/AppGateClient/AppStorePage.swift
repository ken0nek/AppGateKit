import Foundation

/// URLs for App Store pages, built from an id. Nothing here fetches.
///
/// ``AppStoreLookup`` builds the endpoint the gate reads. This type builds the
/// page the app sends people to. The two share only the id.
public enum AppStorePage {
    /// The product page. The wall's button and the notice's update button
    /// both open it.
    ///
    /// The URL has no country code. The path redirects to the viewer's own
    /// storefront, and a fixed country code would send everyone to one store.
    ///
    /// Optional because `URL(string:)` is, and this package force-unwraps
    /// nothing. `URL(string:)` percent-encodes a malformed id, so the result
    /// is a wrong path on the right host and not `nil`. Store the result in a
    /// constant of your own. Do not unwrap it in the button's action, where a
    /// `nil` would leave the button with nothing to open.
    ///
    /// If your server already supplies a store URL, use that. This is for the
    /// case where you have only the id.
    public static func productURL(appStoreID: String) -> URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)")
    }
}
