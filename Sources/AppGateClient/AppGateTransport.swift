import Foundation

/// One HTTP response, reduced to the two values the gate reads.
public struct AppGateResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

/// Fetches a URL, or returns `nil` when there is no response, as with a
/// timeout, a DNS failure or an offline device. Tests inject one, so they
/// exercise the store's handling of status codes, malformed bodies, TTLs and
/// last-good caches with no network.
public typealias AppGateFetching = @Sendable (URL) async -> AppGateResponse?
