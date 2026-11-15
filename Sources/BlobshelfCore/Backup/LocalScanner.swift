import Foundation

public struct LocalFile: Codable, Hashable, Sendable {
    public var size: Int64
    public var mtime: Double

    public init(size: Int64, mtime: Double) {
        self.size = size
        self.mtime = mtime
    }
}

public struct ScanResult: Sendable {
    public var files: [String: LocalFile] = [:]
    public var unreadable = 0
}

public enum LocalScanner {
    /// Regular files under `root`, keyed by "/"-separated path relative to it. Symlinks are skipped;
    /// so is anything inside `skipping` (the app's own state, which changes on every run).
    public static func scan(_ root: URL, excludes: ExcludeMatcher, skipping: [URL] = []) -> ScanResult {
        let root = root.resolvingSymlinksInPath()
        let skipped = skipping.map { $0.resolvingSymlinksInPath().path + "/" }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var result = ScanResult()
        var errors = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) { _, _ in
            errors += 1
            return true
        }
        while let enumerator, let url = enumerator.nextObject() as? URL {
            let rel = relativePath(url, enumerator)
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                result.unreadable += 1
                continue
            }
            if values.isDirectory == true {
                let resolved = url.resolvingSymlinksInPath().path + "/"
                if excludes.excludes(rel) || skipped.contains(where: { resolved.hasPrefix($0) }) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, !excludes.excludes(rel) else { continue }
            result.files[rel] = LocalFile(size: Int64(values.fileSize ?? 0),
                                          mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        result.unreadable += errors
        return result
    }

    /// The enumerator may report paths through a different but equivalent prefix than `root`
    /// (/var vs /private/var), so the relative path is taken from its depth, not by stripping a prefix.
    static func relativePath(_ url: URL, _ enumerator: FileManager.DirectoryEnumerator) -> String {
        url.pathComponents.suffix(enumerator.level).joined(separator: "/")
    }
}
