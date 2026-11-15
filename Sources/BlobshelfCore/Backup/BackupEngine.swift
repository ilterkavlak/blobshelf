import CryptoKit
import Foundation

public enum BackupProgress: Sendable, Equatable {
    case scanning
    case uploading(done: Int, total: Int)
}

public struct BackupResult: Sendable, Equatable {
    public var uploaded = 0
    public var failures: [String] = []
    public var unreadable = 0

    /// One line for the UI, or nil when everything went up.
    public var problem: String? {
        var parts: [String] = []
        if let first = failures.first {
            parts.append("\(failures.count) file(s) failed to upload, e.g. \(first)")
        }
        if unreadable > 0 { parts.append("\(unreadable) item(s) could not be read") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}

public enum BackupRunError: LocalizedError, Equatable {
    case folderMissing(String)
    case readOnly(String?)

    public var errorDescription: String? {
        switch self {
        case let .folderMissing(path): "The folder \(path) does not exist."
        case let .readOnly(reason): "The bucket is read-only" + (reason.map { ": \($0)" } ?? ".")
        }
    }
}

/// One incremental, upload-only pass of a backup job.
public struct BackupEngine: Sendable {
    public static let concurrency = 8

    let manifestsDir: URL
    let skipping: [URL]

    public init(manifestsDir: URL, skipping: [URL]) {
        self.manifestsDir = manifestsDir
        self.skipping = skipping
    }

    /// Keyed by destination as well as job: a run still uploading to a destination the job was just
    /// moved away from keeps writing its own manifest, never the one for the new destination.
    public func manifestURL(for job: BackupJob) -> URL {
        let destination = "\(job.bucketRef.uuidString)/\(BackupJob.normalizedPrefix(job.remotePrefix))"
        let digest = SHA256.hash(data: Data(destination.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return manifestsDir.appending(path: "\(job.id.uuidString)-\(digest).json")
    }

    public func run(_ job: BackupJob, client: S3Client,
                    progress: @escaping @Sendable (BackupProgress) -> Void) async throws -> BackupResult {
        let root = URL(fileURLWithPath: job.localPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw BackupRunError.folderMissing(job.localPath)
        }
        try await Self.checkDestination(client)
        progress(.scanning)
        let prefix = BackupJob.normalizedPrefix(job.remotePrefix)
        let scan = LocalScanner.scan(root, excludes: ExcludeMatcher(job.excludes), skipping: skipping)
        let remote = try await client.listAll(prefix: prefix).objects
        var remoteSizes: [String: Int64] = [:]
        for object in remote { remoteSizes[String(object.key.dropFirst(prefix.count))] = object.size }

        let manifestFile = BackupManifest(url: manifestURL(for: job))
        var manifest = manifestFile.load().filter { scan.files[$0.key] != nil }
        let todo = BackupPlanner.uploads(local: scan.files, remoteSizes: remoteSizes, manifest: manifest)

        var result = BackupResult(unreadable: scan.unreadable)
        var finished = 0
        progress(.uploading(done: 0, total: todo.count))
        let resolvedRoot = root.resolvingSymlinksInPath()
        do {
            try await concurrentForEach(todo, limit: Self.concurrency) { path in
                do {
                    try await client.putFile(resolvedRoot.appending(path: path), key: prefix + path)
                    return (path, String?.none)
                } catch let error as CancellationError {
                    throw error
                } catch {
                    return (path, error.localizedDescription)
                }
            } onResult: { outcome in
                let (path, error) = outcome
                finished += 1
                if let error {
                    result.failures.append("\(path): \(error)")
                } else {
                    result.uploaded += 1
                    manifest[path] = scan.files[path]
                    if result.uploaded % 50 == 0 { try? manifestFile.save(manifest) }
                }
                progress(.uploading(done: finished, total: todo.count))
                try Task.checkCancellation()
            }
        } catch {
            try? manifestFile.save(manifest)
            throw error
        }
        try manifestFile.save(manifest)
        return result
    }

    /// Checked with freshly fetched credentials on every run: a bucket may have been made public
    /// or read-only since the cached ones were issued.
    static func checkDestination(_ client: S3Client) async throws {
        await client.credentials.invalidate()
        let creds = try await client.credentials.credentials()
        if creds.isPublic { throw BackupJobError.publicBucket }
        if creds.isReadOnly { throw BackupRunError.readOnly(creds.readOnlyReason) }
    }
}
