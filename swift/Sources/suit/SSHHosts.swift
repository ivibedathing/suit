import Cocoa
import Security

// One saved SSH destination. Only connection metadata lives here (and in
// ssh-hosts.json) — a password-auth host's password is stored exclusively in
// the macOS Keychain, keyed by this id (see SSHKeychain).
struct SSHHost: Codable, Equatable {
    // Raw-String so old files keep decoding if cases are added later.
    enum Auth: String, Codable {
        case key        // ssh key / agent — ssh handles any interaction
        case password   // Keychain-stored password, auto-typed at the prompt
    }

    let id: UUID
    var name: String          // display name; empty falls back to host
    var host: String
    var user: String?
    var port: Int?            // nil = default 22
    var auth: Auth
    var extraOptions: String? // verbatim extra ssh arguments, user-authored

    var displayName: String {
        name.isEmpty ? host : name
    }

    // The list row's detail line: user@host:port · auth.
    var detail: String {
        var target = host
        if let user, !user.isEmpty { target = "\(user)@\(target)" }
        if let port, port != 22 { target += ":\(port)" }
        return target + (auth == .password ? " · password" : " · key")
    }
}

// The saved-hosts list backing the sidebar's SSH tab, stored in
// ~/.suit/ssh-hosts.json like the other stores. Never contains passwords:
// deleting a host also purges its Keychain item.
final class SSHHostsStore {
    static let shared = SSHHostsStore()
    static let didUpdate = Notification.Name("dev.kosych.suit.SSHHostsStore.didUpdate")

    // Optional field so a file written by a future shape still decodes.
    private struct Model: Codable {
        var hosts: [SSHHost]?
    }

    private(set) var hosts: [SSHHost] = []

    // $HOME rather than NSHomeDirectory(), same as the other stores: an
    // overridden $HOME sandboxes the file for harness runs.
    private var fileURL: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home + "/.suit/ssh-hosts.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Model.self, from: data) {
            hosts = decoded.hosts ?? []
        }
    }

    func host(withId id: UUID) -> SSHHost? {
        hosts.first { $0.id == id }
    }

    func add(_ host: SSHHost) {
        hosts.append(host)
        save()
    }

    func update(_ host: SSHHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index] = host
        save()
    }

    func delete(id: UUID) {
        guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
        hosts.remove(at: index)
        SSHKeychain.deletePassword(forHostId: id)
        save()
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Model(hosts: hosts)) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didUpdate, object: self)
    }
}

// Generic-password Keychain items for password-auth hosts: service is fixed,
// account is the host's UUID. Note the app is ad-hoc signed, so every rebuild
// is a different signer and the first Keychain read after a rebuild re-prompts
// ("Suit wants to use…") — expected for a personal app.
enum SSHKeychain {
    private static let service = "dev.kosych.suit.ssh"

    private static func baseQuery(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    @discardableResult
    static func setPassword(_ password: String, forHostId id: UUID) -> Bool {
        // Delete + add is the simplest upsert and also resets the item's ACL
        // to the current binary.
        SecItemDelete(baseQuery(id) as CFDictionary)
        var attributes = baseQuery(id)
        attributes[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func password(forHostId id: UUID) -> String? {
        var query = baseQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(forHostId id: UUID) {
        SecItemDelete(baseQuery(id) as CFDictionary)
    }
}

// Quote a shell word only when needed, so the command typed into the terminal
// reads clean for the common case.
func shellQuote(_ word: String) -> String {
    let safe = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-"
    )
    if !word.isEmpty, word.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return word
    }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// The command an SSH tab types into its shell. extraOptions passes through
// verbatim by contract — it's user-authored shell text (e.g. "-i ~/.ssh/work
// -o Compression=yes"), quoting it would break option combos.
func sshCommand(for host: SSHHost) -> String {
    var parts = ["ssh"]
    if let port = host.port, port != 22 {
        parts += ["-p", String(port)]
    }
    if let extra = host.extraOptions?.trimmingCharacters(in: .whitespaces), !extra.isEmpty {
        parts.append(extra)
    }
    var target = host.host
    if let user = host.user, !user.isEmpty {
        target = "\(user)@\(target)"
    }
    parts.append(shellQuote(target))
    return parts.joined(separator: " ")
}
