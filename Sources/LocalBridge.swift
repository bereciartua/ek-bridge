import Darwin
import Foundation
import Security

@MainActor
final class LocalBridge {
    private let root: URL
    private let session: URL
    private let token: String
    private let expiresAt: Date
    private let handle: (BridgeCommand) -> [String: Any]
    private let onStop: () -> Void
    private var timer: Timer?
    private var usedIDs = Set<String>()
    private var lockFD: Int32 = -1

    var expiration: Date { expiresAt }

    init(
        handle: @escaping (BridgeCommand) -> [String: Any],
        onStop: @escaping () -> Void
    ) throws {
        self.handle = handle
        self.onStop = onStop
        root = URL(fileURLWithPath: "/tmp/eventkit-bridge-\(getuid())", isDirectory: true)
        session = root.appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        expiresAt = Date().addingTimeInterval(BridgeProtocol.sessionLifetime)

        var randomBytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes) == errSecSuccess else {
            throw BridgeIOError.randomFailed
        }
        token = randomBytes.map { String(format: "%02x", $0) }.joined()

        try Self.ensureDirectory(root)
        let lockPath = root.appendingPathComponent("lock").path
        lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0, Self.isOwnedRegularFile(lockFD, maxBytes: 0),
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            lockFD = -1
            throw BridgeIOError.alreadyActive
        }

        do {
            try Self.ensureDirectory(session)
            try Self.ensureDirectory(session.appendingPathComponent("requests", isDirectory: true))
            try Self.ensureDirectory(session.appendingPathComponent("responses", isDirectory: true))
            let descriptor: [String: Any] = [
                "version": 1,
                "session": session.lastPathComponent,
                "token": token,
                "expiresAt": expiresAt.timeIntervalSince1970,
            ]
            let data = try JSONSerialization.data(withJSONObject: descriptor)
            try Self.writeAtomically(data, to: root.appendingPathComponent("current.json"))
        } catch {
            try? FileManager.default.removeItem(at: session)
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
            throw error
        }

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        unlink(root.appendingPathComponent("current.json").path)
        try? FileManager.default.removeItem(at: session)
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
            lockFD = -1
        }
        onStop()
    }

    private func poll() {
        guard Date() < expiresAt else {
            stop()
            return
        }
        let requests = session.appendingPathComponent("requests", isDirectory: true)
        let responses = session.appendingPathComponent("responses", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: requests.path) else { return }
        for name in names.sorted().prefix(32) where name.hasSuffix(".json") {
            let id = String(name.dropLast(5))
            let requestURL = requests.appendingPathComponent(name)
            guard UUID(uuidString: id) != nil else {
                unlink(requestURL.path)
                continue
            }
            let data = Self.readOwnedFile(requestURL, maxBytes: BridgeProtocol.maxRequestBytes + 1)
            let result = data.map {
                BridgeProtocol.validate($0, token: token, now: Date().timeIntervalSince1970, usedIDs: usedIDs)
            } ?? .failure(.invalid)
            var reply: [String: Any] = ["version": 1, "id": id]
            switch result {
            case .success(let request) where request.id == id:
                usedIDs.insert(id)
                let value = handle(request.command)
                if let error = value["error"] as? String {
                    reply["ok"] = false
                    reply["error"] = error
                } else {
                    reply["ok"] = true
                    reply["result"] = value
                }
            case .success:
                reply["ok"] = false
                reply["error"] = BridgeRequestError.invalid.rawValue
            case .failure(let error):
                reply["ok"] = false
                reply["error"] = error.rawValue
            }
            if let responseData = try? JSONSerialization.data(withJSONObject: reply),
               responseData.count <= BridgeProtocol.maxResponseBytes {
                try? Self.writeAtomically(responseData, to: responses.appendingPathComponent(name))
            }
            unlink(requestURL.path)
        }
    }

    private static func ensureDirectory(_ url: URL) throws {
        if mkdir(url.path, 0o700) != 0, errno != EEXIST { throw BridgeIOError.directoryFailed }
        var details = stat()
        guard lstat(url.path, &details) == 0,
              details.st_mode & S_IFMT == S_IFDIR,
              details.st_uid == getuid(),
              details.st_mode & 0o077 == 0 else { throw BridgeIOError.unsafePath }
    }

    private static func isOwnedRegularFile(_ fd: Int32, maxBytes: Int) -> Bool {
        var details = stat()
        return fstat(fd, &details) == 0 &&
            details.st_mode & S_IFMT == S_IFREG &&
            details.st_uid == getuid() &&
            details.st_mode & 0o077 == 0 &&
            details.st_size <= maxBytes
    }

    private static func readOwnedFile(_ url: URL, maxBytes: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard isOwnedRegularFile(fd, maxBytes: maxBytes) else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? file.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
        return data
    }

    private static func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeIOError.writeFailed }
        var written = 0
        let count = data.count
        let success = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while written < count {
                let next = Darwin.write(fd, base.advanced(by: written), count - written)
                if next <= 0 { return false }
                written += next
            }
            return true
        }
        if success { _ = fsync(fd) }
        close(fd)
        guard success, rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw BridgeIOError.writeFailed
        }
    }
}

enum BridgeIOError: Error {
    case randomFailed
    case directoryFailed
    case unsafePath
    case alreadyActive
    case writeFailed
}
