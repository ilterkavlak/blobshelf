import CryptoKit
import Foundation

struct SigningCredentials: Sendable {
    var accessKeyId: String
    var secretAccessKey: String
    var sessionToken: String?
    var region: String
}

/// AWS Signature Version 4 for S3, header-based. The request's URL must already be encoded with
/// `KeyEncoding`, which is what S3 expects in the canonical request.
enum SigV4 {
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    static let emptyPayloadHash = sha256Hex(Data())
    private static let amzDateStyle = Date.ISO8601FormatStyle(dateSeparator: .omitted, dateTimeSeparator: .standard,
                                                               timeSeparator: .omitted, timeZone: .gmt)

    static func sign(_ request: inout URLRequest, with creds: SigningCredentials,
                     payloadHash: String, date: Date = Date(), service: String = "s3") {
        let amzDate = date.formatted(amzDateStyle)
        let day = String(amzDate.prefix(8))
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        if let token = creds.sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var host = url.host ?? ""
        if let port = url.port, !((url.scheme == "https" && port == 443) || (url.scheme == "http" && port == 80)) {
            host += ":\(port)"
        }
        var headers: [String: String] = ["host": host]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers[name.lowercased()] = value.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        let names = headers.keys.sorted()
        let signedHeaders = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0]!)\n" }.joined()

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let pairs: [(String, String)] = (components.percentEncodedQuery ?? "")
            .split(separator: "&", omittingEmptySubsequences: true)
            .map { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        let query = pairs
            .sorted { a, b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            request.httpMethod ?? "GET", path, query, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(day)/\(creds.region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256Hex(Data(canonicalRequest.utf8))]
            .joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(creds.secretAccessKey)".utf8))
        for part in [day, creds.region, service, "aws4_request"] {
            key = SymmetricKey(data: hmac(key, part))
        }
        let signature = hmac(key, stringToSign).map { String(format: "%02x", $0) }.joined()

        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyId)/\(scope),SignedHeaders=\(signedHeaders),Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: SymmetricKey, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }
}
