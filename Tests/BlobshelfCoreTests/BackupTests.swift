import Foundation
import Testing
@testable import BlobshelfCore

@Suite struct BackupTests {
    @Test func plannerUploadsOnlyWhatChanged() {
        let local = [
            "new.txt": LocalFile(size: 1, mtime: 1),
            "same.txt": LocalFile(size: 2, mtime: 2),
            "touched.txt": LocalFile(size: 3, mtime: 9),
            "resized.txt": LocalFile(size: 5, mtime: 4),
            "nomanifest.txt": LocalFile(size: 6, mtime: 6),
        ]
        let remote: [String: Int64] = ["same.txt": 2, "touched.txt": 3, "resized.txt": 4, "nomanifest.txt": 6, "deleted-locally.txt": 7]
        let manifest = [
            "same.txt": LocalFile(size: 2, mtime: 2),
            "touched.txt": LocalFile(size: 3, mtime: 3),
            "resized.txt": LocalFile(size: 5, mtime: 4),
        ]
        #expect(BackupPlanner.uploads(local: local, remoteSizes: remote, manifest: manifest)
            == ["new.txt", "nomanifest.txt", "resized.txt", "touched.txt"])
    }

    @Test func excludeMatcher() {
        let m = ExcludeMatcher(BackupJob.defaultExcludes + ["build/*.o", " "])
        #expect(m.excludes(".DS_Store"))
        #expect(m.excludes("src/.git/config"))
        #expect(m.excludes("x/y.tmp"))
        #expect(m.excludes("~$report.docx"))
        #expect(m.excludes("build/a.o"))
        #expect(!m.excludes("lib/build/a.o"))
        #expect(!m.excludes("notes.txt"))
    }

    @Test func defaultPrefixIncludesJobID() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        #expect(BackupJob.defaultPrefix(localPath: "/Users/me/Photos", id: id) == "Backups/Photos-abcdef12/")
    }

    @Test func overlappingDestinationsRejected() {
        let bucket = UUID()
        let a = BackupJob(localPath: "/a", bucketRef: bucket, remotePrefix: "Backups/x/")
        #expect(throws: BackupJobError.self) {
            try BackupJob.validate(BackupJob(localPath: "/b", bucketRef: bucket, remotePrefix: "Backups/x/inner"), among: [a])
        }
        #expect(throws: BackupJobError.self) {
            try BackupJob.validate(BackupJob(localPath: "/b", bucketRef: bucket, remotePrefix: "Backups/"), among: [a])
        }
        #expect(throws: BackupJobError.emptyPrefix) {
            try BackupJob.validate(BackupJob(localPath: "/b", bucketRef: bucket, remotePrefix: "/"), among: [a])
        }
        #expect(throws: Never.self) {
            try BackupJob.validate(BackupJob(localPath: "/b", bucketRef: bucket, remotePrefix: "Backups/xy/"), among: [a])
            try BackupJob.validate(BackupJob(localPath: "/b", bucketRef: UUID(), remotePrefix: "Backups/x/"), among: [a])
            try BackupJob.validate(a, among: [a])
        }
    }

    @Test func scannerSkipsExcludedSymlinksAndStateDirs() throws {
        let dir = try TempDir()
        try dir.write("a.txt", "a")
        try dir.write("sub/b.txt", "bb")
        try dir.write("sub/.DS_Store", "x")
        try dir.write(".git/HEAD", "x")
        try dir.write("state/manifest.json", "{}")
        try FileManager.default.createSymbolicLink(at: dir.url.appending(path: "link.txt"),
                                                   withDestinationURL: dir.url.appending(path: "a.txt"))
        let result = LocalScanner.scan(dir.url, excludes: ExcludeMatcher(BackupJob.defaultExcludes),
                                       skipping: [dir.url.appending(path: "state")])
        #expect(Set(result.files.keys) == ["a.txt", "sub/b.txt"])
        #expect(result.files["sub/b.txt"]?.size == 2)
        #expect(result.unreadable == 0)
    }

    @Test func manifestFollowsDestination() {
        let engine = BackupEngine(manifestsDir: URL(fileURLWithPath: "/m"), skipping: [])
        var job = BackupJob(localPath: "/a", bucketRef: UUID(), remotePrefix: "Backups/one/")
        let before = engine.manifestURL(for: job)
        #expect(before.lastPathComponent.hasPrefix(job.id.uuidString))
        job.enabled = false
        #expect(engine.manifestURL(for: job) == before)
        job.remotePrefix = "Backups/two"
        #expect(engine.manifestURL(for: job) != before)
        job.remotePrefix = "Backups/one"
        #expect(engine.manifestURL(for: job) == before)
    }

    @Test func manifestRoundTrip() throws {
        let dir = try TempDir()
        let manifest = BackupManifest(url: dir.url.appending(path: "m/job.json"))
        #expect(manifest.load().isEmpty)
        let entries = ["a": LocalFile(size: 1, mtime: 1_700_000_000.123456)]
        try manifest.save(entries)
        #expect(manifest.load() == entries)
    }
}
