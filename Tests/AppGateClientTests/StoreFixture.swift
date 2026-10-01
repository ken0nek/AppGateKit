import Foundation

/// A separate `UserDefaults` suite for each test, emptied when the test ends.
///
/// Swift Testing runs tests in parallel, so tests that shared a suite name
/// would read each other's keys. Teardown runs in `deinit`, so the test suites
/// that use this are `final class` and not `struct`, which has no `deinit`.
///
/// It is not `Sendable`, because it holds a `UserDefaults`. Each test suite
/// that owns a fixture is `@MainActor`, which isolates it. It does not use
/// `#require`, because that macro needs a test context.
///
/// ## Why the plist outlives the test
///
/// The process that creates a suite cannot delete the suite's file. `cfprefsd`
/// writes the domain back after the process exits. With the domain removed,
/// synchronized and the file deleted, the file is back on disk within seconds
/// of the test process exiting, and an `atexit` handler that does the same
/// fails the same way. So teardown empties the domain, and the next run
/// deletes the file in the sweep below. Without the sweep, each run leaves one
/// file per test suite in the home directory.
final class StoreFixture {
    enum FixtureError: Error { case suiteUnavailable }

    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        // This reference runs the sweep once per process, before this run adds
        // its own files.
        Self.sweptLeftovers
        suiteName = Self.namePrefix + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw FixtureError.suiteUnavailable
        }
        self.defaults = defaults
    }

    deinit {
        // Remove the domain through `defaults` and not a new `UserDefaults()`.
        // Removing it through another instance leaves this instance's cached
        // values in place, and `cfprefsd` writes them back at exit, so the
        // plist keeps its keys.
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
    }

    // MARK: - Leftovers

    /// Suite names include the process id, so a later run can tell a leftover
    /// file from a suite still in use.
    private static let namePrefix = "AppGateKitTests.\(ProcessInfo.processInfo.processIdentifier)."

    /// Deletes the empty plists left by runs that have ended. A `static let`,
    /// so it runs once, when the first fixture is created.
    ///
    /// It removes a file only when the process named in the file name has
    /// exited, which `kill(_:0)` reports as `ESRCH`. A second test process
    /// running at the same time therefore keeps its suites. A rule based on
    /// file age would delete them.
    private static let sweptLeftovers: Void = {
        let directory = preferencesDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names
        where name.hasPrefix(suiteNamespace) && name.hasSuffix(".plist") && !isLive(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }()

    private static let suiteNamespace = "AppGateKitTests."

    /// Whether the process that owns `fileName` is still running. A name with
    /// no process id has no owner, so it counts as a leftover.
    private static func isLive(_ fileName: String) -> Bool {
        let rest = fileName.dropFirst(suiteNamespace.count)
        guard let identifier = rest.split(separator: ".").first.flatMap({ pid_t($0) }) else {
            return false
        }
        // `EPERM` means this process may not signal that one, so it exists.
        return kill(identifier, 0) == 0 || errno != ESRCH
    }

    /// The directory that holds a suite's preferences file. Built from
    /// `NSHomeDirectory()` and not a hardcoded path, so it is correct when the
    /// test host runs in a container.
    private static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Preferences")
    }

    // MARK: - Seeding

    /// The prefix of every key in these tests, which is the store's default.
    static let keyPrefix = "AppGate."

    func write(config json: String, at stamp: Date) {
        defaults.set(Data(json.utf8), forKey: Self.keyPrefix + "config")
        defaults.set(stamp.timeIntervalSince1970, forKey: Self.keyPrefix + "configCachedAt")
    }

    func write(lookup json: String, at stamp: Date) {
        defaults.set(Data(json.utf8), forKey: Self.keyPrefix + "lookup")
        defaults.set(stamp.timeIntervalSince1970, forKey: Self.keyPrefix + "lookupCachedAt")
    }

    func write(dismissed version: String) {
        defaults.set(version, forKey: Self.keyPrefix + "dismissedVersion")
    }
}
