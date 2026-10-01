import Foundation
import Synchronization

@testable import AppGateClient

/// A transport that holds every request open until the test releases it, so a
/// test can act while a refresh is in flight.
///
/// The wait has a time limit, like the wait in `StubTransport`. A test that
/// never releases fails its own assertion and does not hang the suite.
final class GatedTransport: Sendable {
    private struct State {
        var requested: [URL] = []
        var released = false
    }

    private static let polls = 2000
    private static let pollInterval = Duration.milliseconds(1)

    private let state = Mutex(State())
    private let answer: @Sendable (URL) -> AppGateResponse?

    /// One canned response per source. A lookup URL gets `lookup`, and any
    /// other URL gets `config`.
    init(config: AppGateResponse?, lookup: AppGateResponse?) {
        answer = { url in
            url.absoluteString.contains("itunes.apple.com") ? lookup : config
        }
    }

    var requested: [URL] { state.withLock { $0.requested } }

    /// Lets every held request, and every later request, return.
    func release() { state.withLock { $0.released = true } }

    var fetching: AppGateFetching {
        { [self] url in
            state.withLock { $0.requested.append(url) }
            for _ in 0..<Self.polls {
                if state.withLock({ $0.released }) { break }
                try? await Task.sleep(for: Self.pollInterval)
            }
            return answer(url)
        }
    }

    /// Waits until `count` requests have been issued and are held. The wait
    /// has a time limit, so a test cannot hang here.
    func waitForRequests(_ count: Int) async {
        for _ in 0..<Self.polls {
            if requested.count >= count { return }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}
