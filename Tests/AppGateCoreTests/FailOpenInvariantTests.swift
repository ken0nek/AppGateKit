import Testing

@testable import AppGateCore

/// Tests the fail-open rule over every combination of inputs. A wall requires
/// a parseable floor strictly above a parseable running version, and every
/// other combination resolves to no gate.
///
/// The named cases in `AppGateEvaluatorTests` explain why each rule exists.
/// This suite checks that no input outside those cases raises a wall.
/// Hand-picked cases alone leave some mutants of the evaluator undetected, and
/// the full sweep detects them.
struct FailOpenInvariantTests {

    /// A version string and whether the parser must accept it. The flag is
    /// written by hand. Computing it by calling `AppVersion` would only show
    /// that the evaluator agrees with its own dependency.
    ///
    /// Copied by hand from `AppVersionTests.swift`. Keep the two in step.
    struct Sample {
        let text: String
        let parses: Bool
    }

    /// Well-formed and malformed strings. `"2.０"` contains a full-width zero
    /// (U+FF10), and `"99999999999999999999"` overflows `Int`. Neither is a
    /// typo.
    static let corpus: [Sample] = [
        Sample(text: "0", parses: true),
        Sample(text: "1.0.0", parses: true),
        Sample(text: "1.0", parses: true),
        Sample(text: "2", parses: true),
        Sample(text: "2.9.0", parses: true),
        Sample(text: "2.10.0", parses: true),
        Sample(text: "9.0", parses: true),
        Sample(text: "", parses: false),
        Sample(text: "2.x", parses: false),
        Sample(text: "1.2.3-beta", parses: false),
        Sample(text: "2.", parses: false),
        Sample(text: "+1", parses: false),
        Sample(text: "2.０", parses: false),
        Sample(text: "99999999999999999999", parses: false),
    ]

    /// The corpus plus `nil`, for the two inputs that are `Optional`.
    static let optionalCorpus: [Sample?] = [nil] + corpus.map { Optional($0) }

    /// Whether `lhs` is strictly below `rhs`, using the comparator that
    /// `AppVersionTests` covers. Returns `false` when either side is absent or
    /// does not parse.
    static func isBelow(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs, let left = AppVersion(lhs), let right = AppVersion(rhs) else {
            return false
        }
        return left < right
    }

    static func describe(
        minSupported: Sample?, latest: Sample?, current: Sample, dismissed: Sample? = nil
    ) -> Comment {
        Comment(
            rawValue: "minSupported: \(String(describing: minSupported?.text)), "
                + "latest: \(String(describing: latest?.text)), "
                + "current: \(current.text), "
                + "dismissed: \(String(describing: dismissed?.text))"
        )
    }

