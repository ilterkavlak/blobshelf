import Foundation

public struct S3Object: Sendable, Equatable {
    public var key: String
    public var size: Int64
    public var lastModified: Date?
}

public struct ListPage: Sendable, Equatable {
    public var objects: [S3Object] = []
    public var commonPrefixes: [String] = []
    public var nextContinuationToken: String?
}

public struct S3Error: LocalizedError, Equatable {
    public var status: Int
    public var code: String
    public var message: String

    public var errorDescription: String? {
        message.isEmpty ? "\(code) (HTTP \(status))" : "\(message) (\(code))"
    }
}

/// A minimal element tree; S3 responses are small, flat documents.
final class XMLElementNode {
    let name: String
    var text = ""
    var children: [XMLElementNode] = []

    init(name: String) { self.name = name }

    func child(_ name: String) -> XMLElementNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLElementNode] { children.filter { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text }
}

enum S3XML {
    static func parse(_ data: Data) -> XMLElementNode? {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }

    static func listPage(_ data: Data) -> ListPage? {
        guard let root = parse(data), root.name == "ListBucketResult" else { return nil }
        var page = ListPage()
        page.objects = root.all("Contents").compactMap { c in
            guard let key = c.value("Key") else { return nil }
            return S3Object(key: key, size: Int64(c.value("Size") ?? "") ?? 0,
                            lastModified: c.value("LastModified").flatMap(date))
        }
        page.commonPrefixes = root.all("CommonPrefixes").compactMap { $0.value("Prefix") }
        if root.value("IsTruncated") == "true" {
            page.nextContinuationToken = root.value("NextContinuationToken")
        }
        return page
    }

    static func error(_ data: Data, status: Int) -> S3Error {
        embeddedError(data, status: status)
            ?? S3Error(status: status, code: "HTTP\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status))
    }

    /// S3 can answer 200 to CopyObject / CompleteMultipartUpload and still report an error in the body.
    static func embeddedError(_ data: Data, status: Int) -> S3Error? {
        guard let root = parse(data), root.name == "Error" else { return nil }
        return S3Error(status: status, code: root.value("Code") ?? "Unknown", message: root.value("Message") ?? "")
    }

    static func uploadID(_ data: Data) -> String? {
        parse(data)?.value("UploadId")
    }

    static func deleteErrors(_ data: Data) -> [(key: String, message: String)] {
        guard let root = parse(data) else { return [] }
        return root.all("Error").map { ($0.value("Key") ?? "", $0.value("Message") ?? $0.value("Code") ?? "") }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeDate = Date.ISO8601FormatStyle()

    private static func date(_ s: String) -> Date? {
        (try? fractionalDate.parse(s)) ?? (try? wholeDate.parse(s))
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: XMLElementNode?
        private var stack: [XMLElementNode] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = XMLElementNode(name: name)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}
