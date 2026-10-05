import Darwin
import Foundation

/// `mcp-endpoint.json` tells `bridge-mcp` where the server listens and which
/// process owns it, so changing the port never breaks launcher setups. It
/// holds no secret. A stale file after a crash is harmless: the launcher
/// checks the listener, not the file.
struct MCPEndpointFile {
    static let name = "mcp-endpoint.json"
    let directory: URL

    var url: URL { directory.appendingPathComponent(Self.name) }

    static func endpointURL(port: Int) -> String { "http://127.0.0.1:\(port)/mcp" }

    @discardableResult
    func write(port: Int, pid: Int32 = getpid(), startedAt: Date = Date()) -> Bool {
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { return false }
        guard (try? SafePath.checkDirectory(directory.path)) != nil else { return false }
        let object: [String: Any] = [
            "version": 1, "url": Self.endpointURL(port: port), "port": port,
            "pid": Int(pid), "startedAt": Int(startedAt.timeIntervalSince1970),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
        else { return false }
        return SafePath.atomicWrite(data, to: url.path)
    }

    func remove() {
        unlink(url.path)
    }
}
