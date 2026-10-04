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

    func begin(_ request: BridgeRequest) -> Decision {
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
        entries?[key] = Entry(digest: digest, result: nil)
        guard persist() else {
            entries?.removeValue(forKey: key)
            return .reject("journal_unavailable")
        }
        return .execute
    }

    func finish(_ request: BridgeRequest, result: [String: Any]) -> Bool {
        guard let key = request.parameters["idempotencyKey"] as? String,
              let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
              entries?[key] != nil else { return false }
        entries?[key]?.result = data
        return persist()
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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return false }
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
        return true
    }
}
