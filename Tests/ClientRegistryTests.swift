import CryptoKit
import Foundation

@main
struct ClientRegistryTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-client-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ClientRegistry(directory: directory)
        precondition(registry.clients()?.isEmpty == true)
        let issued = value(registry.createClient(name: "Synthetic Client"))
        let id = issued.id
        let key = issued.signingKey!
        precondition(key.hasPrefix("ekb_v1_"))
        precondition(registry.clients()?.first?.grants.isEmpty == true)
        let session = "session-\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970
        let fields: [String: Any] = [
            "calendarID": "synthetic-calendar", "start": 1_800_000_000.0,
            "end": 1_800_003_600.0, "limit": 5,
        ]
        let firstWire = try wire(session: session, id: id, key: key,
                                 command: "read_events", parameters: fields, now: now)
        let first = parsed(firstWire, session: session, now: now)
        guard case .failure(.invalid) = ClientBridgeProtocol.validate(
            firstWire, session: "session-\(UUID().uuidString)", now: now, usedIDs: [])
        else { preconditionFailure("wrong session") }
        guard case .failure(.expired) = ClientBridgeProtocol.validate(
            firstWire, session: session, now: now + 90, usedIDs: [])
        else { preconditionFailure("stale timestamp") }
        failure(registry.authorize(clientID: first.clientID,
                                   signature: first.signature,
                                   signedPayload: first.signedPayload,
                                   request: first.request), .forbidden)
        let grants = [
            ClientGrant(resource: .calendar, targetID: "synthetic-calendar",
                        mask: ClientGrant.read | ClientGrant.create),
            ClientGrant(resource: .reminderList, targetID: "synthetic-list",
                        mask: ClientGrant.read | ClientGrant.complete),
        ]
        success(registry.replaceGrants(clientID: id, grants: grants))
        failure(registry.replaceGrants(clientID: id, grants: [grants[0], grants[0]]),
                .invalidGrants)
        failure(registry.replaceGrants(clientID: id, grants: [
            ClientGrant(resource: .calendar, targetID: "synthetic-calendar",
                        mask: ClientGrant.complete)]), .invalidGrants)
        precondition(registry.clients()?.first(where: { $0.id == id })?.grants == grants)
        let second = value(registry.createClient(name: "Another Synthetic Client"))
        success(registry.replaceGrants(clientID: second.id, grants: [
            ClientGrant(resource: .reminderList, targetID: "other-list",
                        mask: ClientGrant.read)]))
        failure(registry.authorize(clientID: second.id, signature: first.signature,
                                   signedPayload: first.signedPayload,
                                   request: first.request), .unauthorized)
        let allowed = value(registry.authorize(clientID: first.clientID,
                                               signature: first.signature,
                                               signedPayload: first.signedPayload,
                                               request: first.request))
        precondition(registry.stillAuthorized(allowed))
        let createWire = try wire(session: session, id: id, key: key,
                                  command: "create_event", parameters: [
                                    "calendarID": "synthetic-calendar", "title": "Synthetic",
                                    "start": 1_800_000_000.0, "end": 1_800_003_600.0,
                                    "idempotencyKey": WriteIdempotencyKey.make()], now: now)
        let create = parsed(createWire, session: session, now: now)
        let grantedWrite = value(registry.authorize(clientID: create.clientID,
                                                    signature: create.signature,
                                                    signedPayload: create.signedPayload,
                                                    request: create.request))
        precondition(registry.stillAuthorized(grantedWrite))
        precondition(CommandPolicy.validate(create.request,
            scope: BridgeScope(calendarID: grantedWrite.targetID,
                               generation: grantedWrite.revision)) == nil)
        let restarted = ClientRegistry(directory: directory)
        let persistedWrite = value(restarted.authorize(clientID: create.clientID,
                                                       signature: create.signature,
                                                       signedPayload: create.signedPayload,
                                                       request: create.request))
        precondition(restarted.stillAuthorized(persistedWrite))
        let editWire = try wire(session: session, id: id, key: key,
                                command: "update_event", parameters: [
                                    "calendarID": "synthetic-calendar", "itemID": "synthetic-item",
                                    "expectedVersion": "1", "title": "Synthetic edit",
                                    "start": 1_800_000_000.0, "end": 1_800_003_600.0,
                                    "idempotencyKey": WriteIdempotencyKey.make()], now: now)
        let edit = parsed(editWire, session: session, now: now)
        failure(registry.authorize(clientID: edit.clientID, signature: edit.signature,
                                   signedPayload: edit.signedPayload,
                                   request: edit.request), .forbidden)

        var tampered = try JSONSerialization.jsonObject(with: firstWire) as! [String: Any]
        tampered["parameters"] = ["calendarID": "another-calendar", "start": 1_800_000_000.0,
                                  "end": 1_800_003_600.0, "limit": 5]
        let tamperedWire = try JSONSerialization.data(withJSONObject: tampered, options: [.sortedKeys])
        let altered = parsed(tamperedWire, session: session, now: now)
        failure(registry.authorize(clientID: altered.clientID,
                                   signature: altered.signature,
                                   signedPayload: altered.signedPayload,
                                   request: altered.request), .unauthorized)
        guard case .failure(.replay) = ClientBridgeProtocol.validate(
            firstWire, session: session, now: now, usedIDs: [first.request.id])
        else { preconditionFailure("replay") }

        let otherWire = try wire(session: session, id: id, key: key,
                                 command: "read_events", parameters: [
                                    "calendarID": "another-calendar", "start": 1_800_000_000.0,
                                    "end": 1_800_003_600.0, "limit": 5], now: now)
        let other = parsed(otherWire, session: session, now: now)
        failure(registry.authorize(clientID: other.clientID, signature: other.signature,
                                   signedPayload: other.signedPayload,
                                   request: other.request), .forbidden)
        let wrongActionWire = try wire(session: session, id: id, key: key,
                                       command: "complete_reminder", parameters: [
                                        "listID": "synthetic-calendar",
                                        "itemID": "synthetic-item", "expectedVersion": "v1",
                                        "idempotencyKey": WriteIdempotencyKey.make()], now: now)
        let wrongAction = parsed(wrongActionWire, session: session, now: now)
        failure(registry.authorize(clientID: wrongAction.clientID,
                                   signature: wrongAction.signature,
                                   signedPayload: wrongAction.signedPayload,
                                   request: wrongAction.request), .forbidden)

        success(registry.replaceGrants(clientID: id, grants: [grants[1]]))
        precondition(!registry.stillAuthorized(allowed))
        precondition(!registry.stillAuthorized(grantedWrite))
        let newKey = value(registry.rotateKey(clientID: id))
        failure(registry.authorize(clientID: first.clientID, signature: first.signature,
                                   signedPayload: first.signedPayload,
                                   request: first.request), .unauthorized)
        let newWire = try wire(session: session, id: id, key: newKey,
                               command: "read_reminders",
                               parameters: ["listID": "synthetic-list", "limit": 5], now: now)
        let newEnvelope = parsed(newWire, session: session, now: now)
        let rotated = value(registry.authorize(clientID: newEnvelope.clientID,
                                               signature: newEnvelope.signature,
                                               signedPayload: newEnvelope.signedPayload,
                                               request: newEnvelope.request))
        precondition(registry.stillAuthorized(rotated))
        success(registry.revoke(clientID: id))
        precondition(!registry.stillAuthorized(rotated))
        failure(registry.replaceGrants(clientID: id, grants: grants), .clientRevoked)
        failure(registry.authorize(clientID: newEnvelope.clientID,
                                   signature: newEnvelope.signature,
                                   signedPayload: newEnvelope.signedPayload,
                                   request: newEnvelope.request), .unauthorized)
        precondition(registry.clients()?.first(where: { $0.id == id })?.revoked == true)
        precondition(registry.activity()?.contains(where: { $0.outcome == "forbidden" }) == true)
        let persisted = try Data(contentsOf: directory.appendingPathComponent("client-registry.json"))
        let fileMode = (try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("client-registry.json").path))[.posixPermissions] as! Int
        let dirMode = (try FileManager.default.attributesOfItem(
            atPath: directory.path))[.posixPermissions] as! Int
        precondition(fileMode == 0o600 && dirMode == 0o700)
        precondition(!String(decoding: persisted, as: UTF8.self).contains(key))
        precondition(!String(decoding: persisted, as: UTF8.self).contains(newKey))
        let reloaded = ClientRegistry(directory: directory)
        precondition(reloaded.clients()?.first(where: { $0.id == id })?.revoked == true)
        precondition(reloaded.clients()?.first(where: { $0.id == second.id })?.revoked == false)
        print("Client registry: default deny, durable scoped writes, signatures, replay, rotation, revocation passed")
        try schemaVersion3()
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-client-test-\(UUID().uuidString)")
    }

    static func writeRegistry(_ object: [String: Any], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("client-registry.json")
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        precondition(FileManager.default.createFile(atPath: file.path, contents: data,
                                                    attributes: [.posixPermissions: 0o600]))
    }

    static func legacyClient(_ name: String, revoked: Bool = false,
                             grants: [[String: Any]] = []) -> [String: Any] {
        let key = Curve25519.Signing.PrivateKey()
        return [
            "id": UUID().uuidString.lowercased(), "name": name,
            "verifier": revoked ? "" : key.publicKey.rawRepresentation
                .map { String(format: "%02x", $0) }.joined(),
            "revoked": revoked, "revision": 3, "grants": grants,
        ]
    }

    static func schemaVersion3() throws {
        // A version 2 file loads unchanged, upgrades on the first write, keeps
        // a one-time backup, and keeps every grant.
        let legacyDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: legacyDirectory) }
        let grants: [[String: Any]] = [
            ["resource": "calendar", "targetID": "legacy-calendar", "mask": 2],
            ["resource": "reminderList", "targetID": "legacy-list", "mask": 31],
        ]
        let legacy = legacyClient("Legacy Tool", grants: grants)
        try writeRegistry([
            "version": 2, "clients": [legacy, legacyClient("Old", revoked: true)],
            "activity": [["at": 100.0, "clientID": legacy["id"]!,
                          "command": "read_events", "outcome": "success"]],
        ], to: legacyDirectory)
        let original = try Data(contentsOf: legacyDirectory.appendingPathComponent("client-registry.json"))
        let upgraded = ClientRegistry(directory: legacyDirectory)
        precondition(upgraded.clients()?.count == 2)
        precondition(upgraded.activity()?.first?.targetID == nil)
        let backup = legacyDirectory.appendingPathComponent(ClientRegistry.backupFileName(version: 2))
        precondition(!FileManager.default.fileExists(atPath: backup.path))
        let legacyGrants = upgraded.clients()!.first { $0.name == "Legacy Tool" }!.grants
        precondition(legacyGrants.map(\.mask) == [2, 31])
        success(upgraded.rename(clientID: legacy["id"] as! String, name: "Legacy Tool"))
        precondition(!FileManager.default.fileExists(atPath: backup.path),
                     "an unchanged rename doesn't write")
        let extra = value(upgraded.createClient(name: "New Tool"))
        let backupData = try Data(contentsOf: backup)
        precondition(backupData == original)
        let backupMode = (try FileManager.default.attributesOfItem(atPath: backup.path))[.posixPermissions] as! Int
        precondition(backupMode == 0o600)
        let rewritten = try JSONSerialization.jsonObject(with: Data(contentsOf:
            legacyDirectory.appendingPathComponent("client-registry.json"))) as! [String: Any]
        precondition(rewritten["version"] as? Int == ClientRegistry.currentVersion)
        let reloaded = ClientRegistry(directory: legacyDirectory)
        precondition(reloaded.clients()?.first { $0.name == "Legacy Tool" }?.grants == legacyGrants)
        success(reloaded.revoke(clientID: extra.id))
        let backupAgain = try Data(contentsOf: backup)
        precondition(backupAgain == original, "the backup is written once")

        // Only active clients count toward the limit of 32.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ClientRegistry(directory: directory)
        var ids = [String]()
        for index in 0..<32 { ids.append(value(registry.createClient(name: "Client \(index)")).id) }
        for _ in 0..<5 {
            let spare = ids.removeFirst()
            success(registry.revoke(clientID: spare))
            ids.append(value(registry.createClient(name: "Replacement \(UUID().uuidString)")).id)
        }
        precondition(registry.clients()?.filter { !$0.revoked }.count == 32)
        precondition(registry.clients()?.filter(\.revoked).count == 5)
        failure(registry.createClient(name: "One too many"), .limitReached)
        success(registry.revoke(clientID: ids.removeFirst()))
        let afterRevoke = value(registry.createClient(name: "One too many"))
        precondition(ClientRegistry(directory: directory).clients()?.count == 38)

        // Unique names among active clients; rename keeps the revision.
        failure(registry.createClient(name: "  one TOO many "), .duplicateName)
        precondition(registry.nameIssue("ONE TOO MANY") == .duplicate("One too many"))
        precondition(registry.nameIssue("ONE TOO MANY", excluding: afterRevoke.id) == nil)
        precondition(registry.nameIssue("Client 0") == nil, "revoked names can be reused")
        precondition(registry.nameIssue("   ") == .empty)
        precondition(registry.nameIssue(String(repeating: "a", count: 81)) == .tooLong)
        precondition(registry.nameIssue("tab\there") == .controlCharacters)
        let renamedID = ids[0]
        let session = "session-\(UUID().uuidString)"
        let issuedKey = value(registry.rotateKey(clientID: renamedID))
        success(registry.replaceGrants(clientID: renamedID, grants: [
            ClientGrant(resource: .reminderList, targetID: "list-a", mask: ClientGrant.read)]))
        let readWire = try wire(session: session, id: renamedID, key: issuedKey,
                                command: "read_reminders",
                                parameters: ["listID": "list-a", "limit": 1],
                                now: Date().timeIntervalSince1970)
        let read = parsed(readWire, session: session, now: Date().timeIntervalSince1970)
        let inFlight = value(registry.authorize(clientID: read.clientID, signature: read.signature,
                                                signedPayload: read.signedPayload,
                                                request: read.request))
        success(registry.rename(clientID: renamedID, name: "Renamed Tool"))
        precondition(registry.stillAuthorized(inFlight), "rename doesn't change the revision")
        precondition(registry.clients()?.first { $0.id == renamedID }?.name == "Renamed Tool")
        success(registry.rename(clientID: renamedID, name: "renamed tool"))
        failure(registry.rename(clientID: renamedID, name: "One too many"), .duplicateName)
        failure(registry.rename(clientID: renamedID, name: ""), .invalidName)
        failure(registry.rename(clientID: "00000000-0000-0000-0000-000000000000", name: "x"),
                .clientMissing)
        failure(registry.rename(clientID: ids.last!, name: "client 10"), .duplicateName)
        let revokedID = registry.clients()!.first(where: \.revoked)!.id
        failure(registry.rename(clientID: revokedID, name: "Zombie"), .clientRevoked)

        // Activity records the target ID for granted and denied targeted
        // commands, and nil for commands without a target.
        registry.recordResult(inFlight, outcome: "success")
        precondition(registry.activity()?.first?.targetID == "list-a")
        precondition(registry.activity()?.contains { $0.outcome == "accepted" && $0.targetID == "list-a" } == true)
        let deniedWire = try wire(session: session, id: renamedID, key: issuedKey,
                                  command: "read_reminders",
                                  parameters: ["listID": "list-b", "limit": 1],
                                  now: Date().timeIntervalSince1970)
        let denied = parsed(deniedWire, session: session, now: Date().timeIntervalSince1970)
        failure(registry.authorize(clientID: denied.clientID, signature: denied.signature,
                                   signedPayload: denied.signedPayload, request: denied.request),
                .forbidden)
        precondition(registry.activity()?.first?.outcome == "forbidden")
        precondition(registry.activity()?.first?.targetID == "list-b")
        let statusWire = try wire(session: session, id: renamedID, key: issuedKey,
                                  command: "scope_status", parameters: [:],
                                  now: Date().timeIntervalSince1970)
        let status = parsed(statusWire, session: session, now: Date().timeIntervalSince1970)
        let statusCall = value(registry.authorize(clientID: status.clientID, signature: status.signature,
                                                  signedPayload: status.signedPayload,
                                                  request: status.request))
        registry.recordResult(statusCall, outcome: "success")
        precondition(registry.activity()?.first?.command == "scope_status")
        precondition(registry.activity()?.first?.targetID == nil)
        let reread = ClientRegistry(directory: directory).activity()!
        precondition(reread.contains { $0.targetID == "list-b" && $0.outcome == "forbidden" })

        // The revoked cap prunes the oldest revoked records first; legacy
        // records without a revoke time go before any timed one.
        let capDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: capDirectory) }
        var capClients = [legacyClient("Legacy revoked", revoked: true)]
        for index in 0..<199 {
            var record = legacyClient("Revoked \(index)", revoked: true)
            record["revokedAt"] = Double(index)
            capClients.append(record)
        }
        let survivor = legacyClient("Survivor")
        capClients.append(survivor)
        try writeRegistry(["version": 3, "clients": capClients, "activity": []], to: capDirectory)
        let capped = ClientRegistry(directory: capDirectory)
        precondition(capped.clients()?.count == 201)
        success(capped.revoke(clientID: survivor["id"] as! String))
        let afterCap = capped.clients()!
        precondition(afterCap.count == 200)
        precondition(!afterCap.contains { $0.name == "Legacy revoked" })
        precondition(afterCap.contains { $0.name == "Revoked 0" })
        precondition(afterCap.first { $0.name == "Survivor" }?.revokedAt != nil)
        let moreDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: moreDirectory) }
        var moreClients = capClients.filter { $0["name"] as? String != "Legacy revoked" }
        var extraRevoked = legacyClient("Revoked 199", revoked: true)
        extraRevoked["revokedAt"] = 199.0
        moreClients.append(extraRevoked)
        try writeRegistry(["version": 3, "clients": moreClients, "activity": []], to: moreDirectory)
        let more = ClientRegistry(directory: moreDirectory)
        success(more.revoke(clientID: survivor["id"] as! String))
        precondition(more.clients()?.count == 200)
        precondition(!(more.clients()!.contains { $0.name == "Revoked 0" }))

        // A file with 33 active clients still fails closed.
        let overDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: overDirectory) }
        try writeRegistry(["version": 3, "clients": (0..<33).map { legacyClient("Active \($0)") },
                           "activity": []], to: overDirectory)
        precondition(ClientRegistry(directory: overDirectory).clients() == nil)
        // 32 active plus revoked records loads.
        let okDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: okDirectory) }
        try writeRegistry(["version": 2, "clients": (0..<32).map { legacyClient("Active \($0)") } +
                           (0..<10).map { legacyClient("Gone \($0)", revoked: true) },
                           "activity": []], to: okDirectory)
        precondition(ClientRegistry(directory: okDirectory).clients()?.count == 42)
        // An unknown version and an invalid activity target fail closed.
        let futureDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: futureDirectory) }
        try writeRegistry(["version": ClientRegistry.currentVersion + 1, "clients": [], "activity": []],
                          to: futureDirectory)
        precondition(ClientRegistry(directory: futureDirectory).clients() == nil)
        let badTargetDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: badTargetDirectory) }
        try writeRegistry(["version": 3, "clients": [], "activity": [
            ["at": 1.0, "command": "read_events", "outcome": "success", "targetID": "bad\nid"]]],
                          to: badTargetDirectory)
        precondition(ClientRegistry(directory: badTargetDirectory).activity() == nil)
        print("Client registry v3: upgrade and backup, active-only limit, revoked cap, rename, unique names, activity targets passed")
    }

    static func wire(session: String, id: String, key: String, command: String,
                     parameters: [String: Any], now: Double) throws -> Data {
        let seed = Data(hex: String(key.dropFirst(7)))!
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        var fields: [String: Any] = [
            "version": 2, "session": session, "id": UUID().uuidString.lowercased(),
            "clientID": id, "command": command, "issuedAt": now,
            "parameters": parameters,
        ]
        let signed = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        fields["signature"] = try signingKey.signature(for: signed)
            .map { String(format: "%02x", $0) }.joined()
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    static func parsed(_ data: Data, session: String, now: Double) -> ClientBridgeEnvelope {
        switch ClientBridgeProtocol.validate(data, session: session, now: now, usedIDs: []) {
        case .success(let value): return value
        case .failure(let error): preconditionFailure("parse \(error)")
        }
    }
    static func value<T>(_ result: Result<T, ClientRegistryError>) -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): preconditionFailure("unexpected \(error)")
        }
    }
    static func success(_ result: Result<Void, ClientRegistryError>) {
        value(result)
    }
    static func failure<T>(_ result: Result<T, ClientRegistryError>,
                           _ expected: ClientRegistryError) {
        switch result {
        case .success: preconditionFailure("expected \(expected)")
        case .failure(let actual): precondition(actual == expected)
        }
    }
}

// The CLI path: authenticate the signature, then the shared grant check.
extension ClientRegistry {
    func authorize(clientID: String, signature: Data, signedPayload: Data,
                   request: BridgeRequest) -> Result<AuthorizedClientCall, ClientRegistryError> {
        switch authenticateSignature(clientID: clientID, signature: signature,
                                     signedPayload: signedPayload, command: request.command) {
        case .success(let id): return authorize(clientID: id, request: request, origin: .cli)
        case .failure(let error): return .failure(error)
        }
    }
}

private extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            append(byte)
            index = next
        }
    }
}
