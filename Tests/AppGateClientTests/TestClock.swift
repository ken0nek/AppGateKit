import Foundation
import Synchronization

/// A clock a test can move.
final class TestClock: Sendable {
    private let storage: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_000_000)) {
        storage = Mutex(date)
    }

    var now: Date { storage.withLock { $0 } }

    func set(_ date: Date) { storage.withLock { $0 = date } }

    func advance(by interval: TimeInterval) { storage.withLock { $0 += interval } }

    /// The clock as the closure the store takes. It captures `[self]` and not
    /// `[storage]`, because `Mutex` is non-copyable and cannot be captured by
    /// value.
    var provider: @Sendable () -> Date { { [self] in now } }
}
