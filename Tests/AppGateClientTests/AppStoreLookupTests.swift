import Foundation
import Testing

@testable import AppGateClient

struct AppStoreLookupTests {
    @Test("the lookup URL derives from the id")
    func urlDerivesFromID() throws {
        let url = try #require(AppStoreLookup.url(appStoreID: "123456789"))
        #expect(url.absoluteString == "https://itunes.apple.com/lookup?id=123456789")
    }

    @Test("the lookup envelope decodes both fields this reads")
    func envelopeDecodes() throws {
        let json = """
            {"resultCount":1,
             "results":[{"version":"1.5.0","minimumOsVersion":"26.0","trackName":"ignored"}]}
            """
        let decoded = try JSONDecoder().decode(AppStoreLookup.Response.self, from: Data(json.utf8))
        #expect(decoded.results.first?.version == "1.5.0")
        #expect(decoded.results.first?.minimumOsVersion == "26.0")
    }

    @Test("an unknown id answers an empty results array, which carries no version")
    func emptyResults() throws {
        let decoded = try JSONDecoder().decode(
            AppStoreLookup.Response.self, from: Data(#"{"resultCount":0,"results":[]}"#.utf8)
        )
        #expect(decoded.results.isEmpty)
    }

    @Test("a result missing minimumOsVersion decodes, with nil")
    func missingMinimumOSDecodes() throws {
        let decoded = try JSONDecoder().decode(
            AppStoreLookup.Response.self, from: Data(#"{"results":[{"version":"1.5.0"}]}"#.utf8)
        )
        #expect(decoded.results.first?.version == "1.5.0")
        #expect(decoded.results.first?.minimumOsVersion == nil)
    }
}
