import Foundation
import Synchronization

@testable import AppGateClient

/// Returns canned responses, and records which URLs were requested and whether
/// two requests overlapped.
final class StubTransport: Sendable {
    private struct State {
        var requested: [URL] = []
        var inFlight = 0
        var overlapped = false
    }

    /// How long a waiting request waits for the other request before it gives
    /// up, which is 400 polls of 5 ms.
    ///
    /// The wait uses `Task.sleep` and not a count of `Task.yield()` calls.
    /// `Task.yield()` only offers the executor a reschedule, so on a loaded
    /// host a waiter can use all its yields before the other request runs.
    /// With yields this assertion passed 5 times in 12 runs. `Task.sleep`
    /// suspends on a timer, which frees the core. A sequential `refresh()`
    /// still fails the assertion and does not hang the suite. It waits the
    /// full two seconds once.
    private static let rendezvousPolls = 400
    private static let rendezvousPollInterval = Duration.milliseconds(5)

    private let state = Mutex(State())
    private let answer: @Sendable (URL) -> AppGateResponse?

    init(answer: @escaping @Sendable (URL) -> AppGateResponse?) {
        self.answer = answer
    }

    /// One canned response per source. A lookup URL gets `lookup`, and any
    /// other URL gets `config`.
    convenience init(config: AppGateResponse?, lookup: AppGateResponse?) {
        self.init(answer: { url in
            url.absoluteString.contains("itunes.apple.com") ? lookup : config
        })
    }

    var requested: [URL] { state.withLock { $0.requested } }
    /// True once two requests were in flight at the same moment.
    var overlapped: Bool { state.withLock { $0.overlapped } }

    var fetching: AppGateFetching {
        { [self] url in
            let alreadyOverlapped = state.withLock { state -> Bool in
                state.requested.append(url)
                state.inFlight += 1
                if state.inFlight >= 2 { state.overlapped = true }
                return state.overlapped
            }
            if !alreadyOverlapped {
                // Wait for the other request. A sequential
                // `await fetch(a); await fetch(b)` never has one, so it waits
                // the full time and leaves `overlapped` false.
                for _ in 0..<Self.rendezvousPolls {
                    if state.withLock({ $0.overlapped }) { break }
                    try? await Task.sleep(for: Self.rendezvousPollInterval)
                }
            }
            state.withLock { $0.inFlight -= 1 }
            return answer(url)
        }
    }
}

extension AppGateResponse {
    static func ok(_ json: String) -> AppGateResponse {
        AppGateResponse(data: Data(json.utf8), statusCode: 200)
    }

    static func status(_ code: Int, _ json: String = "{}") -> AppGateResponse {
        AppGateResponse(data: Data(json.utf8), statusCode: code)
    }
}
