import Foundation
import Testing
@testable import BlobshelfCore

@Suite struct DriveTests {
    @Test func namesAndParents() {
        #expect(DriveService.name(of: "a/b/c.txt") == "c.txt")
        #expect(DriveService.name(of: "a/b/") == "b")
        #expect(DriveService.parent(of: "a/b/c.txt") == "a/b/")
        #expect(DriveService.parent(of: "a/b/") == "a/")
        #expect(DriveService.parent(of: "top.txt") == "")
    }

    @Test func foldersSortFirst() {
        let items = [
            DriveItem(key: "b.txt", name: "b.txt", isFolder: false),
            DriveItem(key: "z/", name: "z", isFolder: true),
            DriveItem(key: "a10.txt", name: "a10.txt", isFolder: false),
            DriveItem(key: "a2.txt", name: "a2.txt", isFolder: false),
        ]
        #expect(DriveService.sorted(items).map(\.name) == ["z", "a2.txt", "a10.txt", "b.txt"])
    }

    @Test func rejectsBadNames() {
        #expect(throws: DriveError.invalidName) { try DriveService.validate("a/b") }
        #expect(throws: DriveError.invalidName) { try DriveService.validate("  ") }
        #expect(throws: Never.self) { try DriveService.validate("ok name") }
    }

    @Test func uploadPlanRecursesIntoFolders() throws {
        let dir = try TempDir()
        try dir.write("Photos/a.jpg", "1")
        try dir.write("Photos/trip/b.jpg", "22")
        try dir.write("Photos/.hidden", "x")
        try dir.write("single.txt", "s")
        try FileManager.default.createDirectory(at: dir.url.appending(path: "Photos/empty"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.url.appending(path: "Blank"), withIntermediateDirectories: true)
        let plan = DriveService.uploadPlan(for: ["Photos", "single.txt", "Blank"].map { dir.url.appending(path: $0) }, into: "in/")
        #expect(Set(plan.map(\.key)) == ["in/Photos/a.jpg", "in/Photos/trip/b.jpg", "in/Photos/empty/", "in/single.txt", "in/Blank/"])
        #expect(plan.filter { $0.file == nil }.map(\.key).sorted() == ["in/Blank/", "in/Photos/empty/"])
    }

    @Test func publicURL() {
        let token = BlobToken(Data([2, 0, 1, 0, 1, 2] + Array("bph1".utf8)).base64EncodedString())!
        let drive = DriveService(client: S3Client(credentials: CredentialProvider(fetcher: CountingFetcher())),
                                 token: token, publicHostSuffix: "blob.upstash.io")
        #expect(drive.publicURL(for: "a b/c.png").absoluteString == "https://h1.blob.upstash.io/a%20b/c.png")
    }
}

struct TempDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "blobshelf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ path: String, _ content: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
    }
}

@Suite struct LocalPathAllocatorTests {
    let base = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

    @Test func caseInsensitiveNamesGetDistinctFiles() throws {
        var a = LocalPathAllocator()
        let root = a.top("Backup", in: base)
        let oneOpt = a.file("Report.txt", under: root)
        let one = try #require(oneOpt)
        let twoOpt = a.file("report.txt", under: root)
        let two = try #require(twoOpt)
        #expect(one.lastPathComponent == "Report.txt")
        #expect(two.lastPathComponent == "report 2.txt")
    }

    @Test func fileAndDirectoryWithSameNameDoNotCollide() throws {
        var a = LocalPathAllocator()
        let root = a.top("Backup", in: base)
        let fileOpt = a.file("a", under: root)
        let file = try #require(fileOpt)
        let nestedOpt = a.file("a/old.txt", under: root)
        let nested = try #require(nestedOpt)
        let siblingOpt = a.file("a/new.txt", under: root)
        let sibling = try #require(siblingOpt)
        #expect(file.lastPathComponent == "a")
        #expect(nested.deletingLastPathComponent().lastPathComponent == "a 2")
        #expect(sibling.deletingLastPathComponent().path == nested.deletingLastPathComponent().path)
        let dir = a.directory("a/", under: root)
        #expect(dir?.path == nested.deletingLastPathComponent().path)
    }

    @Test func overlappingBatchesShareReservations() {
        var a = LocalPathAllocator()
        let first = a.top("Photos", in: base)
        let second = a.top("photos", in: base)
        #expect(first.lastPathComponent == "Photos")
        #expect(second.lastPathComponent == "photos 2")
    }

    @Test func existingFilesAreNotReused() throws {
        let dir = try TempDir()
        try dir.write("notes.txt", "x")
        var a = LocalPathAllocator()
        let url = a.top("notes.txt", in: dir.url)
        #expect(url.lastPathComponent == "notes 2.txt")
    }

    @Test func dotSegmentsAreRejected() {
        var a = LocalPathAllocator()
        let root = a.top("r", in: base)
        let escape = a.file("../escape.txt", under: root)
        let dot = a.file("x/./y", under: root)
        let top = a.top("..", in: base)
        #expect(escape == nil)
        #expect(dot == nil)
        #expect(top.lastPathComponent == "download")
    }
}

@MainActor @Suite struct CountdownTests {
    @Test func firesOnceAfterAllTicks() {
        var fired = 0
        let c = Countdown(2) { fired += 1 }
        c.tick()
        #expect(fired == 0)
        c.tick()
        c.tick()
        #expect(fired == 1)
    }

    @Test func emptyBatchFiresImmediately() {
        var fired = 0
        _ = Countdown(0) { fired += 1 }
        #expect(fired == 1)
    }

    @Test func ticksBeforeStartAreCounted() {
        var fired = 0
        let c = Countdown { fired += 1 }
        c.tick()
        #expect(fired == 0)
        c.start(1)
        #expect(fired == 1)
    }
}
