import CryptoKit
import Darwin
import Foundation

// A write is recorded as pending before EventKit is called. If the app stops
// between EventKit and the response, retrying cannot silently create twice.
// Pending entries require manual reconciliation. No item titles are stored.
final class WriteJournal {
    enum Decision {
        case execute
        case repeatResult([String: Any])
        case reject(String)
    }

    private struct Entry: Codable {
        let digest: String
        var result: Data?
    }

    private let directory: URL
    private let file: URL
    private var entries: [String: Entry]?

    init(directory override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        directory = override ?? support.appendingPathComponent("EventKitBridge", isDirectory: true)
        file = directory.appendingPathComponent("write-journal.json")
    }

    func inspect(_ request: BridgeRequest) -> Decision {
        guard let key = request.parameters["idempotencyKey"] as? String,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        guard load() else { return .reject("journal_unavailable") }
        if let entry = entries?[key] {
            guard entry.digest == digest else { return .reject("idempotency_conflict") }
            guard let data = entry.result,
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return .reject("idempotency_pending_review") }
            return .repeatResult(result)
        }
        guard (entries?.count ?? 0) < 1_000 else { return .reject("journal_full") }
        return .execute
    }

    func begin(_ request: BridgeRequest) -> Decision {
        switch inspect(request) {
        case .repeatResult(let result): return .repeatResult(result)
        case .reject(let error): return .reject(error)
        case .execute: break
        }
        guard let key = request.parameters["idempotencyKey"] as? String,
              let digest = digest(request) else { return .reject("invalid_idempotency_key") }
        entries?[key] = Entry(digest: digest, result: nil)
        guard persist() else { return .reject("journal_unavailable") }
        return .execute
    }

    func finish(_ request: BridgeRequest, result: [String: Any]) -> Bool {
        guard let key = request.parameters["idempotencyKey"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              entries?[key] != nil else { return false }
        entries?[key]?.result = data
        guard persist() else {
            entries?[key]?.result = nil
            return false
        }
        return true
    }

    private func digest(_ request: BridgeRequest) -> String? {
        let object: [String: Any] = [
            "command": request.command.rawValue,
            "parameters": request.parameters,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func load() -> Bool {
        if entries != nil { return true }
        do {
            let existed = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0,
                  directoryInfo.st_uid == getuid(),
                  directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_mode & 0o077 == 0 else { return false }
            if !existed {
                let parentFD = open(directory.deletingLastPathComponent().path,
                                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard parentFD >= 0 else { return false }
                let synced = fsync(parentFD) == 0
                close(parentFD)
                guard synced else { return false }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                entries = [:]
                return true
            }
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == getuid(),
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_size <= 1_000_000 else { return false }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: 1_000_001) ?? Data()
            entries = try JSONDecoder().decode([String: Entry].self, from: data)
            return true
        } catch { return false }
    }

    private func persist() -> Bool {
        guard let entries, let data = try? JSONEncoder().encode(entries),
              data.count <= 1_000_000 else { return false }
        let temporary = directory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        let success = data.withUnsafeBytes { bytes -> Bool in
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
        guard success, rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            return false
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { return false }
        defer { close(directoryFD) }
        return fsync(directoryFD) == 0
    }
}
