import Foundation

public struct BucketConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var bucketID: String

    public init(id: UUID = UUID(), name: String, bucketID: String) {
        self.id = id
        self.name = name
        self.bucketID = bucketID
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    public var buckets: [BucketConfig] = []
    public var jobs: [BackupJob] = []

    public init() {}
}

public enum AppPaths {
    public static let bundleID = "io.github.ilterkavlak.blobshelf"

    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Blobshelf")
    }

    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Blobshelf")
    }

    public static var manifests: URL { support.appending(path: "manifests") }
    public static var preview: URL { caches.appending(path: "preview") }
    /// The app's own data, which backups and folder watchers must never pick up.
    public static var ownState: [URL] { [support, caches] }
}

public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = AppPaths.support.appending(path: "config.json")) { self.url = url }

    public func load() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfig() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppConfig.self, from: Data(contentsOf: url))
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
