import Testing

@testable import AppGateCore

struct AppVersionTests {
    @Test("2.10.0 is newer than 2.1.0, and newer than 2.9.0")
    func dottedNumericCompare() throws {
        let ten = try #require(AppVersion("2.10.0"))
        #expect(try #require(AppVersion("2.1.0")) < ten)
        #expect(try #require(AppVersion("2.9.0")) < ten)
        // A plain string compare gets this pair backwards. "2.10.0" sorts
        // before "2.9.0" as text, because "1" < "9".
        #expect("2.10.0" < "2.9.0")
    }

    @Test("trailing zeros do not matter, so 2.1 equals 2.1.0")
    func zeroPadding() throws {
        let short = try #require(AppVersion("2.1"))
        let long = try #require(AppVersion("2.1.0"))
        #expect(short == long)
        #expect(!(short < long))
        #expect(!(long < short))
    }

    @Test("padding is not truncation: 2.1 is below a 2.1.3 floor")
    func shorterIsLessAgainstANonZeroTail() throws {
        let short = try #require(AppVersion("2.1"))
        let long = try #require(AppVersion("2.1.3"))
        // A build can ship with the marketing version `2.1`. Comparing only
        // the shared components would treat it as equal to a 2.1.3 floor, and
        // the floor would not wall it.
        #expect(short < long)
        #expect(long > short)
    }

    @Test("a single component parses")
    func singleComponent() throws {
        #expect(try #require(AppVersion("2")) == #require(AppVersion("2.0.0")))
    }

    @Test(
        "strict parse rejects anything that is not dot-separated ASCII digits",
        arguments: [
            "2.x", "", "1.2.3-beta", "2.", "2..0", ".2", "+1", "-1", " 1", "1 ",
            "2.０", "99999999999999999999",
        ]
    )
    func rejects(_ input: String) {
        #expect(AppVersion(input) == nil)
    }

    @Test("description round-trips, which is what a dismissal persists")
    func descriptionRoundTrips() throws {
        #expect(try #require(AppVersion("1.4")).description == "1.4")
        #expect(try #require(AppVersion("10.0.3")).description == "10.0.3")
    }
}
