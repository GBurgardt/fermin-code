import Foundation
import Security

enum KycodeKeychain {
    private static let service = "dev.fermincode.mobile.mobile-bridge"
    private static let legacyAccount = "desktop-auth-token"
    private static let voiceProfileAccount = "voice-isolation.eagle-profile.v1"

    static func loadAuthToken() -> String? {
        loadToken(account: legacyAccount)
    }

    static func saveAuthToken(_ token: String) {
        saveToken(token, account: legacyAccount)
    }

    static func deleteAuthToken() {
        deleteToken(account: legacyAccount)
    }

    static func loadAuthToken(profileId: String) -> String? {
        loadToken(account: profileAccount(profileId: profileId))
    }

    static func saveAuthToken(_ token: String, profileId: String) {
        saveToken(token, account: profileAccount(profileId: profileId))
    }

    static func deleteAuthToken(profileId: String) {
        deleteToken(account: profileAccount(profileId: profileId))
    }

    static func loadVoiceProfile() -> Data? {
        loadData(account: voiceProfileAccount)
    }

    @discardableResult
    static func saveVoiceProfile(_ profile: Data) -> Bool {
        guard !profile.isEmpty else {
            deleteToken(account: voiceProfileAccount)
            return false
        }
        return saveData(
            profile,
            account: voiceProfileAccount,
            accessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    static func deleteVoiceProfile() {
        deleteToken(account: voiceProfileAccount)
    }

    private static func loadToken(account: String) -> String? {
        guard let data = loadData(account: account) else { return nil }
        let token = normalizedToken(String(data: data, encoding: .utf8))
        return token?.isEmpty == false ? token : nil
    }

    private static func loadData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func saveToken(_ token: String, account: String) {
        let trimmed = normalizedToken(token) ?? ""
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            deleteToken(account: account)
            return
        }

        _ = saveData(data, account: account, accessible: kSecAttrAccessibleAfterFirstUnlock)
    }

    @discardableResult
    private static func saveData(
        _ data: Data,
        account: String,
        accessible: CFString
    ) -> Bool {
        let query = baseQuery(account: account)
        let update = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess {
            return true
        }

        var create = query
        create[kSecValueData as String] = data
        create[kSecAttrAccessible as String] = accessible
        return SecItemAdd(create as CFDictionary, nil) == errSecSuccess
    }

    private static func deleteToken(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private static func profileAccount(profileId: String) -> String {
        "desktop-auth-token.\(profileId)"
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
