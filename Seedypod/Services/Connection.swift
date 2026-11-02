import Foundation
import Observation
import Security

/// Which unit the app talks to, remembered across launches. The address lives in
/// UserDefaults; the optional API key (core's ADR-0012) in the Keychain.
@MainActor
@Observable
final class Connection {
    enum Target: Equatable, Sendable {
        case unit(URL)
        case demo
    }

    private(set) var target: Target?
    /// The unit's name from Bonjour, or its host when typed in.
    private(set) var name: String?
    private(set) var api: (any SeedypodAPI)?

    private let defaults: UserDefaults
    private let keychain: KeyStore

    init(defaults: UserDefaults = .standard, keychain: KeyStore = KeyStore()) {
        self.defaults = defaults
        self.keychain = keychain
        if defaults.bool(forKey: Keys.demo) {
            target = .demo
        } else if let raw = defaults.string(forKey: Keys.url), let url = URL(string: raw) {
            target = .unit(url)
        }
        name = defaults.string(forKey: Keys.name)
        api = makeAPI()
    }

    var apiKey: String {
        get { keychain.get() ?? "" }
        set {
            keychain.set(newValue.isEmpty ? nil : newValue)
            api = makeAPI()
        }
    }

    var isDemo: Bool { target == .demo }

    func connect(_ url: URL, name: String?) {
        defaults.set(url.absoluteString, forKey: Keys.url)
        defaults.set(false, forKey: Keys.demo)
        defaults.set(name, forKey: Keys.name)
        self.name = name
        target = .unit(url)
        api = makeAPI()
    }

    func startDemo() {
        defaults.set(true, forKey: Keys.demo)
        defaults.set("Kitchen Gardyn", forKey: Keys.name)
        name = "Kitchen Gardyn"
        target = .demo
        api = makeAPI()
    }

    func disconnect() {
        defaults.removeObject(forKey: Keys.url)
        defaults.removeObject(forKey: Keys.name)
        defaults.set(false, forKey: Keys.demo)
        target = nil
        name = nil
        api = nil
    }

    private func makeAPI() -> (any SeedypodAPI)? {
        switch target {
        case .unit(let url): CoreClient(baseURL: url, apiKey: keychain.get())
        case .demo: DemoClient()
        case nil: nil
        }
    }

    /// Turns what someone typed ("192.168.1.20", "gardyn.local:3000", "http://…") into core's base URL.
    nonisolated static func baseURL(from typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://\(s)" }
        guard var parts = URLComponents(string: s), let host = parts.host, !host.isEmpty,
              parts.scheme == "http" || parts.scheme == "https" else { return nil }
        if parts.port == nil, parts.scheme == "http" { parts.port = 3000 }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private enum Keys {
        static let url = "unitURL"
        static let name = "unitName"
        static let demo = "demoMode"
    }
}

/// One generic-password item holding the unit's API key.
struct KeyStore: Sendable {
    var service = "com.jonathanng.seedypod.apikey"

    func get() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(match as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
