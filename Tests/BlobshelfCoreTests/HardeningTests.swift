import Foundation
import os
import Testing
@testable import BlobshelfCore

/// Stubbed-network tests share `StubProtocol.handler`, so they live in the serialized client suite.
extension S3ClientTests {
    func redirectEverything() {
        StubProtocol.requests.withLock { $0 = [] }
        StubProtocol.handler = { req in
            req.url!.host() == "elsewhere.test"
                ? (200, [:], Data("<ListBucketResult></ListBucketResult>".utf8))
                : (302, ["Location": "https://elsewhere.test/steal"], Data())
        }
    }

    @Test func defaultSessionFollowsRedirects() async throws {
        redirectEverything()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = S3Client(credentials: CredentialProvider(fetcher: CountingFetcher()), session: URLSession(configuration: config))
        _ = try await client.list(prefix: "", delimiter: nil)
        #expect(StubProtocol.requests.withLock { $0.contains { $0.url!.host() == "elsewhere.test" } })
    }

    @Test func appSessionRefusesRedirects() async throws {
        redirectEverything()
        let client = S3Client(credentials: CredentialProvider(fetcher: CountingFetcher()),
                              session: HTTP.makeSession { $0.protocolClasses = [StubProtocol.self] })
        await #expect(throws: S3Error.self) { try await client.list(prefix: "", delimiter: nil) }
        let dir = try TempDir()
        try dir.write("small.txt", "hello")
        await #expect(throws: S3Error.self) {
            try await client.putFile(dir.url.appending(path: "small.txt"), key: "k", progress: { _, _ in })
        }
        #expect(StubProtocol.requests.withLock { !$0.contains { $0.url!.host() == "elsewhere.test" } })
    }
}

@Suite struct HardeningTests {
    @Test func storageEndpointMustBeHTTPSOnR2() {
        #expect(CredentialsAPI.isStorageEndpoint(URL(string: "https://abc.r2.cloudflarestorage.com")!))
        #expect(!CredentialsAPI.isStorageEndpoint(URL(string: "http://abc.r2.cloudflarestorage.com")!))
        #expect(!CredentialsAPI.isStorageEndpoint(URL(string: "https://abc.r2.cloudflarestorage.com.evil.test")!))
        #expect(!CredentialsAPI.isStorageEndpoint(URL(string: "https://r2.cloudflarestorage.com")!))
    }

    @Test func tokenHashMustBeAHostLabel() {
        func token(hash: String) -> String {
            let bytes = [2, 0, 1, 0, 1, UInt8(hash.utf8.count)] + Array("bp".utf8) + Array(hash.utf8)
            return Data(bytes).base64EncodedString()
        }
        #expect(BlobToken(token(hash: "ab12-cd")) != nil)
        #expect(BlobToken(token(hash: "evil.com/x")) == nil)
        #expect(BlobToken(token(hash: "UPPER")) == nil)
        #expect(BlobToken(token(hash: String(repeating: "a", count: 64))) == nil)
    }

    @Test func secretsAreExcludedByDefault() {
        let m = ExcludeMatcher(BackupJob.defaultExcludes)
        for path in [".ssh/id_ed25519", "proj/.env", "proj/.env.local", "certs/server.pem", ".aws/credentials",
                     ".zsh_history", "id_rsa.pub", "login.keychain-db"] {
            #expect(m.excludes(path), "\(path)")
        }
        for path in ["Talk.key", "notes/environment.txt", "id_card.jpg", "Library/photo.png"] {
            #expect(!m.excludes(path), "\(path)")
        }
    }

    @Test func throttleLetsThroughFirstSpacedAndFinal() {
        var throttle = ProgressThrottle()
        let start = ContinuousClock.now
        let reported = [(1, 0), (2, 50), (3, 150), (100, 160)].map { done, ms in
            throttle.shouldReport(done: Int64(done), total: 100, at: start + .milliseconds(ms))
        }
        #expect(reported == [true, false, true, true])
    }

    @Test func partProgressSumsPartsAndNeverGoesBack() {
        let reports = OSAllocatedUnfairLock(initialState: [Int64]())
        let progress = PartProgress(size: 30) { done, total in
            #expect(total == 30)
            reports.withLock { $0.append(done) }
        }
        let a = progress.handler(forPart: 0), b = progress.handler(forPart: 1), c = progress.handler(forPart: 2)
        c(10, 10)
        a(4, 10)
        b(10, 10)
        a(2, 10)
        a(10, 10)
        #expect(reports.withLock { $0 } == [10, 14, 24, 24, 30])
    }
}

