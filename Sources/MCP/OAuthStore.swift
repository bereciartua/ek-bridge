import CryptoKit
import Darwin
import Foundation

/// One cloud app the user allowed for one bridge client (MCP-PLAN §22.6). Only SHA-256 digests of
/// its tokens are stored, never the tokens.
struct OAuthConnection: Codable, Equatable {
    let id: UUID
    /// The bridge client (registry UUID) whose grants the app uses.
    let clientID: String
    let appName: String
    /// The OAuth client: a CIMD URL or a `dcr_` registration.
    let oauthClientID: String
    let createdAt: Date
    var lastUsedAt: Date?
    /// The audience every access token of this connection is bound to.
    let resource: String
    var accessHash: String
    var accessExpiresAt: Date
    var refreshHash: String
    var refreshExpiresAt: Date
    /// Rotated-out refresh tokens, newest last. Presenting one means a copy leaked (reuse detection).
    var previousRefreshHashes: [String]
    /// When the refresh token last rotated, and whether the access token from that rotation has been
    /// used since: a lost token response may be retried with the previous refresh token briefly.
    var rotatedAt: Date? = nil
    var usedSinceRotation: Bool? = nil
}

/// A registered OAuth client: a Dynamic Client Registration (RFC 7591, `dcr_`), the fallback for
/// clients without CIMD, or a confidential client the user set up in the app for one bridge client
/// (`cfg_`, for apps such as Gemini Enterprise that take a client ID and secret).
struct OAuthRegistration: Codable, Equatable {
    let clientID: String
    let clientName: String?
    let redirectURIs: [String]
    let createdAt: Date
    var lastUsedAt: Date?
    /// SHA-256 of the client secret; `cfg_` registrations only.
    var secretHash: String? = nil
    /// The bridge client a `cfg_` registration may pair with.
    var bridgeClientID: String? = nil

    var isConfidential: Bool { clientID.hasPrefix("cfg_") }
}

/// `remote-connections.json`, mode 0600, written atomically with fsync. Like the client registry it
/// fails closed: a file with the wrong owner, mode, type, size or contents makes the store unavailable
/// and nothing is accepted or overwritten. Main thread only.
final class OAuthStore {
    struct State: Codable, Equatable {
        var version = OAuthStore.version
        var connections = [OAuthConnection]()
        var registrations = [OAuthRegistration]()
    }

    static let version = 1
    static let fileName = "remote-connections.json"
    static let maxFileBytes = 2_000_000
    static let maxConnections = 200
    static let maxRegistrations = 100
    static let maxPreviousRefreshHashes = 16
    static let maxNameBytes = 100
    static let maxURIBytes = 2048

    private let directory: URL
    private let file: URL
    /// Nil once loading or writing failed.
    private(set) var state: State?

    init(directory: URL) {
        self.directory = directory
        file = directory.appendingPathComponent(Self.fileName)
        state = Self.load(directory: directory, file: file)
    }

    var isAvailable: Bool { state != nil }

    /// Applies `change` and writes the file. A failed write makes the store unavailable.
    @discardableResult
    func update(persist: Bool = true, _ change: (inout State) -> Void) -> Bool {
        guard var next = state else { return false }
        change(&next)
        guard persist else { state = next; return true }
        guard write(next) else { state = nil; return false }
        state = next
        return true
    }

    /// Writes the current state, for changes made with `persist: false`.
    @discardableResult
    func flush() -> Bool { update { _ in } }

    private static func load(directory: URL, file: URL) -> State? {
        var info = stat()
        if lstat(directory.path, &info) != 0 { return errno == ENOENT ? State() : nil }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
        else { return nil }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? State() : nil }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= maxFileBytes,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: maxFileBytes + 1),
              data.count <= maxFileBytes,
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              valid(decoded) else { return nil }
        return decoded
    }

    private static func valid(_ state: State) -> Bool {
        let connections = state.connections
        let registrations = state.registrations
        return state.version == version
            && connections.count <= maxConnections && registrations.count <= maxRegistrations
            && Set(connections.map(\.id)).count == connections.count
            && Set(connections.map(\.accessHash)).count == connections.count
            && Set(connections.map(\.refreshHash)).count == connections.count
            && Set(registrations.map(\.clientID)).count == registrations.count
            && connections.allSatisfy { connection in
                UUID(uuidString: connection.clientID) != nil && validName(connection.appName)
                    && validText(connection.oauthClientID, max: maxURIBytes)
                    && validText(connection.resource, max: maxURIBytes)
                    && validHash(connection.accessHash) && validHash(connection.refreshHash)
                    && connection.previousRefreshHashes.count <= maxPreviousRefreshHashes
                    && connection.previousRefreshHashes.allSatisfy(validHash)
            }
            && registrations.allSatisfy { registration in
                validText(registration.clientID, max: 64)
                    && (registration.isConfidential
                        ? registration.secretHash.map(validHash) == true
                            && registration.bridgeClientID.flatMap(UUID.init(uuidString:)) != nil
                        : registration.clientID.hasPrefix("dcr_") && registration.secretHash == nil
                            && registration.bridgeClientID == nil)
                    && (registration.clientName.map(validName) ?? true)
                    && (1...5).contains(registration.redirectURIs.count)
                    && registration.redirectURIs.allSatisfy { validText($0, max: maxURIBytes) }
            }
    }

    static func validName(_ name: String) -> Bool { validText(name, max: maxNameBytes) }

    private static func validText(_ text: String, max: Int) -> Bool {
        !text.isEmpty && text.utf8.count <= max && text.rangeOfCharacter(from: .controlCharacters) == nil
    }

    static func validHash(_ hash: String) -> Bool { Hex.decode(hash) != nil }

    /// Plain SHA-256 is deliberate (as for MCP tokens, §6.4): every token carries 256 random bits,
    /// so there is nothing to brute-force and a slow password hash would only add latency.
    static func digest(_ token: String) -> String { Hex.encode(Data(SHA256.hash(data: Data(token.utf8)))) }

    private func write(_ next: State) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(next), data.count <= Self.maxFileBytes else { return false }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { return false }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { return false }
        // Never replace a file that wouldn't have loaded (wrong owner, type or mode).
        if lstat(file.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0
            else { return false }
        } else if errno != ENOENT {
            return false
        }
        guard SafePath.atomicWrite(data, to: file.path) else { return false }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        return fsync(directoryFD) == 0
    }
}
