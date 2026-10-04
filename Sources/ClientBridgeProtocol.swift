import CoreFoundation
import Foundation

struct ClientBridgeEnvelope {
    let clientID: String
    let signature: Data
    let signedPayload: Data
    let request: BridgeRequest
}

enum ClientBridgeProtocol {
    static func validate(_ data: Data, session: String, now: TimeInterval,
                         usedIDs: Set<String>) -> Result<ClientBridgeEnvelope, BridgeRequestError> {
        guard data.count <= BridgeProtocol.maxRequestBytes else { return .failure(.tooLarge) }
        guard let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(fields.keys) == Set(["version", "session", "id", "clientID",
                                       "signature", "command", "issuedAt", "parameters"]),
              let version = fields["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 2, version.doubleValue == 2,
              let suppliedSession = fields["session"] as? String,
              suppliedSession == session,
              let rawID = fields["id"] as? String,
              let id = UUID(uuidString: rawID),
              let rawClientID = fields["clientID"] as? String,
              let clientID = UUID(uuidString: rawClientID),
              let signatureHex = fields["signature"] as? String,
              let signature = unhex(signatureHex), signature.count == 64,
              let commandName = fields["command"] as? String,
              let command = BridgeCommand(rawValue: commandName),
              let timestamp = fields["issuedAt"] as? NSNumber,
              CFGetTypeID(timestamp) != CFBooleanGetTypeID(),
              let parameters = fields["parameters"] as? [String: Any]
        else { return .failure(.invalid) }
        let issuedAt = timestamp.doubleValue
        guard issuedAt.isFinite, now - issuedAt <= BridgeProtocol.requestLifetime,
              issuedAt - now <= 5 else { return .failure(.expired) }
        let normalizedID = id.uuidString.lowercased()
        guard !usedIDs.contains(normalizedID) else { return .failure(.replay) }
        var signedFields = fields
        signedFields.removeValue(forKey: "signature")
        guard let signedPayload = try? JSONSerialization.data(
            withJSONObject: signedFields, options: [.sortedKeys]) else {
            return .failure(.invalid)
        }
        return .success(ClientBridgeEnvelope(
            clientID: clientID.uuidString.lowercased(), signature: signature,
            signedPayload: signedPayload,
            request: BridgeRequest(id: normalizedID, command: command,
                                   parameters: parameters)))
    }

    private static func unhex(_ string: String) -> Data? {
        guard string.count == 128, string.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { return nil }
        var bytes = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
