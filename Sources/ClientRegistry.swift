import CryptoKit
import Darwin
import Foundation

enum ClientResource: String, Codable { case calendar, reminderList }

struct ClientGrant: Codable, Equatable {
    let resource: ClientResource
    let targetID: String
    let mask: Int

    static let read = 1
    static let create = 2
    static let edit = 4
    static let delete = 8
    static let complete = 16

    var isValid: Bool {
        let allowed = resource == .calendar ? 15 : 31
        return !targetID.isEmpty && targetID.utf8.count <= 512 &&
            targetID.rangeOfCharacter(from: .controlCharacters) == nil &&
            mask > 0 && mask & ~allowed == 0
    }

    func allows(_ command: BridgeCommand) -> Bool {
        let required: Int
        switch command {
        case .readEvents where resource == .calendar,
             .readReminders where resource == .reminderList: required = Self.read
        case .createEvent where resource == .calendar,
             .createReminder where resource == .reminderList: required = Self.create
        case .updateEvent where resource == .calendar,
             .updateReminder where resource == .reminderList: required = Self.edit
        case .deleteEvent where resource == .calendar,
             .deleteReminder where resource == .reminderList: required = Self.delete
        case .completeReminder where resource == .reminderList: required = Self.complete
        default: return false
        }
        return mask & required != 0
    }
}

struct ClientView {
    let id: String
    let name: String
    let revoked: Bool
    let grants: [ClientGrant]
}

struct ClientActivity: Codable {
    let at: Date
    let clientID: String?
    let command: String
    let outcome: String
}

struct AuthorizedClientCall {
    let clientID: String
    let clientName: String
    let revision: Int
    let command: BridgeCommand
    let targetID: String?
    let grant: ClientGrant?
}

enum ClientRegistryError: String, Error {
    case unavailable
    case invalidName
    case invalidGrants
    case limitReached
    case clientMissing
    case clientRevoked
    case unauthorized
    case forbidden
}

// The store protects against other UIDs and unsafe paths. It does not isolate
// its policy file from another process running as this same macOS user.
final class ClientRegistry {
    private struct Record: Codable {
        let id: String
        var name: String
        var verifier: String
        var revoked: Bool
        var revision: Int
        var grants: [ClientGrant]
    }
    private struct State: Codable {
        var version = 2
        var clients = [Record]()
        var activity = [ClientActivity]()
    }

    private let directory: URL
    private let file: URL
    private var state: State?
    private var failed = false

    init(directory override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        directory = override ?? support.appendingPathComponent("EventKitBridge", isDirectory: true)
        file = directory.appendingPathComponent("client-registry.json")
    }

    func clients() -> [ClientView]? {
        guard load() else { return nil }
        return state!.clients.map {
            ClientView(id: $0.id, name: $0.name, revoked: $0.revoked,
                       grants: $0.grants)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func activity() -> [ClientActivity]? {
        guard load() else { return nil }
        return Array(state!.activity.reversed())
    }

    func createClient(name: String) -> Result<(id: String, key: String), ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard Self.validName(name) else { return .failure(.invalidName) }
        guard state!.clients.count < 32 else { return .failure(.limitReached) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let id = UUID().uuidString.lowercased()
        var next = state!
        next.clients.append(Record(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                   verifier: Self.hex(signingKey.publicKey.rawRepresentation),
                                   revoked: false, revision: 1, grants: []))
        guard persist(next) else { return .failure(.unavailable) }
        return .success((id, "ekb_v1_" + Self.hex(signingKey.rawRepresentation)))
    }

    func rotateKey(clientID: String) -> Result<String, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        guard !state!.clients[index].revoked else { return .failure(.clientRevoked) }
        let signingKey = Curve25519.Signing.PrivateKey()
        var next = state!
        next.clients[index].verifier = Self.hex(signingKey.publicKey.rawRepresentation)
        next.clients[index].revision += 1
        guard persist(next) else { return .failure(.unavailable) }
        return .success("ekb_v1_" + Self.hex(signingKey.rawRepresentation))
    }

    func revoke(clientID: String) -> Result<Void, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        var next = state!
        next.clients[index].revoked = true
        next.clients[index].verifier = ""
        next.clients[index].revision += 1
        guard persist(next) else { return .failure(.unavailable) }
        return .success(())
    }

