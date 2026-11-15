import Foundation
import os
import Testing
@testable import BlobshelfCore

func credentials(expiresIn seconds: TimeInterval, from now: Date = Date(), id: String = "a") -> BlobCredentials {
    BlobCredentials(accessKeyId: id, secretAccessKey: "s", sessionToken: "t",
                    endpoint: URL(string: "https://acct.r2.test")!, bucket: "bkt", region: "auto",
                    expiresAt: now.addingTimeInterval(seconds), visibility: "private", permission: "object-read-write")
}

final class CountingFetcher: CredentialsFetching {
    let calls = OSAllocatedUnfairLock(initialState: 0)
    let lifetime: TimeInterval
    let delay: Duration

    init(lifetime: TimeInterval = 600, delay: Duration = .zero) {
        self.lifetime = lifetime
        self.delay = delay
    }

    func fetch() async throws -> BlobCredentials {
        let n = calls.withLock { $0 += 1; return $0 }
        try await Task.sleep(for: delay)
        return credentials(expiresIn: lifetime, id: "cred\(n)")
    }
}

@Suite struct CredentialProviderTests {
    @Test func cachesUntilNearExpiry() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let fetcher = CountingFetcher()
        let provider = CredentialProvider(fetcher: fetcher, now: { clock.withLock { $0 } })
        _ = try await provider.credentials()
        _ = try await provider.credentials()
        #expect(fetcher.calls.withLock { $0 } == 1)
        clock.withLock { $0 = $0.addingTimeInterval(545) }
        #expect(try await provider.credentials().accessKeyId == "cred2")
    }

    @Test func concurrentCallersShareOneFetch() async throws {
        let fetcher = CountingFetcher(delay: .milliseconds(50))
        let provider = CredentialProvider(fetcher: fetcher)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await provider.credentials().accessKeyId } }
            for try await id in group { #expect(id == "cred1") }
        }
        #expect(fetcher.calls.withLock { $0 } == 1)
    }

    @Test func invalidateForcesRefetch() async throws {
        let fetcher = CountingFetcher()
        let provider = CredentialProvider(fetcher: fetcher)
        _ = try await provider.credentials()
        await provider.invalidate()
        #expect(try await provider.credentials().accessKeyId == "cred2")
    }
}

/// Serves canned responses to an S3Client and records the requests it made.
final class StubProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    nonisolated(unsafe) static var handler: Handler = { _ in (500, [:], Data()) }
    /// Seconds to wait before answering, without blocking other requests.
    nonisolated(unsafe) static var latency: @Sendable (URLRequest) -> Double = { _ in 0 }
    static let requests = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        Self.requests.withLock { $0.append(request) }
        let (status, headers, body) = Self.handler(request)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.latency(request)) { [self] in
            respond(status, headers, body)
        }
    }

    private func respond(_ status: Int, _ headers: [String: String], _ body: Data) {
        let request = self.request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        if (300..<400).contains(status), let location = headers["Location"].flatMap(URL.init(string:)) {
            var redirected = request
            redirected.url = location
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct S3ClientTests {
    func makeClient(_ fetcher: CountingFetcher = CountingFetcher()) -> S3Client {
        StubProtocol.requests.withLock { $0 = [] }
        return S3Client(credentials: CredentialProvider(fetcher: fetcher), session: HTTP.makeSession { $0.protocolClasses = [StubProtocol.self] })
    }

    @Test func listAllFollowsContinuation() async throws {
        StubProtocol.handler = { req in
            let query = req.url!.query ?? ""
            let body = query.contains("continuation-token=n%2B1")
                ? "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>b</Key><Size>2</Size></Contents></ListBucketResult>"
                : "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>n+1</NextContinuationToken><Contents><Key>a</Key><Size>1</Size></Contents></ListBucketResult>"
            return (200, [:], Data(body.utf8))
        }
        let page = try await makeClient().listAll(prefix: "")
        #expect(page.objects.map(\.key) == ["a", "b"])
        let urls = StubProtocol.requests.withLock { $0.map { $0.url!.absoluteString } }
        #expect(urls.first == "https://acct.r2.test/bkt?list-type=2&prefix=")
    }

    @Test func retriesOnceWithFreshCredentialsAfter403() async throws {
        StubProtocol.handler = { req in
            req.value(forHTTPHeaderField: "Authorization")!.contains("Credential=cred1/")
                ? (403, [:], Data("<Error><Code>AccessDenied</Code><Message>expired</Message></Error>".utf8))
                : (204, [:], Data())
        }
        let fetcher = CountingFetcher()
        try await makeClient(fetcher).delete("dir/file name.txt")
        #expect(fetcher.calls.withLock { $0 } == 2)
        let urls = StubProtocol.requests.withLock { $0.map { $0.url!.absoluteString } }
        #expect(urls == Array(repeating: "https://acct.r2.test/bkt/dir/file%20name.txt", count: 2))
    }

    @Test func surfacesS3ErrorAfterRetry() async throws {
        StubProtocol.handler = { _ in (403, [:], Data("<Error><Code>AccessDenied</Code><Message>nope</Message></Error>".utf8)) }
        await #expect(throws: S3Error(status: 403, code: "AccessDenied", message: "nope")) {
            try await makeClient().delete("k")
        }
        #expect(StubProtocol.requests.withLock { $0.count } == 2)
    }

    @Test func existsMapsNotFound() async throws {
        StubProtocol.handler = { req in req.url!.path.hasSuffix("/there") ? (200, [:], Data()) : (404, [:], Data()) }
        let client = makeClient()
        #expect(try await client.exists("there"))
        #expect(try await !client.exists("missing"))
    }

    @Test func copyReportsErrorInsideSuccess() async throws {
        StubProtocol.handler = { req in
            #expect(req.value(forHTTPHeaderField: "x-amz-copy-source") == "/bkt/a%20b")
            return (200, [:], Data("<Error><Code>InternalError</Code><Message>boom</Message></Error>".utf8))
        }
        await #expect(throws: S3Error.self) { try await makeClient().copy(from: "a b", to: "c") }
    }

    @Test func partSizeStaysUnderPartLimit() {
        #expect(S3Client.partSize(for: 100 << 20) == 16 << 20)
        let huge: Int64 = 1 << 40
        let part = S3Client.partSize(for: huge)
        #expect((huge + part - 1) / part <= 10_000)
        #expect(part % (1 << 20) == 0)
    }
}
