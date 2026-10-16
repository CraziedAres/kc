import Foundation
import Security

/// A thin wrapper over the macOS login Keychain that stores secrets as
/// generic-password items. Every item lives under a single `service`, and the
/// secret's name is the item's account, so secrets show up in Keychain Access
/// as "<service>" entries and are easy to find or remove by hand.
public struct Keychain {
    public static let defaultService = "kc"

    public let service: String

    public init(service: String = Keychain.defaultService) {
        self.service = service
    }

    /// Stores `value` under `name`, replacing any existing value.
    public func set(_ name: String, value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(baseQuery(name) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = baseQuery(name)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service): \(name)"
            try check(SecItemAdd(add as CFDictionary, nil))
        default:
            throw KeychainError(status: status)
        }
    }

    /// Returns the secret stored under `name`, or nil if there isn't one.
    public func get(_ name: String) throws -> String? {
        var query = baseQuery(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)

        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return value
    }

    /// Deletes the secret stored under `name`. Returns false if it didn't exist.
    @discardableResult
    public func delete(_ name: String) throws -> Bool {
        let status = SecItemDelete(baseQuery(name) as CFDictionary)
        if status == errSecItemNotFound { return false }
        try check(status)
        return true
    }

    /// Names of every secret in this service, sorted. Reads attributes only,
    /// so it never triggers a Keychain access prompt.
    public func list() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)

        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func baseQuery(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
