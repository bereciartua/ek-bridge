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
        let key = issued.key
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
