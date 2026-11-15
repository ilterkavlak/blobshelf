import Foundation

/// URI encoding as SigV4 defines it: everything but RFC 3986 unreserved characters is
/// percent-encoded (UTF-8, upper-case hex). The same string goes on the wire and into the
/// canonical request, so the two can never disagree.
enum KeyEncoding {
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
    private static let unreservedAndSlash = unreserved.union(CharacterSet(charactersIn: "/"))

    static func encode(_ s: String, keepSlash: Bool = false) -> String {
        s.addingPercentEncoding(withAllowedCharacters: keepSlash ? unreservedAndSlash : unreserved) ?? s
    }

    static func query(_ items: [(String, String)]) -> String {
        items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
