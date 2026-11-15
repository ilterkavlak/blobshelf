import Foundation

public struct DriveItem: Identifiable, Hashable, Sendable {
    public var key: String
    public var name: String
    public var isFolder: Bool
    public var size: Int64?
    public var modified: Date?

    public var id: String { key }
}

public enum DriveError: LocalizedError, Equatable {
    case invalidName
    case alreadyExists(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Names cannot be empty or contain “/”."
        case let .alreadyExists(name): "“\(name)” already exists here."
        }
    }
}

/// Folder semantics over a flat key space: "a/b/" is a folder, either because keys exist under it
/// or because an empty "a/b/" marker object was created for it.
public struct DriveService: Sendable {
    static let copyConcurrency = 8

    public let client: S3Client
    public let token: BlobToken
    public let publicHostSuffix: String

    public init(client: S3Client, token: BlobToken, publicHostSuffix: String) {
        self.client = client
        self.token = token
        self.publicHostSuffix = publicHostSuffix
    }

    public func listFolder(_ prefix: String) async throws -> [DriveItem] {
        let page = try await client.listAll(prefix: prefix, delimiter: "/")
        let folders = page.commonPrefixes.map {
            DriveItem(key: $0, name: Self.name(of: $0), isFolder: true)
        }
        let files = page.objects.filter { $0.key != prefix }.map {
            DriveItem(key: $0.key, name: Self.name(of: $0.key), isFolder: false, size: $0.size, modified: $0.lastModified)
        }
        return Self.sorted(folders + files)
    }

    public func createFolder(named name: String, in prefix: String) async throws {
        try Self.validate(name)
        let key = prefix + name + "/"
        if try await folderExists(key) { throw DriveError.alreadyExists(name) }
        try await client.putData(Data(), key: key)
    }

    public func upload(_ file: URL, key: String, progress: ProgressHandler? = nil) async throws {
        try await client.putFile(file, key: key, progress: progress)
    }

    /// Every object a download or delete of `item` covers: the item itself, or all keys under a folder.
    public func keys(of item: DriveItem) async throws -> [S3Object] {
        if !item.isFolder { return [S3Object(key: item.key, size: item.size ?? 0)] }
        return try await client.listAll(prefix: item.key).objects
    }

    public func download(_ key: String, to destination: URL, progress: ProgressHandler? = nil) async throws {
        try await client.download(key, to: destination, progress: progress)
    }

    public func rename(_ item: DriveItem, to newName: String) async throws {
        try Self.validate(newName)
        let parent = Self.parent(of: item.key)
        if item.isFolder {
            let newPrefix = parent + newName + "/"
            if try await folderExists(newPrefix) { throw DriveError.alreadyExists(newName) }
            let objects = try await client.listAll(prefix: item.key).objects
            try await concurrentForEach(objects, limit: Self.copyConcurrency) { [client] object in
                try await client.copy(from: object.key, to: newPrefix + object.key.dropFirst(item.key.count))
            }
            try await client.deleteMany(objects.map(\.key))
        } else {
            let newKey = parent + newName
            if try await client.exists(newKey) { throw DriveError.alreadyExists(newName) }
            try await client.copy(from: item.key, to: newKey)
            try await client.delete(item.key)
        }
    }

    public func delete(_ items: [DriveItem]) async throws {
        var keys: [String] = []
        for item in items {
            keys += try await self.keys(of: item).map(\.key)
        }
        try await client.deleteMany(keys)
    }

    public func publicURL(for key: String) -> URL {
        URL(string: "https://\(token.hashForDomain).\(publicHostSuffix)/\(KeyEncoding.encode(key, keepSlash: true))")!
    }

    private func folderExists(_ prefix: String) async throws -> Bool {
        let page = try await client.list(prefix: prefix, delimiter: nil, maxKeys: 1)
        return !page.objects.isEmpty
    }

    // MARK: Helpers

    public static func name(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }

    public static func parent(of key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }

    static func validate(_ name: String) throws {
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.contains("/") { throw DriveError.invalidName }
    }

    static func sorted(_ items: [DriveItem]) -> [DriveItem] {
        items.sorted {
            $0.isFolder != $1.isFolder ? $0.isFolder : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// What an upload of `urls` into `prefix` writes: a file per regular file, and an empty folder
    /// marker (nil `file`) per empty directory. Folders are uploaded recursively under their own
    /// name; hidden files and symlinks inside them are skipped.
    public static func uploadPlan(for urls: [URL], into prefix: String) -> [UploadEntry] {
        var plan: [UploadEntry] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isDir {
                plan.append(UploadEntry(file: url, key: prefix + url.lastPathComponent))
                continue
            }
            let root = url.resolvingSymlinksInPath()
            let base = prefix + url.lastPathComponent + "/"
            if isEmptyDirectory(root) { plan.append(UploadEntry(file: nil, key: base)) }
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: [.skipsHiddenFiles])
            while let enumerator, let file = enumerator.nextObject() as? URL {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
                let rel = LocalScanner.relativePath(file, enumerator)
                if values?.isDirectory == true {
                    if isEmptyDirectory(file) { plan.append(UploadEntry(file: nil, key: base + rel + "/")) }
                } else if values?.isRegularFile == true {
                    plan.append(UploadEntry(file: file, key: base + rel))
                }
            }
        }
        return plan
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return contents?.isEmpty == true
    }
}

public struct UploadEntry: Sendable, Equatable {
    public var file: URL?
    public var key: String
}
