import CryptoKit
import Foundation

@main
struct ClientRegistryV4Tests {
    static func main() throws {
        try MainActor.assumeIsolated { try run() }
    }

    @MainActor
    static func run() throws {
        try migrations()
        try tokens()
        try revisionBumps()
        try credentials()
        try loadValidation()
        agentSanitizing()
        try failedAuthentication()
        try activityRows()
        try roundTrip()
        print("Client registry v4: v2/v3 upgrade and one-time backups, tokens, revision bumps, "
              + "MCP-only clients, load validation, agent names, failed-auth coalescing, "
              + "CLI/MCP rows, round trip passed")
    }

    // MARK: Migration and backups

    static func migrations() throws {
        for version in [2, 3] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let legacy = legacyClient("Legacy \(version)", grants: [
                ["resource": "calendar", "targetID": "legacy-calendar", "mask": 3]])
            var activity: [String: Any] = ["at": 100.0, "clientID": legacy["id"]!,
                                           "command": "read_events", "outcome": "success"]
            if version == 3 { activity["targetID"] = "legacy-calendar" }
            try writeRegistry(["version": version, "clients": [legacy, legacyClient("Gone", revoked: true)],
                               "activity": [activity]], to: directory)
            let file = directory.appendingPathComponent("client-registry.json")
            let original = try Data(contentsOf: file)
            let registry = ClientRegistry(directory: directory)
            let loaded = registry.clients()!
            precondition(loaded.count == 2)
            let client = loaded.first { $0.name == "Legacy \(version)" }!
            precondition(client.approval == .allow && !client.hasMCPToken && client.hasSigningKey)
            precondition(client.mcpIssuedAt == nil)
            precondition(registry.activity()?.first?.via == nil && registry.activity()?.first?.agent == nil)
            let backup = directory.appendingPathComponent("client-registry.v\(version).backup.json")
            precondition(ClientRegistry.backupFileName(version: version) == backup.lastPathComponent)
            precondition(!FileManager.default.fileExists(atPath: backup.path), "reading writes nothing")
            // The first write keeps the original bytes once, then writes v4.
            let token = value(registry.issueMCPToken(clientID: client.id))
            precondition(try! Data(contentsOf: backup) == original)
            precondition(mode(backup) == 0o600)
            let rewritten = try json(file)
            precondition(rewritten["version"] as? Int == 4)
            precondition(value(registry.authenticateMCPToken(token)) == client.id)
            // Never rewritten by later writes, or by a later process.
            success(registry.setApproval(clientID: client.id, .ask))
            let restarted = ClientRegistry(directory: directory)
            success(restarted.setApproval(clientID: client.id, .allow))
            precondition(try! Data(contentsOf: backup) == original, "the backup is written once")
            precondition(restarted.clients()?.first { $0.id == client.id }?.grants.map(\.mask) == [3])
            let otherBackup = directory.appendingPathComponent(
                ClientRegistry.backupFileName(version: version == 2 ? 3 : 2))
            precondition(!FileManager.default.fileExists(atPath: otherBackup.path))
        }