@Suite struct ConcurrencyTests {
    @Test func respectsLimitAndDeliversEveryResult() async throws {
        let running = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        var results: [Int] = []
        try await concurrentForEach(0..<40, limit: 3) { i in
            running.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            try await Task.sleep(for: .milliseconds(2))
            running.withLock { $0.now -= 1 }
            return i * 2
        } onResult: { results.append($0) }
        #expect(results.sorted() == (0..<40).map { $0 * 2 })
        #expect(running.withLock { $0.peak } == 3)
    }

    @Test func partBudgetCapsSlotsAcrossCallers() async throws {
        let budget = PartBudget(limit: 2)
        let running = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        try await concurrentForEach(0..<12, limit: 6) { _ in
            try await budget.withSlot {
                running.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
                try await Task.sleep(for: .milliseconds(3))
                running.withLock { $0.now -= 1 }
            }
        }
        #expect(running.withLock { $0.peak } == 2)
    }

    @Test func cancellingAWaiterFreesItWithoutASlot() async throws {
        let budget = PartBudget(limit: 1)
        let holder = Task { try await budget.withSlot { try await Task.sleep(for: .seconds(5)) } }
        try await Task.sleep(for: .milliseconds(50))
        let waiter = Task { try await budget.withSlot { 1 } }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let started = ContinuousClock.now
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - started < .seconds(1))
        holder.cancel()
    }

    @Test func firstErrorStopsTheRest() async {
        struct Boom: Error {}
        let started = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: Boom.self) {
            try await concurrentForEach(0..<100, limit: 2) { i in
                started.withLock { $0 += 1 }
                if i == 3 { throw Boom() }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        #expect(started.withLock { $0 } < 100)
    }
}

extension S3ClientTests {
    /// Uploads a zero-filled multipart file while `replaceWhen` matches a request, at which point the
    /// file is atomically replaced by a larger one full of 0xFF; returns whether each part was all zeros.
    func uploadWhileReplacing(replaceWhen: @escaping @Sendable (String) -> Bool) async throws -> [Int: Bool] {
        let dir = try TempDir()
        let file = dir.url.appending(path: "big.bin")
        let size = Int(S3Client.multipartThreshold) + 5
        try Data(count: size).write(to: file)
        let partBytes = OSAllocatedUnfairLock(initialState: [Int: Bool]())
        StubProtocol.requests.withLock { $0 = [] }
        StubProtocol.latency = { req in req.url!.query?.contains("partNumber=1&") == true ? 0.3 : 0 }
        defer { StubProtocol.latency = { _ in 0 } }
        StubProtocol.handler = { req in
            let query = req.url!.query ?? ""
            if replaceWhen(query) { try? Data(repeating: 0xFF, count: size + (32 << 20)).write(to: file, options: .atomic) }
            if query == "uploads=" {
                return (200, [:], Data("<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>".utf8))
            }
            if let number = query.split(separator: "&").first(where: { $0.hasPrefix("partNumber=") }).flatMap({ Int($0.dropFirst(11)) }) {
                partBytes.withLock { $0[number] = req.bodyData?.allSatisfy { $0 == 0 } ?? false }
                return (200, ["ETag": "\"e\(number)\""], Data())
            }
            return (200, [:], Data("<CompleteMultipartUploadResult/>".utf8))
        }
        let client = S3Client(credentials: CredentialProvider(fetcher: CountingFetcher()),
                              session: HTTP.makeSession { $0.protocolClasses = [StubProtocol.self] })
        try await client.putFile(file, key: "big.bin")
        return partBytes.withLock { $0 }
    }

    @Test func multipartKeepsReadingTheOriginalFileWhenItIsReplaced() async throws {
        let parts = try await uploadWhileReplacing { $0.hasPrefix("partNumber=1&") }
        #expect(parts == [1: true, 2: true, 3: true, 4: true, 5: true])
    }

    @Test func multipartSizeComesFromTheOpenFileNotTheReplacement() async throws {
        let parts = try await uploadWhileReplacing { $0 == "uploads=" }
        #expect(parts == [1: true, 2: true, 3: true, 4: true, 5: true])
    }

