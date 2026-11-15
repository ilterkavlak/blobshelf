import Foundation
import Testing
@testable import BlobshelfCore

/// Runs against a real bucket when UPSTASH_DISK_TEST_TOKEN holds a read-write bucket token.
/// Everything is written under a random prefix and deleted afterwards.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UPSTASH_DISK_TEST_TOKEN"] != nil))
struct LiveTests {
    @Test func roundTrip() async throws {
        let raw = ProcessInfo.processInfo.environment["UPSTASH_DISK_TEST_TOKEN"]!
        let token = try #require(BlobToken(raw))
        let client = S3Client(credentials: CredentialProvider(fetcher: CredentialsAPI(token: raw)))
        let drive = DriveService(client: client, token: token, publicHostSuffix: "blob.upstash.io")
        let root = "blobshelf-test-\(UUID().uuidString)/"
        let dir = try TempDir()

        do {
            try dir.write("small file.txt", "hello upstash")
            let big = dir.url.appending(path: "big.bin")
            try Data(count: Int(S3Client.multipartThreshold) + 1234).write(to: big)

            try await drive.createFolder(named: "docs", in: root)
            try await drive.upload(dir.url.appending(path: "small file.txt"), key: root + "docs/small file.txt")
            try await drive.upload(big, key: root + "big.bin")

            let top = try await drive.listFolder(root)
            #expect(top.map(\.name) == ["docs", "big.bin"])
            #expect(top.last?.size == S3Client.multipartThreshold + 1234)

            let docs = try #require(top.first)
            try await drive.rename(docs, to: "papers")
            let papers = try await drive.listFolder(root + "papers/")
            #expect(papers.map(\.name) == ["small file.txt"])

            let out = dir.url.appending(path: "out.txt")
            try await drive.download(root + "papers/small file.txt", to: out)
            #expect(try String(contentsOf: out, encoding: .utf8) == "hello upstash")
        } catch {
            try? await drive.delete([DriveItem(key: root, name: "", isFolder: true)])
            throw error
        }
        try await drive.delete([DriveItem(key: root, name: "", isFolder: true)])
        #expect(try await drive.listFolder(root).isEmpty)
    }
}
