import CryptoKit
import Darwin
import Foundation

private enum ClientError: Error { case invalid, unavailable, timeout }

@main
struct BridgeClientCLI {
    static func main() {
        do {
            let result = try run()
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            FileHandle.standardOutput.write(data + Data([10]))
            if result["ok"] as? Bool != true { exit(1) }
        } catch {
            FileHandle.standardError.write(Data(
                "Bridge request failed or session is unavailable.\n".utf8))
            exit(1)
        }
    }

    private static func run() throws -> [String: Any] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let name = arguments.first, let command = BridgeCommand(rawValue: name)
        else { throw ClientError.invalid }
        var credentialPath: String?
        var parametersPath: String?
        var index = 1
        while index + 1 < arguments.count {
            switch arguments[index] {
            case "--credentials-file" where credentialPath == nil:
                credentialPath = arguments[index + 1]
            case "--params-file" where parametersPath == nil:
                parametersPath = arguments[index + 1]
            default: throw ClientError.invalid
            }
            index += 2
        }
        guard index == arguments.count, let credentialPath else { throw ClientError.invalid }
        let credentialData = try ownedFile(credentialPath, maxBytes: 512)
        guard let credentials = (try? JSONSerialization.jsonObject(with: credentialData)) as? [String: Any],
              Set(credentials.keys) == Set(["clientID", "key"]),
              let clientID = credentials["clientID"] as? String,
              let clientUUID = UUID(uuidString: clientID),
              let key = credentials["key"] as? String,
              key.hasPrefix("ekb_v1_"), key.utf8.count == 71,
              let secret = unhex(String(key.dropFirst(7))), secret.count == 32
        else { throw ClientError.invalid }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let parameters: [String: Any]
        if let parametersPath {
            let data = try ownedFile(parametersPath, maxBytes: 8_192)
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { throw ClientError.invalid }
            parameters = parsed
        } else { parameters = [:] }

        let root = "/tmp/eventkit-bridge-\(getuid())"
        try ownedDirectory(root)
        let descriptorData = try ownedFile(root + "/current.json", maxBytes: 2_048)
        guard let descriptor = (try? JSONSerialization.jsonObject(with: descriptorData)) as? [String: Any],
              Set(descriptor.keys) == Set(["version", "session"]),
              descriptor["version"] as? Int == 2,
              let session = descriptor["session"] as? String,
              session.hasPrefix("session-"), UUID(uuidString: String(session.dropFirst(8))) != nil
        else { throw ClientError.unavailable }
        let sessionPath = root + "/" + session
        let requests = sessionPath + "/requests"
        let responses = sessionPath + "/responses"
        for path in [sessionPath, requests, responses] { try ownedDirectory(path) }

        let requestID = UUID().uuidString.lowercased()
        var object: [String: Any] = [
            "version": 2, "session": session, "id": requestID,
            "clientID": clientUUID.uuidString.lowercased(),
            "command": command.rawValue, "issuedAt": Date().timeIntervalSince1970,
            "parameters": parameters,
        ]
        let signed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let signature = try signingKey.signature(for: signed)
        object["signature"] = hex(signature)
        let request = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard request.count <= BridgeProtocol.maxRequestBytes else { throw ClientError.invalid }
        try atomicWrite(request, to: requests + "/" + requestID + ".json")
        let responsePath = responses + "/" + requestID + ".json"
        let deadline = Date().timeIntervalSince1970 + (command.isWrite ? 60 : 10)
        while Date().timeIntervalSince1970 < deadline {
            if let responseData = try? ownedFile(responsePath,
                                                 maxBytes: BridgeProtocol.maxResponseBytes) {
                _ = unlink(responsePath)
                guard let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
                      response["version"] as? Int == 2,
                      response["id"] as? String == requestID else { throw ClientError.invalid }
                return response
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw ClientError.timeout
    }

    private static func ownedDirectory(_ path: String) throws {
        var details = stat()
        guard lstat(path, &details) == 0,
              details.st_mode & S_IFMT == S_IFDIR,
              details.st_uid == getuid(), details.st_mode & 0o077 == 0
        else { throw ClientError.invalid }
    }

    private static func ownedFile(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ClientError.invalid }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0,
              details.st_mode & S_IFMT == S_IFREG,
              details.st_uid == getuid(), details.st_mode & 0o077 == 0,
              details.st_size <= maxBytes else { throw ClientError.invalid }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw ClientError.invalid }
        return data
    }

    private static func atomicWrite(_ data: Data, to path: String) throws {
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ClientError.invalid }
        var offset = 0
        let complete = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard complete, rename(temporary, path) == 0 else {
            unlink(temporary)
            throw ClientError.invalid
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
    private static func unhex(_ string: String) -> Data? {
        guard string.count == 64, string.utf8.allSatisfy({
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
}
