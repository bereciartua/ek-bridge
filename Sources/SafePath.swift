import Darwin
import Foundation

// Private-file checks shared by bridge-client, bridge-mcp and the app (Copy
// Token…). Every read refuses symlinks, other owners and group/other access.

enum SafePath {
    enum Problem: Error {
        case missing
        case symlink
        case otherOwner
        case sharedMode(String)
        case wrongType(String)
        case tooLarge
        case unreadable(Int32)
    }

    /// A private directory: not a symlink, owned by this user, no group/other access.
    static func checkDirectory(_ path: String) throws {
        var details = stat()
        guard lstat(path, &details) == 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? Problem.missing : Problem.unreadable(errno)
        }
        if details.st_mode & S_IFMT == S_IFLNK { throw Problem.symlink }
        guard details.st_mode & S_IFMT == S_IFDIR else { throw Problem.wrongType("directory") }
        try checkOwnerAndMode(details)
    }

    /// A private regular file: not a symlink, owned by this user, no
    /// group/other access, at most `maxBytes`.
    static func readFile(_ path: String, maxBytes: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { throw Problem.missing }
            if code == ELOOP { throw Problem.symlink }
            var details = stat()
            if lstat(path, &details) == 0 {
                if details.st_mode & S_IFMT == S_IFLNK { throw Problem.symlink }
                if details.st_uid != getuid() { throw Problem.otherOwner }
            }
            throw Problem.unreadable(code)
        }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0 else { throw Problem.unreadable(errno) }
        guard details.st_mode & S_IFMT == S_IFREG else { throw Problem.wrongType("regular file") }
        try checkOwnerAndMode(details)
        guard details.st_size <= maxBytes else { throw Problem.tooLarge }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            .read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Problem.tooLarge }
        return data
    }

    private static func checkOwnerAndMode(_ details: stat) throws {
        guard details.st_uid == getuid() else { throw Problem.otherOwner }
        guard details.st_mode & 0o077 == 0 else {
            throw Problem.sharedMode(String(details.st_mode & 0o777, radix: 8))
        }
    }

    static func atomicWrite(_ data: Data, to path: String) -> Bool {
        let temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
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
            return false
        }
        return true
    }
}

enum Hex {
    static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func decode(_ string: String) -> Data? {
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
