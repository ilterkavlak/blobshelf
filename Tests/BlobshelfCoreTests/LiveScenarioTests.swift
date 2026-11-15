import Foundation
import Testing
@testable import BlobshelfCore

/// Wider scenarios against a real bucket (UPSTASH_DISK_TEST_TOKEN, read-write). Each test works
/// under its own random prefix and deletes it afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UPSTASH_DISK_TEST_TOKEN"] != nil))
struct LiveScenarioTests {
    let raw = ProcessInfo.processInfo.environment["UPSTASH_DISK_TEST_TOKEN"] ?? ""

    func drive(fetcher: (any CredentialsFetching)? = nil) throws -> DriveService {
        let token = try #require(BlobToken(raw))
        let provider = CredentialProvider(fetcher: fetcher ?? CredentialsAPI(token: raw))
        return DriveService(client: S3Client(credentials: provider), token: token, publicHostSuffix: "blob.upstash.io")
    }

    func withPrefix(_ drive: DriveService, _ body: (String) async throws -> Void) async throws {
        let root = "blobshelf-scenario-\(UUID().uuidString)/"
        do { try await body(root) } catch {
            try? await drive.delete([DriveItem(key: root, name: "", isFolder: true)])
            throw error
        }
        try await drive.delete([DriveItem(key: root, name: "", isFolder: true)])
        #expect(try await drive.client.listAll(prefix: root).objects.isEmpty)
    }

    @Test func credentialsLookSane() async throws {
        let c = try await CredentialsAPI(token: raw).fetch()
        #expect(c.endpoint.scheme == "https")
        let lifetime = c.expiresAt.timeIntervalSinceNow
        #expect(lifetime > 60 && lifetime <= 3600)
    }

    @Test func badTokensAreRejected() async throws {
        #expect(BlobToken("not a token") == nil)
        var bytes = try #require(Data(base64URLEncoded: raw))
        bytes[6 + Int(bytes[2])] ^= 0x01
        let tampered = bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        await #expect(throws: BlobError.self) { try await CredentialsAPI(token: tampered).fetch() }
    }

    @Test func oddNamesRoundTrip() async throws {
        let drive = try drive()
        let names = [
            "space name.txt", "plus+sign.txt", "percent%20literal.txt", "amp&eq=q?hash#.txt",
            "semi;comma,quote'paren(1)[2].txt", "tilde~bang!dollar$at@star*.txt",
            "Türkçe çğıöşü.txt", "日本語.txt", "emoji 🚀.txt", "e\u{301}-decomposed.txt", "back\\slash.txt",
        ]
        try await withPrefix(drive) { root in
            for (i, name) in names.enumerated() {
                try await drive.client.putData(Data("content \(i)".utf8), key: root + "odd/" + name)
            }
            let listed = try await drive.listFolder(root + "odd/")
            #expect(Set(listed.map(\.name)) == Set(names))
            #expect(listed.allSatisfy { $0.key == root + "odd/" + $0.name })

            let dir = try TempDir()
            for (i, name) in names.enumerated() {
                #expect(try await drive.client.exists(root + "odd/" + name))
                let out = dir.url.appending(path: "\(i).out")
                try await drive.download(root + "odd/" + name, to: out)
                #expect(try String(contentsOf: out, encoding: .utf8) == "content \(i)")
            }
            for item in listed where item.name.hasPrefix("amp") || item.name.hasPrefix("emoji") {
                try await drive.rename(item, to: "renamed " + item.name)
            }
            let after = try await drive.listFolder(root + "odd/").map(\.name)
            #expect(after.contains("renamed amp&eq=q?hash#.txt"))
            #expect(after.contains("renamed emoji 🚀.txt"))
            #expect(!after.contains("emoji 🚀.txt"))
            try await drive.rename(DriveItem(key: root + "odd/", name: "odd", isFolder: true), to: "odd ünï")
            #expect(try await drive.listFolder(root + "odd ünï/").count == names.count)
        }
    }

    @Test func emptyFilesFoldersAndConflicts() async throws {
        let drive = try drive()
        try await withPrefix(drive) { root in
            let dir = try TempDir()
            try dir.write("empty.txt", "")
            try await drive.upload(dir.url.appending(path: "empty.txt"), key: root + "empty.txt")
            try await drive.createFolder(named: "Empty Folder", in: root)
            try await drive.client.putData(Data("x".utf8), key: root + "taken.txt")

            let items = try await drive.listFolder(root)
            #expect(items.map(\.name) == ["Empty Folder", "empty.txt", "taken.txt"])
            #expect(items.first { $0.name == "empty.txt" }?.size == 0)
            #expect(try await drive.listFolder(root + "Empty Folder/").isEmpty)

            let out = dir.url.appending(path: "empty.out")
            try await drive.download(root + "empty.txt", to: out)
            #expect(try Data(contentsOf: out).isEmpty)

            let empty = try #require(items.first { $0.name == "empty.txt" })
            await #expect(throws: DriveError.alreadyExists("taken.txt")) { try await drive.rename(empty, to: "taken.txt") }
            let folder = try #require(items.first)
            try await drive.createFolder(named: "Other", in: root)
            await #expect(throws: DriveError.alreadyExists("Other")) { try await drive.rename(folder, to: "Other") }

            let missing = dir.url.appending(path: "missing.out")
            await #expect(throws: (any Error).self) { try await drive.download(root + "nope.txt", to: missing) }
            #expect(!FileManager.default.fileExists(atPath: missing.path))
            #expect(try await !drive.client.exists(root + "nope.txt"))
            try await drive.delete([])
        }
    }