    @Test("the corpus agrees with the parser it was written against")
    func corpusAgreesWithParser() {
        for sample in Self.corpus {
            #expect(
                (AppVersion(sample.text) != nil) == sample.parses,
                "text: \(sample.text), expected parses: \(sample.parses)"
            )
        }
    }

    @Test("the only path to a wall is a parseable floor strictly above a parseable running version")
    func onlyPathToAWall() {
        for minSupported in Self.optionalCorpus {
            for latest in Self.optionalCorpus {
                for current in Self.corpus {
                    let decision = AppGate.evaluate(
                        minSupported: minSupported?.text,
                        latest: latest?.text,
                        current: current.text
                    )
                    let shouldWall =
                        (minSupported?.parses ?? false) && current.parses
                        && Self.isBelow(current.text, minSupported?.text)
                    #expect(
                        (decision.state == .blocked) == shouldWall,
                        Self.describe(minSupported: minSupported, latest: latest, current: current)
                    )
                }
            }
        }
    }

    @Test("a notice needs a parseable latest above a parseable running version, and no wall")
    func noticeNeedsAParseableLatestAboveCurrent() throws {
        for minSupported in Self.optionalCorpus {
            for latest in Self.optionalCorpus {
                for current in Self.corpus {
                    let decision = AppGate.evaluate(
                        minSupported: minSupported?.text,
                        latest: latest?.text,
                        current: current.text
                    )
                    let shouldWall =
                        (minSupported?.parses ?? false) && current.parses
                        && Self.isBelow(current.text, minSupported?.text)
                    let shouldNotice =
                        !shouldWall && current.parses && (latest?.parses ?? false)
                        && Self.isBelow(current.text, latest?.text)
                    let message = Self.describe(
                        minSupported: minSupported, latest: latest, current: current)
                    if shouldNotice {
                        let expectedLatest = try #require(AppVersion(latest!.text))
                        #expect(decision.state == .notice(latest: expectedLatest), message)
                    } else if case .notice = decision.state {
                        Issue.record(
                            "a notice was raised with no parseable newer version — \(message)")
                    }
                }
            }
        }
    }

    @Test("an unparseable running version gates nothing, on every other axis")
    func unparseableCurrentGatesNothing() {
        for minSupported in Self.optionalCorpus {
            for latest in Self.optionalCorpus {
                for current in Self.corpus where !current.parses {
                    let decision = AppGate.evaluate(
                        minSupported: minSupported?.text,
                        latest: latest?.text,
                        current: current.text
                    )
                    let message = Self.describe(
                        minSupported: minSupported, latest: latest, current: current)
                    #expect(decision.state == .open, message)
                    #expect(decision.diagnosis == .currentVersionUnparseable, message)
                }
            }
        }
    }

    @Test("a dismissal silences only an exact match, and never releases a wall")
    func dismissalSilencesOnlyAnExactMatch() {
        for dismissed in Self.optionalCorpus {
            for current in Self.corpus where current.parses && Self.isBelow(current.text, "9.0.0") {
                let walled = AppGate.evaluate(
                    minSupported: "9.0.0",
                    latest: "9.0.0",
                    current: current.text,
                    dismissedVersion: dismissed?.text
                )
                #expect(
                    walled.state == .blocked,
                    Self.describe(
                        minSupported: Sample(text: "9.0.0", parses: true),
                        latest: Sample(text: "9.0.0", parses: true),
                        current: current, dismissed: dismissed
                    )
                )

                let noticed = AppGate.evaluate(
                    minSupported: nil,
                    latest: "9.0.0",
                    current: current.text,
                    dismissedVersion: dismissed?.text
                )
                let shouldDismiss =
                    dismissed.flatMap { AppVersion($0.text) } == AppVersion("9.0.0")
                let message = Self.describe(
                    minSupported: nil, latest: Sample(text: "9.0.0", parses: true),
                    current: current, dismissed: dismissed
                )
                if shouldDismiss {
                    #expect(noticed.state == .open, message)
                    #expect(
                        noticed.diagnosis == .newerVersionDismissed(latest: AppVersion("9.0.0")!),
                        message
                    )
                } else {
                    if case .open = noticed.state, case .newerVersionDismissed = noticed.diagnosis {
                        Issue.record(
                            "a dismissal silenced a notice without an exact match — \(message)")
                    }
                }
            }
        }
    }

    @Test("a feature floor gates only when both its floor and the running version parse")
    func featureFloorGatesOnlyWhenBothParse() {
        for floor in Self.optionalCorpus {
            for current in Self.corpus {
                let config = AppGateConfig(
                    minSupported: nil,
                    featureFloors: floor.map { ["share": $0.text] }
                )
                let shouldBlock =
                    (floor?.parses ?? false) && current.parses
                    && Self.isBelow(current.text, floor?.text)
                let message = Self.describe(minSupported: floor, latest: nil, current: current)
                #expect(
                    config.isBlocked(feature: "share", current: current.text) == shouldBlock,
                    message
                )
                #expect(
                    config.isBlocked(feature: "absent", current: current.text) == false, message)
            }
        }
    }
}
