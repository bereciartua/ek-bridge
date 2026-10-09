import Darwin
import Foundation

enum CredentialFileStatus: Equatable {
    case present
    case missing
    /// Wrong owner, mode, type or size: never replaced automatically.
    case unsafe
}

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

    var fileSuffix: String {
        switch self {
        case .signingKey: ".json"
        case .mcpToken: ".mcp-token"
        case .remoteToken: ".mcp-remote-token"
        }
    }
    var maxBytes: Int { self == .signingKey ? 512 : 128 }
}

enum CredentialFileError: String, Error {
    case invalidCredential
    case unsafeDirectory
    case unsafeExistingFile
    case alreadyExists
    case missingFile
    case writeFailed
    case removeFailed
}

// Private credentials live outside the registry, which stores only verifiers.
// The path is fixed by client UUID; no caller-supplied path enters file APIs.
// This protects against other UIDs, not a malicious process with the same UID.
final class ClientCredentialFiles {
    private let parent: URL
    private let directory: URL

    init(parent override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        parent = override ?? AppIdentity.dataFolder(inSupport: support)
        directory = parent.appendingPathComponent("client-credentials", isDirectory: true)
    }

    func url(for clientID: String, kind: CredentialKind = .signingKey) -> URL? {
        guard let uuid = UUID(uuidString: clientID) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString.lowercased() + kind.fileSuffix)
    }

    /// Whether the file exists and is safe, without reading it.
    func status(clientID: String, kind: CredentialKind = .signingKey) -> CredentialFileStatus {
        guard let destination = url(for: clientID, kind: kind) else { return .unsafe }
        var info = stat()
        // Folders that exist must be private and owned, or nothing is written.
        for folder in [parent, directory] {
            if lstat(folder.path, &info) != 0 {
                if errno == ENOENT { return .missing }
                return .unsafe
            }
            guard Self.safeDirectory(info) else { return .unsafe }
        }
        if lstat(destination.path, &info) != 0 { return errno == ENOENT ? .missing : .unsafe }
        return Self.safe(info, kind: kind) ? .present : .unsafe
    }

    func canReplace(clientID: String, kind: CredentialKind = .signingKey)
        -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID, kind: kind) else {
            return .failure(.invalidCredential)
        }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            guard Self.safeFile(name: destination.lastPathComponent, kind: kind, in: fd) else {
                return .failure(.unsafeExistingFile)
            }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
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
        guard let destination = url(for: clientID, kind: kind) else {
            return .failure(.invalidCredential)
        }
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 && errno == ENOENT {
            guard lstat(parent.path, &directoryInfo) == 0,
                  Self.safeDirectory(directoryInfo) else { return .failure(.unsafeDirectory) }
            return .success(())
        }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            let name = destination.lastPathComponent
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .success(()) : .failure(.removeFailed)
            }
            guard Self.safe(info, kind: kind) else { return .failure(.unsafeExistingFile) }
            guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else {
                return .failure(.removeFailed)
            }
            return .success(())
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    private func write(clientID: String, kind: CredentialKind, secret: String, replacing: Bool)
        -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID, kind: kind),
              let data = Self.contents(clientID: clientID, kind: kind, secret: secret),
              data.count <= kind.maxBytes else {
            return .failure(.invalidCredential)
        }
        do {
            let directoryFD = try openDirectory(create: !replacing)
            defer { close(directoryFD) }
            let name = destination.lastPathComponent
            var info = stat()
            let exists = fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            if replacing {
                guard exists, Self.safe(info, kind: kind) else { return .failure(.unsafeExistingFile) }
            } else if exists {
                return .failure(.alreadyExists)
            } else if errno != ENOENT {
                return .failure(.unsafeExistingFile)
            }
            let temporary = ".tmp-\(UUID().uuidString.lowercased())"
            let tempFD = openat(directoryFD, temporary,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard tempFD >= 0 else { return .failure(.writeFailed) }
            defer { unlinkat(directoryFD, temporary, 0) }
            guard fchmod(tempFD, 0o600) == 0 else {
                close(tempFD)
                return .failure(.writeFailed)
            }
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(tempFD, base.advanced(by: offset), data.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return fsync(tempFD) == 0
            }
            close(tempFD)
            guard written else { return .failure(.writeFailed) }
            let installed = replacing
                ? renameat(directoryFD, temporary, directoryFD, name) == 0
                : linkat(directoryFD, temporary, directoryFD, name, 0) == 0
            guard installed, fsync(directoryFD) == 0 else { return .failure(.writeFailed) }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        var info = stat()
        guard lstat(parent.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw CredentialFileError.unsafeDirectory
        }
        guard lstat(directory.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialFileError.unsafeDirectory }
        guard fstat(fd, &info) == 0, Self.safeDirectory(info) else {
            close(fd)
            throw CredentialFileError.unsafeDirectory
        }
        return fd
    }

    private static func safeDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() &&
            info.st_mode & 0o077 == 0
    }

    private static func safeFile(name: String, kind: CredentialKind, in directoryFD: Int32) -> Bool {
        var info = stat()
        return fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && safe(info, kind: kind)
    }

    private static func safe(_ info: stat, kind: CredentialKind) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() &&
            info.st_mode & 0o777 == 0o600 && info.st_size <= kind.maxBytes
    }

    private static func contents(clientID: String, kind: CredentialKind, secret: String) -> Data? {
        switch kind {
        case .signingKey:
            guard validSecret(secret, prefix: "ekb_v1_") else { return nil }
            return try? JSONSerialization.data(withJSONObject: [
                "clientID": UUID(uuidString: clientID)!.uuidString.lowercased(),
                "key": secret,
            ], options: [.sortedKeys])
        case .mcpToken:
            guard validSecret(secret, prefix: "ekb_mcp_v1_") else { return nil }
            return Data(secret.utf8)
        case .remoteToken:
            guard validSecret(secret, prefix: "ekb_mcpr_v1_") else { return nil }
            return Data(secret.utf8)
        }
    }

    private static func validSecret(_ secret: String, prefix: String) -> Bool {
        secret.hasPrefix(prefix) && secret.utf8.count == prefix.utf8.count + 64 &&
            secret.utf8.dropFirst(prefix.utf8.count).allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }
}
