import CryptoKit
import Foundation
import UniformTypeIdentifiers

public final class S3Client: Sendable {
    public static let multipartThreshold: Int64 = 64 << 20
    static let minPartSize: Int64 = 16 << 20
    static let maxParts: Int64 = 10_000
    static let partConcurrency = 4

    public let credentials: CredentialProvider
    private let session: URLSession

    public convenience init(credentials: CredentialProvider) {
        self.init(credentials: credentials, session: HTTP.session)
    }

    init(credentials: CredentialProvider, session: URLSession) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: Listing

    public func list(prefix: String, delimiter: String?, continuationToken: String? = nil,
                     maxKeys: Int? = nil) async throws -> ListPage {
        var query = [("list-type", "2"), ("prefix", prefix)]
        if let delimiter { query.append(("delimiter", delimiter)) }
        if let continuationToken { query.append(("continuation-token", continuationToken)) }
        if let maxKeys { query.append(("max-keys", String(maxKeys))) }
        let (data, _) = try await send("GET", key: nil, query: query)
        guard let page = S3XML.listPage(data) else {
            throw S3Error(status: 200, code: "MalformedResponse", message: "Could not read the object listing.")
        }
        return page
    }

    public func listAll(prefix: String, delimiter: String? = nil) async throws -> ListPage {
        var result = ListPage()
        var token: String?
        repeat {
            let page = try await list(prefix: prefix, delimiter: delimiter, continuationToken: token)
            result.objects += page.objects
            result.commonPrefixes += page.commonPrefixes
            token = page.nextContinuationToken
        } while token != nil
        return result
    }

    public func exists(_ key: String) async throws -> Bool {
        do {
            _ = try await send("HEAD", key: key)
            return true
        } catch let error as S3Error where error.status == 404 {
            return false
        }
    }

    // MARK: Writing

    public func putData(_ data: Data, key: String) async throws {
        _ = try await send("PUT", key: key, body: .data(data))
    }

    /// Large files go up in parts, so they are not bound by the single-PUT size limit.
    public func putFile(_ file: URL, key: String, progress: ProgressHandler? = nil) async throws {
        let size = try Int64(file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let contentType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        if size >= Self.multipartThreshold {
            try await multipartUpload(SourceFile(file), key: key, contentType: contentType, progress: progress)
        } else {
            _ = try await send("PUT", key: key, headers: ["Content-Type": contentType], body: .file(file), progress: progress)
        }
    }

    public func copy(from source: String, to destination: String) async throws {
        let bucket = try await credentials.credentials().bucket
        let copySource = "/" + KeyEncoding.encode(bucket) + "/" + KeyEncoding.encode(source, keepSlash: true)
        let (data, response) = try await send("PUT", key: destination, headers: ["x-amz-copy-source": copySource])
        if let error = S3XML.embeddedError(data, status: response.statusCode) { throw error }
    }

    public func delete(_ key: String) async throws {
        _ = try await send("DELETE", key: key)
    }

    /// Throws if any key could not be deleted.
    public func deleteMany(_ keys: [String]) async throws {
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = keys[start..<min(start + 1000, keys.count)]
            let body = "<Delete><Quiet>true</Quiet>"
                + batch.map { "<Object><Key>\(S3XML.escape($0))</Key></Object>" }.joined()
                + "</Delete>"
            let data = Data(body.utf8)
            let md5 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()
            let (resp, _) = try await send("POST", key: nil, query: [("delete", "")],
                                           headers: ["Content-MD5": md5, "Content-Type": "application/xml"],
                                           body: .data(data))
            if let first = S3XML.deleteErrors(resp).first {
                throw S3Error(status: 200, code: "DeleteFailed", message: "Could not delete \(first.key): \(first.message)")
            }
        }
    }

    // MARK: Reading