        // An existing backup is never overwritten (O_EXCL), and the upgrade
        // still goes ahead.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeRegistry(["version": 3, "clients": [legacyClient("Kept")], "activity": []],
                          to: directory)
        let backup = directory.appendingPathComponent("client-registry.v3.backup.json")
        let earlier = Data(#"{"earlier":"backup"}"#.utf8)
        precondition(FileManager.default.createFile(atPath: backup.path, contents: earlier,
                                                    attributes: [.posixPermissions: 0o600]))
        let registry = ClientRegistry(directory: directory)
        _ = value(registry.createClient(name: "New"))
        precondition(try! Data(contentsOf: backup) == earlier)
        precondition(try! json(directory.appendingPathComponent("client-registry.json"))["version"]
                     as? Int == 4)

        // A v4 file makes no backup.
        let current = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: current) }
        try writeRegistry(["version": 4, "clients": [legacyClient("Current")], "activity": []],
                          to: current)
        _ = value(ClientRegistry(directory: current).createClient(name: "Another"))
        let names = try FileManager.default.contentsOfDirectory(atPath: current.path)
        precondition(!names.contains { $0.contains("backup") }, "\(names)")
    }

    // MARK: Tokens

    static func tokens() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let registry = ClientRegistry(directory: directory, now: { clock })
        let created = value(registry.createClient(name: "CLI first"))
        precondition(created.signingKey != nil && created.mcpToken == nil)
        let first = value(registry.issueMCPToken(clientID: created.id))
        precondition(first.hasPrefix("ekb_mcp_v1_") && first.utf8.count == 75)
        precondition(ClientRegistry.validMCPToken(first))
        precondition(value(registry.authenticateMCPToken(first)) == created.id)
        var view = registry.clients()!.first { $0.id == created.id }!
        precondition(view.hasMCPToken && view.mcpIssuedAt == clock && view.hasSigningKey)
        // Reset: a new token, the old one stops working.
        clock = clock.addingTimeInterval(60)
        let second = value(registry.issueMCPToken(clientID: created.id))
        precondition(second != first)
        failure(registry.authenticateMCPToken(first), .unauthorized)
        precondition(value(registry.authenticateMCPToken(second)) == created.id)
        view = registry.clients()!.first { $0.id == created.id }!
        precondition(view.mcpIssuedAt == clock)
        // Another client's token identifies that client.
        let other = value(registry.createClient(name: "MCP agent", credentials: [.mcpToken]))
        precondition(value(registry.authenticateMCPToken(other.mcpToken!)) == other.id)
        precondition(value(registry.authenticateMCPToken(second)) == created.id)
        // Survives a restart (only the digest is stored).
        let restarted = ClientRegistry(directory: directory, now: { clock })
        precondition(value(restarted.authenticateMCPToken(second)) == created.id)
        precondition(value(restarted.authenticateMCPToken(other.mcpToken!)) == other.id)
        // The registry file holds digests, never token text.
        let text = try String(contentsOf: directory.appendingPathComponent("client-registry.json"),
                              encoding: .utf8)
        for token in [first, second, other.mcpToken!] {
            precondition(!text.contains(token) && !text.contains(String(token.dropFirst(11))))
        }
        precondition(text.contains(ClientRegistry.tokenDigest(second)))
        precondition(!text.contains("ekb_mcp_v1_"))
        // Remove: the token stops working, and removing twice is a no-op.
        success(restarted.removeMCPToken(clientID: created.id))
        failure(restarted.authenticateMCPToken(second), .unauthorized)
        precondition(restarted.clients()!.first { $0.id == created.id }!.hasMCPToken == false)
        precondition(restarted.clients()!.first { $0.id == created.id }!.mcpIssuedAt == nil)
        success(restarted.removeMCPToken(clientID: created.id))
        // Revoke clears the token.
        success(restarted.revoke(clientID: other.id))
        failure(restarted.authenticateMCPToken(other.mcpToken!), .unauthorized)
        failure(restarted.issueMCPToken(clientID: other.id), .clientRevoked)
        failure(restarted.issueMCPToken(clientID: UUID().uuidString.lowercased()), .clientMissing)
        let revokedRecord = (try json(directory.appendingPathComponent("client-registry.json"))["clients"]
                             as! [[String: Any]]).first { $0["id"] as? String == other.id }!
        precondition(revokedRecord["mcpVerifier"] == nil && revokedRecord["verifier"] as? String == "")

        // Malformed shapes are refused before any digest is compared: even a
        // registered digest of the malformed string doesn't match.
        let hex = String(second.dropFirst(11))
        let malformed = [
            "ekb_mcp_v1_" + hex.uppercased(),
            "ekb_mcp_v2_" + hex,
            "EKB_MCP_V1_" + hex,
            "ekb_mcp_v1_" + hex.dropLast(),
            "ekb_mcp_v1_" + hex + "0",
            "ekb_mcp_v1_" + hex.dropLast() + "g",
            " ekb_mcp_v1_" + hex.dropLast(),
            "",
        ]
        precondition(malformed[3].utf8.count == 74 && malformed[4].utf8.count == 76)
        let shapeDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: shapeDirectory) }
        var clients = [[String: Any]]()
        for (index, token) in malformed.enumerated() {
            var record = legacyClient("Shape \(index)")
            record["mcpVerifier"] = ClientRegistry.tokenDigest(token)
            clients.append(record)
        }
        let control = "ekb_mcp_v1_" + String(repeating: "ab", count: 32)
        var controlRecord = legacyClient("Control")
        controlRecord["mcpVerifier"] = ClientRegistry.tokenDigest(control)
        clients.append(controlRecord)
        try writeRegistry(["version": 4, "clients": clients, "activity": []], to: shapeDirectory)
        let shapes = ClientRegistry(directory: shapeDirectory)
        for token in malformed {
            precondition(!ClientRegistry.validMCPToken(token), token)
            failure(shapes.authenticateMCPToken(token), .unauthorized)
        }
        precondition(value(shapes.authenticateMCPToken(control)) == controlRecord["id"] as! String)
    }

    // MARK: Revision bumps

    static func revisionBumps() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ClientRegistry(directory: directory)
        let id = value(registry.createClient(name: "Bumps")).id
        // list_collections is client-level: no grants needed, no target.
        let listing = value(registry.authorize(clientID: id, request: request(.listCollections),
                                               origin: .mcp(agent: "Agent")))
        precondition(listing.targetID == nil && listing.grant == nil)
        precondition(registry.activity()?.first?.outcome == "accepted")
        precondition(registry.activity()?.first?.targetID == nil)

        func bumps(_ change: () -> Void) -> Bool {
            let call = value(registry.authorize(clientID: id, request: request(.listCollections),
                                                origin: .cli))
            precondition(registry.stillAuthorized(call))
            change()
            return !registry.stillAuthorized(call)
        }
        precondition(bumps { _ = value(registry.issueMCPToken(clientID: id)) }, "token issue")
        precondition(bumps { _ = value(registry.issueMCPToken(clientID: id)) }, "token reset")
        precondition(bumps { success(registry.removeMCPToken(clientID: id)) }, "token remove")
        precondition(!bumps { success(registry.removeMCPToken(clientID: id)) }, "remove without a token")
        precondition(bumps { success(registry.setApproval(clientID: id, .ask)) }, "approval change")
        precondition(!bumps { success(registry.setApproval(clientID: id, .ask)) }, "unchanged approval")
        precondition(bumps { success(registry.setApproval(clientID: id, .allow)) }, "approval back")
        precondition(!bumps { success(registry.rename(clientID: id, name: "Renamed")) }, "rename")
        precondition(bumps { success(registry.removeSigningKey(clientID: id)) }, "key remove")
        precondition(!bumps { success(registry.removeSigningKey(clientID: id)) }, "remove without a key")
        precondition(bumps { _ = value(registry.addSigningKey(clientID: id)) }, "key add")
        precondition(bumps { _ = value(registry.rotateKey(clientID: id)) }, "key rotate")
        precondition(bumps { success(registry.replaceGrants(clientID: id, grants: [])) }, "grant save")
        precondition(bumps { success(registry.revoke(clientID: id)) }, "revoke")
        // The approval mode reaches the authorized call.
        let asking = value(registry.createClient(name: "Asking", approval: .ask)).id
        precondition(value(registry.authorize(clientID: asking, request: request(.listCollections),
                                              origin: .cli)).approval == .ask)
        precondition(registry.clients()?.first { $0.id == asking }?.approval == .ask)
    }

    // MARK: MCP-only clients and signing keys

    static func credentials() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ClientRegistry(directory: directory)
        let mcpOnly = value(registry.createClient(name: "Agent only", credentials: [.mcpToken],
                                                  approval: .ask))
        precondition(mcpOnly.signingKey == nil && mcpOnly.mcpToken != nil)
        let record = (try json(directory.appendingPathComponent("client-registry.json"))["clients"]
                      as! [[String: Any]]).first!
        precondition(record["verifier"] as? String == "")
        precondition(record["approval"] as? String == "ask")
        precondition(record["mcpVerifier"] as? String == ClientRegistry.tokenDigest(mcpOnly.mcpToken!))
        let reloaded = ClientRegistry(directory: directory)
        let view = reloaded.clients()!.first!
        precondition(!view.hasSigningKey && view.hasMCPToken && view.approval == .ask)
        // No CLI key: any signature is refused.
        let stranger = Curve25519.Signing.PrivateKey()
        let payload = Data("payload".utf8)
        failure(reloaded.authenticateSignature(clientID: mcpOnly.id,
                                               signature: try stranger.signature(for: payload),
                                               signedPayload: payload, command: .scopeStatus),
                .unauthorized)
        precondition(reloaded.activity()?.first?.via == "cli")
        // Add a key, then remove it again.
        let key = value(reloaded.addSigningKey(clientID: mcpOnly.id))
        precondition(key.hasPrefix("ekb_v1_"))
        let seed = try Curve25519.Signing.PrivateKey(rawRepresentation: unhex(String(key.dropFirst(7))))
        let signature = try seed.signature(for: payload)
        precondition(value(reloaded.authenticateSignature(clientID: mcpOnly.id, signature: signature,
                                                          signedPayload: payload,
                                                          command: .scopeStatus)) == mcpOnly.id)
        precondition(reloaded.clients()!.first!.hasSigningKey)
        success(reloaded.removeSigningKey(clientID: mcpOnly.id))
        precondition(!reloaded.clients()!.first!.hasSigningKey)
        failure(reloaded.authenticateSignature(clientID: mcpOnly.id, signature: signature,
                                               signedPayload: payload, command: .scopeStatus),
                .unauthorized)
        // Neither credential is allowed too.
        let bare = value(reloaded.createClient(name: "Nothing yet", credentials: []))
        precondition(bare.signingKey == nil && bare.mcpToken == nil)
        let bareView = ClientRegistry(directory: directory).clients()!.first { $0.id == bare.id }!
        precondition(!bareView.hasSigningKey && !bareView.hasMCPToken && bareView.approval == .allow)
        let both = value(reloaded.createClient(name: "Both", credentials: [.signingKey, .mcpToken]))
        precondition(both.signingKey != nil && both.mcpToken != nil)
    }

    // MARK: Load validation

    static func loadValidation() throws {
        func loads(_ clients: [[String: Any]], activity: [[String: Any]] = [],
                   version: Int = 4) throws -> ClientRegistry? {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try writeRegistry(["version": version, "clients": clients, "activity": activity],
                              to: directory)
            let registry = ClientRegistry(directory: directory)
            return registry.clients() == nil ? nil : registry
        }
        let digest = ClientRegistry.tokenDigest("ekb_mcp_v1_" + String(repeating: "cd", count: 32))

        // approval: nil → .allow, "ask" → .ask, anything else fails closed.
        var plain = legacyClient("Plain")
        let registry = try loads([plain])!
        precondition(registry.clients()!.first!.approval == .allow)
        precondition(value(registry.authorize(clientID: plain["id"] as! String,
                                              request: request(.listCollections),
                                              origin: .cli)).approval == .allow)
        plain["approval"] = "ask"
        precondition(try! loads([plain])?.clients()?.first?.approval == .ask)
        plain["approval"] = "sometimes"
        precondition(try! loads([plain]) == nil)
        // MCP-only active record.
        var tokenOnly = legacyClient("Token only")
        tokenOnly["verifier"] = ""
        tokenOnly["mcpVerifier"] = digest
        tokenOnly["mcpIssuedAt"] = 100.0
        precondition(try! loads([tokenOnly]) != nil)
        // Duplicate active mcpVerifier fails closed.
        var twin = legacyClient("Twin")
        twin["mcpVerifier"] = digest
        precondition(try! loads([tokenOnly, twin]) == nil)
        var short = legacyClient("Short")
        short["mcpVerifier"] = String(digest.dropLast(2))
        precondition(try! loads([short]) == nil)
        var upper = legacyClient("Upper")
        upper["mcpVerifier"] = digest.uppercased()
        precondition(try! loads([upper]) == nil)
        // Revoked records hold no credential.
        var revokedKey = legacyClient("Revoked key")
        revokedKey["revoked"] = true
        precondition(try! loads([revokedKey]) == nil)
        var revokedToken = legacyClient("Revoked token", revoked: true)
        revokedToken["mcpVerifier"] = digest
        precondition(try! loads([revokedToken]) == nil)
        precondition(try! loads([legacyClient("Revoked clean", revoked: true)]) != nil)

        // Activity: via, agent and approval detail are checked.
        func row(_ extra: [String: Any]) -> [String: Any] {
            ["at": 100.0, "command": "read_events", "outcome": "success"].merging(extra) { _, new in new }
        }
        let good = row(["via": "mcp", "agent": "Claude Code 2.4.1", "approval": "window",
                        "targetID": "CAL"])
        let loaded = try loads([], activity: [good, row(["via": "cli"]), row([:])])!
        precondition(loaded.activity()?.last?.agent == "Claude Code 2.4.1")
        precondition(loaded.activity()?.last?.approval == "window")
        for detail in ["user", "window", "denied", "timeout"] {
            precondition(try! loads([], activity: [row(["approval": detail])]) != nil, detail)
        }
        precondition(try! loads([], activity: [row(["agent": String(repeating: "a", count: 64)])]) != nil)
        let bad: [[String: Any]] = [
            ["via": "http"], ["via": "MCP"], ["via": ""],
            ["agent": "bell\u{7}"], ["agent": "line\nbreak"], ["agent": ""],
            ["agent": String(repeating: "a", count: 65)],
            ["agent": String(repeating: "é", count: 33)],
            ["approval": "allowed_window"], ["approval": "yes"],
        ]
        for extra in bad {
            precondition(try! loads([], activity: [row(extra)]) == nil, "\(extra)")
        }
    }

    // MARK: Agent names

    static func agentSanitizing() {
        precondition(ClientRegistry.sanitizedAgent("Claude Code 2.4.1") == "Claude Code 2.4.1")
        precondition(ClientRegistry.sanitizedAgent("Claude\u{0}Code\n\t 2.4") == "Claude Code 2.4")
        precondition(ClientRegistry.sanitizedAgent("  spaced   out \u{1b}[31m ") == "spaced out [31m")
        precondition(ClientRegistry.sanitizedAgent("") == nil)
        precondition(ClientRegistry.sanitizedAgent(" \u{1}\u{2}\n ") == nil)
        let a = { (count: Int) in String(repeating: "a", count: count) }
        precondition(ClientRegistry.sanitizedAgent(a(70)) == a(64))
        precondition(ClientRegistry.sanitizedAgent(a(62) + "é") == a(62) + "é")      // 64 bytes
        precondition(ClientRegistry.sanitizedAgent(a(63) + "é") == a(63))            // 65 → cut
        precondition(ClientRegistry.sanitizedAgent(a(61) + "👍") == a(61))            // 4-byte scalar
        precondition(ClientRegistry.sanitizedAgent(a(60) + "👍") == a(60) + "👍")
        precondition(ClientRegistry.sanitizedAgent(a(62) + "e\u{301}") == a(62),
                     "a combining sequence is cut whole, not after its base")
        precondition(ClientRegistry.sanitizedAgent(String(repeating: "日", count: 30)) ==
                     String(repeating: "日", count: 21))                               // 63 bytes
        for sample in ["Claude\u{0}Code", a(70), a(63) + "é", String(repeating: "日", count: 30),
                       "x\u{85}y", "tab\there"] {
            let cleaned = ClientRegistry.sanitizedAgent(sample)!
            precondition(ClientRegistry.validAgent(cleaned), "sanitized names load back: \(cleaned)")
        }
    }

    // MARK: Failed MCP authentication

    static func failedAuthentication() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var clock = Date(timeIntervalSince1970: 2_000_000_000)
        let registry = ClientRegistry(directory: directory, now: { clock })
        let bad = "ekb_mcp_v1_" + String(repeating: "0", count: 64)
        let unauthorizedRows = { registry.activity()!.filter { $0.outcome == "unauthorized" } }
        for _ in 0..<50 { failure(registry.authenticateMCPToken(bad), .unauthorized) }
        precondition(unauthorizedRows().count == 1, "a burst is one row")
        let first = unauthorizedRows()[0]
        precondition(first.via == "mcp" && first.clientID == nil && first.command == "mcp")
        precondition(first.agent == nil && first.targetID == nil && first.at == clock)
        clock = clock.addingTimeInterval(9.5)
        failure(registry.authenticateMCPToken("malformed"), .unauthorized)
        precondition(unauthorizedRows().count == 1, "malformed tokens share the coalescing")
        clock = clock.addingTimeInterval(0.5)
        failure(registry.authenticateMCPToken(bad), .unauthorized)
        precondition(unauthorizedRows().count == 2, "a new row after 10 s")
        for step in 1...30 {
            clock = clock.addingTimeInterval(1)
            failure(registry.authenticateMCPToken(bad), .unauthorized)
            precondition(unauthorizedRows().count == 2 + step / 10)
        }
        precondition(ClientRegistry(directory: directory).activity()!.count == 5)
    }

    // MARK: Activity rows

    static func activityRows() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Date(timeIntervalSince1970: 2_000_000_000)
        let registry = ClientRegistry(directory: directory, now: { clock })
        let id = value(registry.createClient(name: "Rows")).id
        success(registry.replaceGrants(clientID: id, grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A", mask: ClientGrant.read)]))
        let read = request(.readEvents, ["calendarID": "CAL-A", "start": 1_000.0, "end": 2_000.0,
                                         "limit": 5])

        // recordRejected writes via, agent and the target.
        let create = request(.createEvent, ["calendarID": "CAL-X", "title": "t"])
        precondition(registry.recordRejected(clientID: id, request: create, outcome: "error:bridge_off",
                                             origin: .mcp(agent: "Agent\u{1}X  1.0")))
        let rejected = registry.activity()!.first!
        precondition(rejected == ClientActivity(at: clock, clientID: id, command: "create_event",
                                                outcome: "error:bridge_off", targetID: "CAL-X",
                                                via: "mcp", agent: "Agent X 1.0", approval: nil))
        precondition(registry.recordRejected(clientID: id, request: request(.scopeStatus),
                                             outcome: "error:rate_limited", origin: .cli))
        let cliRejected = registry.activity()!.first!
        precondition(cliRejected.via == "cli" && cliRejected.agent == nil && cliRejected.targetID == nil)

        // The same request via the CLI and via MCP: identical rows apart from via/agent.
        let before = registry.activity()!.count
        var cli = value(registry.authorize(clientID: id, request: read, origin: .cli))
        cli.approvalDetail = "user"
        precondition(registry.recordResult(cli, outcome: "success"))
        var mcp = value(registry.authorize(clientID: id, request: read,
                                           origin: .mcp(agent: "Claude Code 2.4.1")))
        mcp.approvalDetail = "user"
        precondition(registry.recordResult(mcp, outcome: "success"))
        failure(registry.authorize(clientID: id, request: request(.readEvents, ["calendarID": "CAL-B"]),
                                   origin: .cli), .forbidden)
        failure(registry.authorize(clientID: id, request: request(.readEvents, ["calendarID": "CAL-B"]),
                                   origin: .mcp(agent: "Claude Code 2.4.1")), .forbidden)
        let rows = Array(registry.activity()!.prefix(registry.activity()!.count - before).reversed())
        precondition(rows.count == 6)
        precondition(rows.map(\.via) == ["cli", "cli", "mcp", "mcp", "cli", "mcp"])
        precondition(rows.map(\.agent) == [nil, nil, "Claude Code 2.4.1", "Claude Code 2.4.1",
                                           nil, "Claude Code 2.4.1"])
        for (cliRow, mcpRow) in [(rows[0], rows[2]), (rows[1], rows[3]), (rows[4], rows[5])] {
            precondition(try! stripped(cliRow) == stripped(mcpRow), "\(cliRow) vs \(mcpRow)")
        }
        precondition(rows[0].outcome == "accepted" && rows[0].targetID == "CAL-A" && rows[0].approval == nil)
        precondition(rows[1].outcome == "success" && rows[1].approval == "user")
        precondition(rows[4].outcome == "forbidden" && rows[4].targetID == "CAL-B")
        // An unknown approval detail is dropped rather than stored.
        var odd = value(registry.authorize(clientID: id, request: read, origin: .cli))
        odd.approvalDetail = "allowed_window"
        precondition(registry.recordResult(odd, outcome: "success"))
        precondition(registry.activity()!.first!.approval == nil)
        // An agent name that sanitizes to nothing is stored as nil.
        precondition(registry.recordRejected(clientID: id, request: read, outcome: "error:bridge_off",
                                             origin: .mcp(agent: "\u{1}\u{2}")))
        precondition(registry.activity()!.first!.agent == nil && registry.activity()!.first!.via == "mcp")
        precondition(ClientRegistry(directory: directory).activity()!.count == registry.activity()!.count)
    }

    static func stripped(_ row: ClientActivity) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as! [String: Any]
        object["via"] = nil
        object["agent"] = nil
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Round trip

    static func roundTrip() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = ClientRegistry(directory: directory)
        let agent = value(registry.createClient(name: "Agent", credentials: [.mcpToken], approval: .ask))
        let both = value(registry.createClient(name: "Both", credentials: [.signingKey, .mcpToken]))
        let gone = value(registry.createClient(name: "Gone", credentials: [.mcpToken]))
        success(registry.replaceGrants(clientID: agent.id, grants: [
            ClientGrant(resource: .calendar, targetID: "CAL-A", mask: 15),
            ClientGrant(resource: .reminderList, targetID: "LIST-A", mask: 31)]))
        success(registry.revoke(clientID: gone.id))
        let file = directory.appendingPathComponent("client-registry.json")
        let before = try canonicalClients(file)
        precondition(before.count > 0)
        // A reload followed by a write that doesn't touch clients keeps every
        // client field, tokens included.
        let reloaded = ClientRegistry(directory: directory)
        _ = value(reloaded.authorize(clientID: both.id, request: request(.scopeStatus), origin: .cli))
        precondition(try! canonicalClients(file) == before)
        let records = try json(file)["clients"] as! [[String: Any]]
        let agentRecord = records.first { $0["id"] as? String == agent.id }!
        precondition(agentRecord["mcpVerifier"] as? String == ClientRegistry.tokenDigest(agent.mcpToken!))
        precondition(agentRecord["mcpIssuedAt"] != nil && agentRecord["approval"] as? String == "ask")
        precondition(value(reloaded.authenticateMCPToken(agent.mcpToken!)) == agent.id)
        precondition(value(reloaded.authenticateMCPToken(both.mcpToken!)) == both.id)
        let text = try String(contentsOf: file, encoding: .utf8)
        for token in [agent.mcpToken!, both.mcpToken!, gone.mcpToken!, both.signingKey!] {
            precondition(!text.contains(token))
        }
    }

    static func canonicalClients(_ file: URL) throws -> Data {
        try JSONSerialization.data(withJSONObject: json(file)["clients"]!, options: [.sortedKeys])
    }

    // MARK: Helpers

    static func request(_ command: BridgeCommand, _ parameters: [String: Any] = [:]) -> BridgeRequest {
        BridgeRequest(id: UUID().uuidString, command: command, parameters: parameters)
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-registry-v4-\(UUID().uuidString)")
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

    static func json(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    static func mode(_ file: URL) -> Int {
        (try! FileManager.default.attributesOfItem(atPath: file.path))[.posixPermissions] as! Int
    }

    static func unhex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
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
        case .failure(let actual): precondition(actual == expected, "expected \(expected), got \(actual)")
        }
    }
}
