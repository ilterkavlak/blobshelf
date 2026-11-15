import Foundation

/// Short-lived S3 credentials for one bucket, as returned by `POST /v1/credentials`.
public struct BlobCredentials: Codable, Sendable, Equatable {
    public var accessKeyId: String
    public var secretAccessKey: String
    public var sessionToken: String
    public var endpoint: URL
    public var bucket: String
    public var region: String
    public var expiresAt: Date
    public var visibility: String
    public var permission: String
    public var readOnlyReason: String?

    public var isReadOnly: Bool { permission == "object-read-only" }
    public var isPublic: Bool { visibility == "public" }
}

public enum BlobError: LocalizedError, Equatable {
    case invalidToken
    case credentials(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "This is not a valid Upstash Blob bucket token."
        case let .credentials(status, message): "Upstash Blob refused the token (\(status)): \(message)"
        }
    }
}

public protocol CredentialsFetching: Sendable {
    func fetch() async throws -> BlobCredentials
}

/// Exchanges a bucket token for credentials. Both hosts are fixed: the token only ever goes to
/// Upstash, and the credentials it returns are only ever used against Cloudflare R2.
public struct CredentialsAPI: CredentialsFetching {
    public static let publicHostSuffix = "blob.upstash.io"
    static let url = URL(string: "https://blob.upstash.io/v1/credentials")!
    static let storageHostSuffix = ".r2.cloudflarestorage.com"

    let token: String

    public init(token: String) { self.token = token }

    public func fetch() async throws -> BlobCredentials {
        var req = URLRequest(url: Self.url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await HTTP.session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw BlobError.credentials(status: status, message: message)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let credentials = try decoder.decode(BlobCredentials.self, from: data)
        guard Self.isStorageEndpoint(credentials.endpoint) else {
            throw BlobError.credentials(status: status, message: "the storage endpoint is not an HTTPS Cloudflare R2 address")
        }
        return credentials
    }

    static func isStorageEndpoint(_ url: URL) -> Bool {
        url.scheme == "https" && url.host()?.hasSuffix(storageHostSuffix) == true
    }
}