    func replaceGrants(clientID: String, grants: [ClientGrant])
        -> Result<Void, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        guard let index = state!.clients.firstIndex(where: { $0.id == clientID }) else {
            return .failure(.clientMissing)
        }
        guard !state!.clients[index].revoked else { return .failure(.clientRevoked) }
        let identities = grants.map { "\($0.resource.rawValue):\($0.targetID)" }
        guard grants.count <= 100, grants.allSatisfy(\.isValid),
              Set(identities).count == identities.count else {
            return .failure(.invalidGrants)
        }
        var next = state!
        next.clients[index].grants = grants
        next.clients[index].revision += 1
        guard persist(next) else { return .failure(.unavailable) }
        return .success(())
    }

    func authorize(clientID: String, signature: Data, signedPayload: Data,
                   request: BridgeRequest)
        -> Result<AuthorizedClientCall, ClientRegistryError> {
        guard load() else { return .failure(.unavailable) }
        let candidate = state!.clients.first { $0.id == clientID && !$0.revoked }
        let verifier = candidate.flatMap { Self.unhex($0.verifier) }
            .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        guard let candidate, let verifier, signature.count == 64,
              verifier.isValidSignature(signature, for: signedPayload) else {
            _ = record(clientID: nil, command: request.command.rawValue, outcome: "unauthorized")
            return .failure(.unauthorized)
        }
        let targetID = Self.targetID(request)
        let itemCommand = request.command != .authorizationStatus &&
            request.command != .calendarCount &&
            request.command != .reminderListCount &&
            request.command != .scopeStatus
        if itemCommand && targetID == nil {
            _ = record(clientID: clientID, command: request.command.rawValue, outcome: "forbidden")
            return .failure(.forbidden)
        }
        let grant = candidate.grants.first {
            $0.targetID == targetID && $0.allows(request.command)
        }
        if targetID != nil && grant == nil {
            _ = record(clientID: clientID, command: request.command.rawValue, outcome: "forbidden")
            return .failure(.forbidden)
        }
        let call = AuthorizedClientCall(clientID: clientID, clientName: candidate.name,
                                        revision: candidate.revision,
                                        command: request.command,
                                        targetID: targetID, grant: grant)
        guard record(clientID: clientID, command: request.command.rawValue,
                     outcome: "accepted") else { return .failure(.unavailable) }
        return .success(call)
    }

    func stillAuthorized(_ call: AuthorizedClientCall) -> Bool {
        guard load(), let current = state!.clients.first(where: { $0.id == call.clientID }),
              !current.revoked, current.revision == call.revision else { return false }
        guard let targetID = call.targetID else { return true }
        return current.grants.contains { $0.targetID == targetID && $0.allows(call.command) }
    }

    @discardableResult
    func recordResult(_ call: AuthorizedClientCall, outcome: String) -> Bool {
        record(clientID: call.clientID, command: call.command.rawValue, outcome: outcome)
    }

    private static func targetID(_ request: BridgeRequest) -> String? {
        switch request.command {
        case .readEvents, .createEvent, .updateEvent, .deleteEvent:
            return request.parameters["calendarID"] as? String
        case .readReminders, .createReminder, .updateReminder,
             .completeReminder, .deleteReminder:
            return request.parameters["listID"] as? String
        default: return nil
        }
    }

    private func record(clientID: String?, command: String, outcome: String) -> Bool {
        guard load() else { return false }
        var next = state!
        next.activity.append(ClientActivity(at: Date(), clientID: clientID,
                                            command: command, outcome: outcome))
        if next.activity.count > 500 { next.activity.removeFirst(next.activity.count - 500) }
        return persist(next)
    }

    private static func validName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 80 &&
            trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    private static func unhex(_ string: String) -> Data? {
        guard string.count.isMultiple(of: 2), string.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private func load() -> Bool {
        if failed { return false }
        if state != nil { return true }
        if !FileManager.default.fileExists(atPath: directory.path) {
            state = State()
            return true
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { failed = true; return false }
        if !FileManager.default.fileExists(atPath: file.path) {
            state = State()
            return true
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { failed = true; return false }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 1_000_000,
              let data = try? FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: 1_000_001),
              let decoded = try? JSONDecoder().decode(State.self, from: data),
              decoded.version == 2, decoded.clients.count <= 32,
              decoded.activity.count <= 500,
              Set(decoded.clients.map(\.id)).count == decoded.clients.count,
              decoded.clients.allSatisfy({ record in
                  UUID(uuidString: record.id) != nil && Self.validName(record.name) &&
                  record.revision > 0 && record.grants.count <= 100 &&
                  record.grants.allSatisfy(\.isValid) &&
                  (record.revoked || Self.unhex(record.verifier)?.count == 32)
              }) else { failed = true; return false }
        state = decoded
        return true
    }

    private func persist(_ next: State) -> Bool {
        guard !failed, let data = try? JSONEncoder().encode(next), data.count <= 1_000_000
        else { failed = true; return false }
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            failed = true; return false
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { failed = true; return false }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { failed = true; return false }
        let written = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard written, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            failed = true; return false
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { failed = true; return false }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { failed = true; return false }
        state = next
        return true
    }
}
