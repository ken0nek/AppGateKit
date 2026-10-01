import Foundation
import Testing

@testable import AppGateCore

struct AppGateConfigTests {
    private func decode(_ json: String) throws -> AppGateConfig {
        try JSONDecoder().decode(AppGateConfig.self, from: Data(json.utf8))
    }

    @Test("the documented envelope decodes")
    func decodesTheContract() throws {
        let config = try decode(#"{"min_supported":"1.3.0","feature_floors":{"share":"2.2.0"}}"#)
        #expect(config.minSupported == "1.3.0")
        #expect(config.featureFloors == ["share": "2.2.0"])
    }

    @Test("an unknown field is ignored, so a future field cannot break an old build")
    func ignoresUnknownFields() throws {
        let config = try decode(
            #"{"min_supported":"1.3.0","maintenance":{"until":"2030-01-01T00:00:00Z"}}"#)
        #expect(config.minSupported == "1.3.0")
    }

    @Test("an absent field decodes to nil, so a cached blob of another shape survives")
    func absentFieldsSurvive() throws {
        let empty = try decode("{}")
        #expect(empty.minSupported == nil)
        #expect(empty.featureFloors == nil)
    }

    @Test("a feature with no floor is never blocked")
    func noFloorNeverBlocks() {
        let config = AppGateConfig(minSupported: "1.0.0")
        #expect(config.floor(for: "share") == nil)
        #expect(config.isBlocked(feature: "share", current: "1.0.0") == false)
    }

    @Test("a feature floor blocks only a build strictly below it")
    func floorBlocksBelow() throws {
        let config = AppGateConfig(featureFloors: ["share": "2.2.0"])
        let floor = try #require(AppVersion("2.2.0"))
        #expect(config.floor(for: "share") == floor)
        #expect(config.isBlocked(feature: "share", current: "2.1.9"))
        #expect(config.isBlocked(feature: "share", current: "2.2") == false)
        #expect(config.isBlocked(feature: "share", current: "2.3.0") == false)
    }

    @Test("an unparseable floor or running version blocks nothing")
    func unparseableFailsOpen() {
        #expect(
            AppGateConfig(featureFloors: ["share": "2.x"]).isBlocked(
                feature: "share", current: "1.0.0") == false)
        #expect(
            AppGateConfig(featureFloors: ["share": "2.0.0"]).isBlocked(
                feature: "share", current: "") == false)
    }
}
