import Foundation

public enum BackupPlanner {
    /// Relative paths to upload: files the bucket lacks, whose size differs there, or that changed
    /// locally since their last successful upload. Remote objects are never deleted.
    public static func uploads(local: [String: LocalFile], remoteSizes: [String: Int64],
                               manifest: [String: LocalFile]) -> [String] {
        local.compactMap { path, file in
            remoteSizes[path] == file.size && manifest[path] == file ? nil : path
        }.sorted()
    }
}

/// What was last uploaded for each file of one job, so unchanged files are not uploaded again.
public struct BackupManifest: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [String: LocalFile] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: LocalFile].self, from: data)) ?? [:]
    }

    public func save(_ entries: [String: LocalFile]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}
