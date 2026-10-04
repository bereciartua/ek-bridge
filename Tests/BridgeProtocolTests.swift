import Foundation

@main
struct BridgeProtocolTests {
    static func main() throws {
        let id = UUID().uuidString
        let token = String(repeating: "a", count: 64)
        let now = Date().timeIntervalSince1970

        func message(
            command: String = "calendar_count",
            suppliedToken: String? = nil,
            issuedAt: TimeInterval? = nil,
            extra: Bool = false
        ) throws -> Data {
            var object: [String: Any] = [
                "version": 1,
                "id": id,
                "command": command,
                "token": suppliedToken ?? token,
                "issuedAt": issuedAt ?? now,
            ]
            if extra { object["unapproved"] = true }
            return try JSONSerialization.data(withJSONObject: object)
        }

        func expect(_ result: Result<BridgeRequest, BridgeRequestError>,
                    command: BridgeCommand? = nil,
                    error: BridgeRequestError? = nil) {
            switch result {
            case .success(let request):
                precondition(error == nil && request.id == id && request.command == command)
            case .failure(let failure):
                precondition(command == nil && failure.rawValue == error?.rawValue)
            }
        }

        expect(BridgeProtocol.validate(try message(), token: token, now: now, usedIDs: []),
               command: .calendarCount)
        expect(BridgeProtocol.validate(try message(suppliedToken: "wrong"), token: token,
                                       now: now, usedIDs: []), error: .unauthorized)
        expect(BridgeProtocol.validate(try message(command: "read_events"), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(try message(issuedAt: now - 31), token: token,
                                       now: now, usedIDs: []), error: .expired)
        expect(BridgeProtocol.validate(try message(issuedAt: now + 6), token: token,
                                       now: now, usedIDs: []), error: .expired)
        expect(BridgeProtocol.validate(try message(), token: token,
                                       now: now, usedIDs: [id]), error: .replay)
        expect(BridgeProtocol.validate(try message(extra: true), token: token,
                                       now: now, usedIDs: []), error: .invalid)
        expect(BridgeProtocol.validate(Data(repeating: 65, count: 2_049), token: token,
                                       now: now, usedIDs: []), error: .tooLarge)
        print("Bridge protocol: 8 positive/negative checks passed")
    }
}