    /// Downloads an object to `destination`, replacing any file already there.
    public func download(_ key: String, to destination: URL, progress: ProgressHandler? = nil) async throws {
        let (temp, _) = try await signedRequest("GET", key: key) { request in
            let (url, response) = try await session.download(for: request, delegate: progress.map(ProgressDelegate.init))
            return (url, response as! HTTPURLResponse)
        } errorBody: { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return (try? Data(contentsOf: url)) ?? Data()
        }
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    // MARK: Multipart

    static func partSize(for size: Int64) -> Int64 {
        let mib: Int64 = 1 << 20
        let needed = (size + maxParts - 1) / maxParts
        return max(minPartSize, (needed + mib - 1) / mib * mib)
    }

    /// `source` is opened before anything else, and its size taken from the open file, so the whole
    /// upload describes one version of the file even if the path is replaced meanwhile.
    private func multipartUpload(_ source: SourceFile, key: String, contentType: String,
                                 progress: ProgressHandler?) async throws {
        let size = source.size
        let (initData, _) = try await send("POST", key: key, query: [("uploads", "")],
                                           headers: ["Content-Type": contentType])
        guard let uploadID = S3XML.uploadID(initData) else {
            throw S3Error(status: 200, code: "MalformedResponse", message: "Multipart upload did not return an upload id.")
        }
        do {
            let partSize = Self.partSize(for: size)
            let partCount = Int((size + partSize - 1) / partSize)
            let parts = progress.map { PartProgress(size: size, handler: $0) }
            var etags = [String](repeating: "", count: partCount)
            try await concurrentForEach(0..<partCount, limit: Self.partConcurrency) { [self] index in
                try await PartBudget.shared.withSlot {
                    try Task.checkCancellation()
                    let offset = Int64(index) * partSize
                    let chunk = try source.read(at: offset, count: Int(min(partSize, size - offset)))
                    let (_, response) = try await send(
                        "PUT", key: key, query: [("partNumber", String(index + 1)), ("uploadId", uploadID)],
                        body: .data(chunk), progress: parts?.handler(forPart: index))
                    guard let etag = response.value(forHTTPHeaderField: "ETag") else {
                        throw S3Error(status: response.statusCode, code: "MalformedResponse", message: "Part \(index + 1) returned no ETag.")
                    }
                    return (index, etag)
                }
            } onResult: { part in
                etags[part.0] = part.1
            }
            let body = "<CompleteMultipartUpload>"
                + etags.enumerated().map { "<Part><PartNumber>\($0.offset + 1)</PartNumber><ETag>\(S3XML.escape($0.element))</ETag></Part>" }.joined()
                + "</CompleteMultipartUpload>"
            let (data, response) = try await send("POST", key: key, query: [("uploadId", uploadID)],
                                                  headers: ["Content-Type": "application/xml"],
                                                  body: .data(Data(body.utf8)))
            if let error = S3XML.embeddedError(data, status: response.statusCode) { throw error }
        } catch {
            // Detached so a cancelled upload still releases its stored parts.
            Task.detached { [self] in
                _ = try? await send("DELETE", key: key, query: [("uploadId", uploadID)])
            }
            throw error
        }
    }

    // MARK: Transport

    enum Body {
        case none
        case data(Data)
        case file(URL)
    }

    private func send(_ method: String, key: String?, query: [(String, String)] = [],
                      headers: [String: String] = [:], body: Body = .none,
                      progress: ProgressHandler? = nil) async throws -> (Data, HTTPURLResponse) {
        try await signedRequest(method, key: key, query: query, headers: headers, body: body) { request in
            let delegate = progress.map(ProgressDelegate.init)
            let (data, response): (Data, URLResponse) = switch body {
            case .none: try await session.data(for: request, delegate: delegate)
            case let .data(payload): try await session.upload(for: request, from: payload, delegate: delegate)
            case let .file(url): try await session.upload(for: request, fromFile: url, delegate: delegate)
            }
            return (data, response as! HTTPURLResponse)
        } errorBody: { $0 }
    }

    /// Signs and performs a request. A 401/403 is retried once with fresh credentials, since the
    /// cached ones may have been revoked or expired between being handed out and reaching R2.
    private func signedRequest<Payload>(
        _ method: String, key: String?, query: [(String, String)] = [], headers: [String: String] = [:],
        body: Body = .none, perform: (URLRequest) async throws -> (Payload, HTTPURLResponse),
        errorBody: (Payload) -> Data
    ) async throws -> (Payload, HTTPURLResponse) {
        var retried = false
        while true {
            let creds = try await credentials.credentials()
            let (payload, response) = try await perform(sign(method, key: key, query: query, headers: headers, body: body, creds: creds))
            let status = response.statusCode
            if (200..<300).contains(status) { return (payload, response) }
            let data = errorBody(payload)
            if (status == 401 || status == 403) && !retried {
                retried = true
                await credentials.invalidate()
                continue
            }
            throw S3XML.error(data, status: status)
        }
    }

    private func sign(_ method: String, key: String?, query: [(String, String)], headers: [String: String],
                      body: Body, creds: BlobCredentials) -> URLRequest {
        var path = creds.endpoint.absoluteString
        if path.hasSuffix("/") { path.removeLast() }
        path += "/" + KeyEncoding.encode(creds.bucket)
        if let key { path += "/" + KeyEncoding.encode(key, keepSlash: true) }
        if !query.isEmpty { path += "?" + KeyEncoding.query(query) }
        var request = URLRequest(url: URL(string: path)!)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let payloadHash: String = switch body {
        case .none: SigV4.emptyPayloadHash
        case let .data(data): data.count <= 1 << 20 ? SigV4.sha256Hex(data) : SigV4.unsignedPayload
        case .file: SigV4.unsignedPayload
        }
        SigV4.sign(&request, with: SigningCredentials(accessKeyId: creds.accessKeyId,
                                                      secretAccessKey: creds.secretAccessKey,
                                                      sessionToken: creds.sessionToken,
                                                      region: creds.region),
                   payloadHash: payloadHash)
        return request
    }
}

/// A file held open for a whole multipart upload, so every part comes from the same file even if
/// the path is replaced meanwhile (as editors do when saving). Positional reads are thread-safe.
final class SourceFile: Sendable {
    let size: Int64
    private let descriptor: Int32
    private let name: String

    init(_ url: URL) throws {
        name = url.lastPathComponent
        descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw Self.posixError() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = Self.posixError()
            close(descriptor)
            throw error
        }
        size = Int64(info.st_size)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    deinit { close(descriptor) }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        try data.withUnsafeMutableBytes { buffer in
            while filled < count {
                let n = pread(descriptor, buffer.baseAddress! + filled, count - filled, off_t(offset) + off_t(filled))
                if n < 0 && errno == EINTR { continue }
                if n < 0 { throw Self.posixError() }
                if n == 0 { break }
                filled += n
            }
        }
        guard filled == count else {
            throw S3Error(status: 0, code: "SourceChanged", message: "\(name) changed while it was being uploaded.")
        }
        return data
    }
}
