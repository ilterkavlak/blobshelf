import Foundation
import Security

/// Bucket tokens, stored as generic passwords keyed by bucket id.
public struct Keychain: Sendable {
    let service: String

    public init(service: String) { self.service = service }

    public func save(_ secret: String, account: String) throws {
        delete(account: account)
        let status = SecItemAdd(query(account, [kSecValueData: Data(secret.utf8)]), nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func read(account: String) throws -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query(account, [kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]), &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) {
        SecItemDelete(query(account))
    }

    private func query(_ account: String, _ extra: [CFString: Any] = [:]) -> CFDictionary {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        return base.merging(extra) { $1 } as CFDictionary
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        "Keychain error: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "\(status)")
    }
}
