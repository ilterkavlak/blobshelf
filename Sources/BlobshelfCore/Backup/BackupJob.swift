import Foundation

public struct BackupJob: Codable, Identifiable, Hashable, Sendable {
    /// Junk, plus files that commonly hold secrets: those stay on this Mac unless the user removes the pattern.
    public static let defaultExcludes = [
        ".DS_Store", ".git", "*.tmp", "~$*",
        ".ssh", ".gnupg", ".aws", ".netrc", ".npmrc", ".env", ".env.*", "*.pem",
        "id_rsa*", "id_ed25519*", "id_ecdsa*", "*.keychain-db", ".*_history",
    ]

    public var id: UUID
    public var localPath: String
    /// `BucketConfig.id` of the destination bucket.
    public var bucketRef: UUID
    public var remotePrefix: String
    public var enabled: Bool
    public var intervalMinutes: Int
    public var excludes: [String]
    /// Read-only security-scoped bookmark to the folder; the sandboxed app can reach it only through this.
    public var bookmark: Data?
    public var lastSuccess: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), localPath: String, bucketRef: UUID, remotePrefix: String,
                enabled: Bool = true, intervalMinutes: Int = 60, excludes: [String] = defaultExcludes) {
        self.id = id
        self.localPath = localPath
        self.bucketRef = bucketRef
        self.remotePrefix = remotePrefix
        self.enabled = enabled
        self.intervalMinutes = intervalMinutes
        self.excludes = excludes
    }

    public var name: String { URL(fileURLWithPath: localPath).lastPathComponent }

    public static func makeBookmark(_ folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The id suffix keeps two same-named folders from sharing a destination.
    public static func defaultPrefix(localPath: String, id: UUID) -> String {
        let dir = URL(fileURLWithPath: localPath).lastPathComponent
        return "Backups/\(dir)-\(id.uuidString.prefix(8).lowercased())/"
    }

    public static func normalizedPrefix(_ prefix: String) -> String {
        var p = prefix.trimmingCharacters(in: .whitespaces)
        while p.hasPrefix("/") { p.removeFirst() }
        if !p.isEmpty && !p.hasSuffix("/") { p += "/" }
        return p
    }

    /// Rejects a job whose destination would mix its files with another job's in the same bucket.
    public static func validate(_ job: BackupJob, among jobs: [BackupJob]) throws {
        let prefix = normalizedPrefix(job.remotePrefix)
        if prefix.isEmpty { throw BackupJobError.emptyPrefix }
        for other in jobs where other.id != job.id && other.bucketRef == job.bucketRef {
            let otherPrefix = normalizedPrefix(other.remotePrefix)
            if prefix.hasPrefix(otherPrefix) || otherPrefix.hasPrefix(prefix) {
                throw BackupJobError.overlaps(other.name, otherPrefix)
            }
        }
        if job.intervalMinutes < 1 { throw BackupJobError.badInterval }
    }
}

public enum BackupJobError: LocalizedError, Equatable {
    case emptyPrefix
    case overlaps(String, String)
    case badInterval
    case publicBucket

    public var errorDescription: String? {
        switch self {
        case .emptyPrefix: "Choose a destination folder in the bucket."
        case let .overlaps(name, prefix): "The destination overlaps the backup of “\(name)” (\(prefix))."
        case .badInterval: "The interval must be at least one minute."
        case .publicBucket: "Backups cannot go to a public bucket, where anyone on the internet could read them. Choose a private bucket."
        }
    }
}
