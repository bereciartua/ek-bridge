import Foundation

/// The two secrets a client can hold, each in its own private file.
enum CredentialKind: Hashable, CaseIterable {
    /// The CLI's Ed25519 key: `<uuid>.json`, `{"clientID","key":"ekb_v1_…"}`.
    case signingKey
    /// The MCP bearer token: `<uuid>.mcp-token`, the bare token with no newline,
    /// so agents can read it directly (`${file:…}`, `$(cat …)`, the launcher).
    case mcpToken
    /// Remote Access: the token a cloud agent sends through a tunnel. Unlike
    /// the local token, it's pasted into the vendor's settings.
    case remoteToken

    var fileSuffix: String { file.fileSuffix }
    var maxBytes: Int { file.maxBytes }

    /// The file BridgeKitCore's `SecretFileStore` keeps it in.
    var file: SecretFileKind {
        switch self {
        case .signingKey: SecretFileKind(fileSuffix: ".json", maxBytes: 512)
        case .mcpToken: .mcpKey
        case .remoteToken: SecretFileKind(fileSuffix: ".mcp-remote-token", maxBytes: 128)
        }
    }
}

// Private credentials live outside the registry, which stores only verifiers,
// in BridgeKitCore's SecretFileStore (0600 files in a 0700 folder, written
// atomically, never through a symlink). The path is fixed by client UUID; no
// caller-supplied path enters file APIs. This protects against other UIDs,
// not a malicious process with the same UID.
final class ClientCredentialFiles {
    private let store: SecretFileStore

    init(parent override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        store = SecretFileStore(parent: override ?? AppIdentity.dataFolder(inSupport: support),
                                folderName: "client-credentials")
    }

    func url(for clientID: String, kind: CredentialKind = .signingKey) -> URL? {
        store.url(for: clientID, kind: kind.file)
    }

    /// Whether the file exists and is safe, without reading it.
    func status(clientID: String, kind: CredentialKind = .signingKey) -> CredentialFileStatus {
        store.status(clientID: clientID, kind: kind.file)
    }

    func canReplace(clientID: String, kind: CredentialKind = .signingKey)
        -> Result<URL, CredentialFileError> {
        store.canReplace(clientID: clientID, kind: kind.file)
    }

    func saveNew(clientID: String, key: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, kind: .signingKey, secret: key, replacing: false)
    }

    func replace(clientID: String, key: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, kind: .signingKey, secret: key, replacing: true)
    }

    func saveNew(clientID: String, token: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, kind: .mcpToken, secret: token, replacing: false)
    }

    func replace(clientID: String, token: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, kind: .mcpToken, secret: token, replacing: true)
    }

    /// Writes a remote token, replacing an existing safe file.
    func save(clientID: String, remoteToken: String) -> Result<URL, CredentialFileError> {
        let replacing = status(clientID: clientID, kind: .remoteToken) == .present
        return write(clientID: clientID, kind: .remoteToken, secret: remoteToken, replacing: replacing)
    }

    func remove(clientID: String, kind: CredentialKind = .signingKey)
        -> Result<Void, CredentialFileError> {
        store.remove(clientID: clientID, kind: kind.file)
    }

    private func write(clientID: String, kind: CredentialKind, secret: String, replacing: Bool)
        -> Result<URL, CredentialFileError> {
        guard store.url(for: clientID, kind: kind.file) != nil,
              let data = Self.contents(clientID: clientID, kind: kind, secret: secret) else {
            return .failure(.invalidCredential)
        }
        return store.write(clientID: clientID, kind: kind.file, data: data, replacing: replacing)
    }

    private static func contents(clientID: String, kind: CredentialKind, secret: String) -> Data? {
        switch kind {
        case .signingKey:
            guard AgentKey.isValid(secret, prefix: "ekb_v1_") else { return nil }
            return try? JSONSerialization.data(withJSONObject: [
                "clientID": UUID(uuidString: clientID)!.uuidString.lowercased(),
                "key": secret,
            ], options: [.sortedKeys])
        case .mcpToken:
            guard AgentKey.isValid(secret, prefix: "ekb_mcp_v1_") else { return nil }
            return Data(secret.utf8)
        case .remoteToken:
            guard AgentKey.isValid(secret, prefix: "ekb_mcpr_v1_") else { return nil }
            return Data(secret.utf8)
        }
    }
}
