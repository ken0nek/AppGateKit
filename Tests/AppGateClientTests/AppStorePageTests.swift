import Foundation
import Testing

@testable import AppGateClient

struct AppStorePageTests {
    @Test("the product URL derives from the id, with no country code")
    func productURLDerivesFromID() throws {
        let url = try #require(AppStorePage.productURL(appStoreID: "123456789"))
        #expect(url.absoluteString == "https://apps.apple.com/app/id123456789")
    }

    /// `URL(string:)` percent-encodes a malformed id and does not fail, so the
    /// result is a wrong path on the right host and not `nil`. This test checks
    /// the host, because the host is what matters if an id ever comes from
    /// somewhere other than a constant.
    @Test(
        "a ragged id cannot move the URL off the App Store",
        arguments: ["1 2", "1/2", "1?x=y", "1#frag", "../../elsewhere", "1@elsewhere.example", ""]
    )
    func raggedIDStaysOnTheStore(id: String) throws {
        let url = try #require(AppStorePage.productURL(appStoreID: id))
        #expect(url.host() == "apps.apple.com")
        #expect(url.scheme == "https")
    }

    @Test("the two App Store URLs share the id and nothing else")
    func lookupAndProductShareTheID() throws {
        let product = try #require(AppStorePage.productURL(appStoreID: "987654321"))
        let lookup = try #require(AppStoreLookup.url(appStoreID: "987654321"))
        #expect(product.absoluteString.contains("987654321"))
        #expect(lookup.absoluteString.contains("987654321"))
        #expect(product.host() != lookup.host())
    }
}
