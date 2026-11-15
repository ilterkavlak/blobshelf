import Foundation

/// The parts of an Upstash Blob bucket token the client needs: which bucket it opens, and the
/// hostname label public objects are served under. The password stays inside the token.
public struct BlobToken: Sendable, Equatable {
    public let bucketID: String
    public let hashForDomain: String

    /// Layout (version 2): [version, flags, bucketLen, passwordLen (2 bytes BE), hashLen] + bucketID + password + hash.
    public init?(_ token: String) {
        guard let raw = Data(base64URLEncoded: token.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let b = [UInt8](raw)
        guard b.count >= 6, b[0] == 0x02 else { return nil }
        let bLen = Int(b[2]), pLen = Int(b[3]) << 8 | Int(b[4]), hLen = Int(b[5])
        guard bLen > 0, pLen > 0, hLen > 0, b.count == 6 + bLen + pLen + hLen,
              let bucket = String(bytes: b[6..<(6 + bLen)], encoding: .utf8),
              let hash = String(bytes: b[(6 + bLen + pLen)...], encoding: .utf8),
              Self.isHostLabel(hash)
        else { return nil }
        bucketID = bucket
        hashForDomain = hash
    }

    /// The hash becomes a hostname label in public links, so it must not be able to name another host.
    private static func isHostLabel(_ s: String) -> Bool {
        s.utf8.count <= 63 && s.utf8.allSatisfy { (0x61...0x7a).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2d }
    }
}

extension Data {
    init?(base64URLEncoded s: String) {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        self.init(base64Encoded: b64)
    }
}
