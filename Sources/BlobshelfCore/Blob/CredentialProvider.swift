import Foundation

/// Hands out a bucket's current credentials, fetching new ones shortly before they expire.
/// Concurrent callers share one fetch.
public actor CredentialProvider {
    private let fetcher: any CredentialsFetching
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private var cached: BlobCredentials?
    private var inflight: Task<BlobCredentials, Error>?

    public init(fetcher: any CredentialsFetching, refreshMargin: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.refreshMargin = refreshMargin
        self.now = now
    }

    public func credentials() async throws -> BlobCredentials {
        if let c = cached, c.expiresAt.timeIntervalSince(now()) > refreshMargin { return c }
        if let task = inflight { return try await task.value }
        let fetcher = self.fetcher
        let task = Task { try await fetcher.fetch() }
        inflight = task
        defer { inflight = nil }
        let fresh = try await task.value
        cached = fresh
        return fresh
    }

    /// Drops the cached credentials so the next call fetches new ones (e.g. after R2 rejected them).
    public func invalidate() {
        cached = nil
    }
}
