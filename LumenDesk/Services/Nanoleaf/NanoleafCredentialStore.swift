import Foundation
import Security

protocol NanoleafCredentialStoring {
    func load() throws -> [NanoleafPairing]
    func save(_ pairings: [NanoleafPairing]) throws
}

final class NanoleafCredentialStore: NanoleafCredentialStoring {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.lumendesk.nanoleaf",
         kSecAttrAccount as String: "paired-controllers"]
    }

    func load() throws -> [NanoleafPairing] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data,
              let pairings = try? JSONDecoder().decode([NanoleafPairing].self, from: data) else {
            throw NanoleafError.storageFailure
        }
        return pairings
    }

    func save(_ pairings: [NanoleafPairing]) throws {
        let data = try JSONEncoder().encode(pairings)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else {
                throw NanoleafError.storageFailure
            }
        } else if status != errSecSuccess {
            throw NanoleafError.storageFailure
        }
    }
}
