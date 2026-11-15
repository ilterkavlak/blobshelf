import Foundation

/// Chooses local paths for downloaded objects so no two objects ever share one. Names that differ
/// only in case are the same file on the default macOS volume, and an upload-only backup can hold
/// both a file "a" and files under "a/" — each remote directory gets its own local directory and
/// each file its own name ("x 2.txt"). Every path returned is inside the directory it was given.
public struct LocalPathAllocator: Sendable {
    private var reserved: Set<String> = []
    private var directories: [String: URL] = [:]

    public init() {}

    /// A new, unused name for a top-level download (a file, or the root of a folder download).
    public mutating func top(_ name: String, in directory: URL) -> URL {
        let parts = Self.components(name)
        return unique(parts?.count == 1 ? parts![0] : "download", in: directory)
    }

    /// The local directory standing for remote directory `relativePath` (e.g. "trip/day1/") under `base`.
    public mutating func directory(_ relativePath: String, under base: URL) -> URL? {
        guard let parts = Self.components(relativePath) else { return nil }
        return parts.reduce(base) { dir($1, in: $0) }
    }

    /// A unique local file for remote file `relativePath` under `base`; nil for paths with "." or ".." segments.
    public mutating func file(_ relativePath: String, under base: URL) -> URL? {
        guard var parts = Self.components(relativePath) else { return nil }
        let name = parts.removeLast()
        return unique(name, in: parts.reduce(base) { dir($1, in: $0) })
    }

    private mutating func dir(_ name: String, in parent: URL) -> URL {
        let key = parent.path + "/" + name
        if let known = directories[key] { return known }
        let url = unique(name, in: parent)
        directories[key] = url
        return url
    }

    private mutating func unique(_ name: String, in parent: URL) -> URL {
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var candidate = parent.appending(path: name)
        var n = 2
        while reserved.contains(candidate.path.lowercased()) || FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        reserved.insert(candidate.path.lowercased())
        return candidate
    }

    static func components(_ path: String) -> [String]? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return parts
    }
}
