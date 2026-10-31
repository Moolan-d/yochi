import Foundation
import Security

/// Where the Gateway is and the token it expects. The host lives in
/// UserDefaults, the token in the Keychain.
struct GatewayConfig: Equatable {
    static let defaultPort = 7420

    var host: String
    var token: String

    var url: URL? {
        let address = host.contains(":") ? host : "\(host):\(Self.defaultPort)"
        return URL(string: "ws://\(address)/v0/ws")
    }

    private static let hostKey = "gateway.host"
    private static let tokenAccount = "gateway.token"

    static func load() -> GatewayConfig? {
        #if DEBUG
        // `simctl launch` passes SIMCTL_CHILD_COMPANION_* through as these.
        let env = ProcessInfo.processInfo.environment
        if let host = env["COMPANION_HOST"], let token = env["COMPANION_TOKEN"] {
            return GatewayConfig(host: host, token: token)
        }
        #endif
        guard let host = UserDefaults.standard.string(forKey: hostKey),
              let token = Keychain.read(tokenAccount) else { return nil }
        return GatewayConfig(host: host, token: token)
    }

    func save() {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        Keychain.write(token, account: Self.tokenAccount)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        Keychain.delete(tokenAccount)
    }
}

private enum Keychain {
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "companion",
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account)
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
