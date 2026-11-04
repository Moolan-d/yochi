import Foundation
import Security

/// The paired Gateway: where it is, and this device's token for it. The host
/// and device ID live in UserDefaults, the token in the Keychain.
struct GatewayConfig: Equatable {
    static let defaultPort = 7420

    var host: String
    var token: String
    /// The Gateway's ID for this device, as `yochi devices` lists it.
    var device: String?

    var url: URL? {
        Self.endpoint(host: host, path: "/v0/ws")
    }

    static func endpoint(host: String, path: String) -> URL? {
        URL(string: "ws://\(address(host))\(path)")
    }

    private static func address(_ host: String) -> String {
        host.contains(":") ? host : "\(host):\(defaultPort)"
    }

    private static let hostKey = "gateway.host"
    private static let deviceKey = "gateway.device"
    private static let tokenAccount = "gateway.token"

    static func load() -> GatewayConfig? {
        #if DEBUG
        // `simctl launch` passes SIMCTL_CHILD_COMPANION_* through as these.
        let env = ProcessInfo.processInfo.environment
        // UI tests start unpaired.
        if env["COMPANION_RESET"] != nil {
            clear()
            AgentMessageStore.clearAllDrafts()
        }
        if let host = env["COMPANION_HOST"], let token = env["COMPANION_TOKEN"] {
            return GatewayConfig(host: host, token: token)
        }
        #endif
        guard let host = UserDefaults.standard.string(forKey: hostKey),
              let token = Keychain.read(tokenAccount) else { return nil }
        return GatewayConfig(host: host, token: token, device: UserDefaults.standard.string(forKey: deviceKey))
    }

    func save() {
        UserDefaults.standard.set(host, forKey: Self.hostKey)
        UserDefaults.standard.set(device, forKey: Self.deviceKey)
        Keychain.write(token, account: Self.tokenAccount)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: hostKey)
        UserDefaults.standard.removeObject(forKey: deviceKey)
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
