import Darwin

/// Shell globs matched against each path component ("*.tmp", ".git"), or against the whole
/// relative path when the pattern contains a "/" ("build/*.o").
public struct ExcludeMatcher: Sendable {
    let patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public func excludes(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/").map(String.init)
        return patterns.contains { pattern in
            pattern.contains("/")
                ? fnmatch(pattern, relativePath, 0) == 0
                : components.contains { fnmatch(pattern, $0, 0) == 0 }
        }
    }
}