    @Test func missingSourceReportsItsRealCause() {
        #expect(throws: POSIXError(.ENOENT)) { try SourceFile(URL(fileURLWithPath: "/nonexistent/blobshelf-test")) }
    }

    @Test func partsUploadInParallelAndCompleteInOrder() async throws {
        let completeBody = OSAllocatedUnfairLock<String?>(initialState: nil)
        let started = OSAllocatedUnfairLock(initialState: [Int: ContinuousClock.Instant]())
        StubProtocol.requests.withLock { $0 = [] }
        StubProtocol.latency = { req in req.url!.query?.contains("partNumber=1&") == true ? 0.4 : 0.02 }
        defer { StubProtocol.latency = { _ in 0 } }
        StubProtocol.handler = { req in
            let query = req.url!.query ?? ""
            if query == "uploads=" {
                return (200, [:], Data("<InitiateMultipartUploadResult><UploadId>u1</UploadId></InitiateMultipartUploadResult>".utf8))
            }
            if let number = query.split(separator: "&").first(where: { $0.hasPrefix("partNumber=") }).flatMap({ Int($0.dropFirst(11)) }) {
                started.withLock { $0[number] = .now }
                return (200, ["ETag": "\"e\(number)\""], Data())
            }
            completeBody.withLock { $0 = req.bodyString }
            return (200, [:], Data("<CompleteMultipartUploadResult/>".utf8))
        }
        let dir = try TempDir()
        let file = dir.url.appending(path: "big.bin")
        try Data(count: Int(S3Client.multipartThreshold) + 5).write(to: file)
        let client = S3Client(credentials: CredentialProvider(fetcher: CountingFetcher()),
                              session: HTTP.makeSession { $0.protocolClasses = [StubProtocol.self] })
        try await client.putFile(file, key: "big.bin")

        let starts = started.withLock { $0 }
        let first = try #require(starts[1]), second = try #require(starts[2])
        #expect(second - first < .milliseconds(300), "part 2 should start while the slow part 1 is in flight")
        let body = try #require(completeBody.withLock { $0 })
        let expected = (1...5).map { "<Part><PartNumber>\($0)</PartNumber><ETag>&quot;e\($0)&quot;</ETag></Part>" }.joined()
        #expect(body == "<CompleteMultipartUpload>\(expected)</CompleteMultipartUpload>")
    }
}

/// Hands out credentials with the given visibilities in order, then repeats the last one.
final class VisibilityFetcher: CredentialsFetching {
    let visibilities: [String]
    let calls = OSAllocatedUnfairLock(initialState: 0)

    init(_ visibilities: [String]) { self.visibilities = visibilities }

    func fetch() async throws -> BlobCredentials {
        let n = calls.withLock { $0 += 1; return $0 }
        var creds = credentials(expiresIn: 600)
        creds.visibility = visibilities[min(n, visibilities.count) - 1]
        return creds
    }
}

@Suite struct BackupDestinationTests {
    func run(_ fetcher: VisibilityFetcher, primeCache: Bool) async throws {
        let provider = CredentialProvider(fetcher: fetcher)
        if primeCache { _ = try await provider.credentials() }
        let dir = try TempDir()
        try dir.write("secret.txt", "x")
        let client = S3Client(credentials: provider, session: HTTP.makeSession { $0.protocolClasses = [] })
        let job = BackupJob(localPath: dir.url.path, bucketRef: UUID(), remotePrefix: "b/")
        _ = try await BackupEngine(manifestsDir: try TempDir().url, skipping: []).run(job, client: client) { _ in }
    }

    @Test func publicBucketIsRefusedBeforeAnyUpload() async {
        await #expect(throws: BackupJobError.publicBucket) { try await run(VisibilityFetcher(["public"]), primeCache: false) }
    }

    @Test func cachedPrivateVisibilityIsNotTrusted() async {
        let fetcher = VisibilityFetcher(["private", "public"])
        await #expect(throws: BackupJobError.publicBucket) { try await run(fetcher, primeCache: true) }
        #expect(fetcher.calls.withLock { $0 } == 2)
    }
}

extension URLRequest {
    var bodyString: String? { bodyData.flatMap { String(data: $0, encoding: .utf8) } }

    /// The body as the stub sees it: upload tasks hand it over as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