    @Test func paginationAndBatchDelete() async throws {
        let drive = try drive()
        let count = 1_105
        try await withPrefix(drive) { root in
            try await withThrowingTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < count else { return }
                    let i = next; next += 1
                    group.addTask { try await drive.client.putData(Data("\(i)".utf8), key: root + "many/\(String(format: "%05d", i)).txt") }
                }
                for _ in 0..<24 { add() }
                while try await group.next() != nil { add() }
            }
            #expect(try await drive.client.listAll(prefix: root + "many/").objects.count == count)
            #expect(try await drive.listFolder(root + "many/").count == count)
            #expect(try await drive.listFolder(root).map(\.name) == ["many"])
        }
    }

    @Test func rejectedCredentialsAreRefreshedOnce() async throws {
        let fetcher = FlakyFetcher(real: CredentialsAPI(token: raw))
        let drive = try drive(fetcher: fetcher)
        try await withPrefix(drive) { root in
            try await drive.client.putData(Data("retry".utf8), key: root + "retry.txt")
            #expect(try await drive.client.exists(root + "retry.txt"))
            #expect(fetcher.calls >= 2)
        }
    }

    @Test func backupRunsAreIncremental() async throws {
        let drive = try drive()
        let local = try TempDir()
        let state = try TempDir()
        try local.write("a.txt", "alpha")
        try local.write("nested/deep/b.txt", "beta")
        try local.write("nested/Türkçe ğ.txt", "unicode")
        try local.write("nested/empty.txt", "")
        try local.write(".DS_Store", "junk")
        try local.write(".git/config", "junk")
        try local.write("draft.tmp", "junk")
        try local.write("~$lock.docx", "junk")

        try await withPrefix(drive) { root in
            let job = BackupJob(localPath: local.url.path, bucketRef: UUID(), remotePrefix: root + "backup")
            let engine = BackupEngine(manifestsDir: state.url, skipping: [state.url])
            let first = try await engine.run(job, client: drive.client) { _ in }
            #expect(first.uploaded == 4 && first.failures.isEmpty)
            let keys = try await drive.client.listAll(prefix: root + "backup/").objects.map(\.key).sorted()
            #expect(keys == ["a.txt", "nested/Türkçe ğ.txt", "nested/deep/b.txt", "nested/empty.txt"].map { root + "backup/" + $0 }.sorted())

            #expect(try await engine.run(job, client: drive.client) { _ in }.uploaded == 0)

            try await Task.sleep(for: .seconds(1.1))
            try local.write("a.txt", "ALPHA")
            try local.write("new.txt", "new")
            try FileManager.default.removeItem(at: local.url.appending(path: "nested/deep/b.txt"))
            let third = try await engine.run(job, client: drive.client) { _ in }
            #expect(third.uploaded == 2)
            #expect(try await drive.client.exists(root + "backup/nested/deep/b.txt"))

            let out = local.url.appending(path: "check.out")
            try await drive.download(root + "backup/a.txt", to: out)
            #expect(try String(contentsOf: out, encoding: .utf8) == "ALPHA")
        }
    }

    @Test func publicLinkMatchesVisibility() async throws {
        let drive = try drive()
        let visibility = try await drive.client.credentials.credentials().visibility
        try await withPrefix(drive) { root in
            try await drive.client.putData(Data("public?".utf8), key: root + "link test.txt")
            let url = drive.publicURL(for: root + "link test.txt")
            if visibility == "public" {
                let (data, response) = try await URLSession.shared.data(from: url)
                #expect((response as? HTTPURLResponse)?.statusCode == 200 && data == Data("public?".utf8))
            } else {
                // A private bucket has no public host at all, so either a lookup failure or a refusal is fine.
                let status = try? await (URLSession.shared.data(from: url).1 as? HTTPURLResponse)?.statusCode
                #expect(status != 200)
            }
        }
    }
}

/// Returns credentials with a wrong secret first, so R2 rejects the first request.
final class FlakyFetcher: CredentialsFetching, @unchecked Sendable {
    let real: CredentialsAPI
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(real: CredentialsAPI) { self.real = real }

    func fetch() async throws -> BlobCredentials {
        let n = lock.withLock { count += 1; return count }
        var credentials = try await real.fetch()
        if n == 1 { credentials.secretAccessKey = String(credentials.secretAccessKey.reversed()) }
        return credentials
    }
}
