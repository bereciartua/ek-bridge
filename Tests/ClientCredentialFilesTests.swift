import Foundation

@main
struct ClientCredentialFilesTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eventkit-credential-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ClientCredentialFiles(parent: root)
        let id = UUID().uuidString.lowercased()
        let first = "ekb_v1_" + String(repeating: "a", count: 64)
        let next = "ekb_v1_" + String(repeating: "b", count: 64)
        let path = value(files.saveNew(clientID: id, key: first))
        precondition(path.lastPathComponent == id + ".json")
        precondition(mode(path) == 0o600)
        precondition(mode(path.deletingLastPathComponent()) == 0o700)
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: String]
        precondition(payload["clientID"] == id && payload["key"] == first)
        failure(files.saveNew(clientID: id, key: next), .alreadyExists)
        precondition(value(files.canReplace(clientID: id)) == path)
        _ = value(files.replace(clientID: id, key: next))
        let replaced = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: String]
        precondition(replaced["key"] == next)
        value(files.remove(clientID: id))
        precondition(!FileManager.default.fileExists(atPath: path.path))

        let symlinkTarget = root.appendingPathComponent("target")
        try Data("not-a-credential".utf8).write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: symlinkTarget)
        failure(files.saveNew(clientID: id, key: first), .alreadyExists)
        failure(files.canReplace(clientID: id), .unsafeExistingFile)
        failure(files.replace(clientID: id, key: first), .unsafeExistingFile)
        failure(files.remove(clientID: id), .unsafeExistingFile)
        try FileManager.default.removeItem(at: path)

        _ = value(files.saveNew(clientID: id, key: first))
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: path.path)
        failure(files.canReplace(clientID: id), .unsafeExistingFile)
        failure(files.replace(clientID: id, key: next), .unsafeExistingFile)
        failure(files.remove(clientID: id), .unsafeExistingFile)
        try FileManager.default.removeItem(at: path)

        failure(files.saveNew(clientID: "../escape", key: first), .invalidCredential)
        failure(files.saveNew(clientID: id, key: "short"), .invalidCredential)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: root.path)
        failure(files.saveNew(clientID: id, key: first), .unsafeDirectory)
        print("Credential files: private create, atomic replace, remove, unsafe path and overwrite checks passed")
    }

    private static func mode(_ url: URL) -> Int {
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        return attributes[.posixPermissions] as! Int
    }
    private static func value<T>(_ result: Result<T, CredentialFileError>) -> T {
        switch result {
        case .success(let value): return value
        case .failure(let error): preconditionFailure("unexpected \(error)")
        }
    }
    private static func failure<T>(_ result: Result<T, CredentialFileError>,
                                   _ expected: CredentialFileError) {
        switch result {
        case .success: preconditionFailure("expected \(expected)")
        case .failure(let error): precondition(error == expected)
        }
    }
}
