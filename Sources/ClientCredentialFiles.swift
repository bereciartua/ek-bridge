import Darwin
import Foundation

enum CredentialFileError: String, Error {
    case invalidCredential
    case unsafeDirectory
    case unsafeExistingFile
    case alreadyExists
    case missingFile
    case writeFailed
    case removeFailed
}

// Private signing credentials live outside the server's public-verifier JSON.
// The path is fixed by client UUID; no caller-supplied path enters file APIs.
// This protects against other UIDs, not a malicious process with the same UID.
final class ClientCredentialFiles {
    private let parent: URL
    private let directory: URL

    init(parent override: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask)[0]
        parent = override ?? support.appendingPathComponent("EventKitBridge", isDirectory: true)
        directory = parent.appendingPathComponent("client-credentials", isDirectory: true)
    }

    func url(for clientID: String) -> URL? {
        guard let uuid = UUID(uuidString: clientID) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString.lowercased() + ".json")
    }

    func canReplace(clientID: String) -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID) else { return .failure(.invalidCredential) }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            guard Self.safeFile(name: destination.lastPathComponent, in: fd) else {
                return .failure(.unsafeExistingFile)
            }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    func saveNew(clientID: String, key: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, key: key, replacing: false)
    }

    func replace(clientID: String, key: String) -> Result<URL, CredentialFileError> {
        write(clientID: clientID, key: key, replacing: true)
    }

    func remove(clientID: String) -> Result<Void, CredentialFileError> {
        guard let destination = url(for: clientID) else { return .failure(.invalidCredential) }
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) != 0 && errno == ENOENT {
            guard lstat(parent.path, &directoryInfo) == 0,
                  Self.safeDirectory(directoryInfo) else { return .failure(.unsafeDirectory) }
            return .success(())
        }
        do {
            let fd = try openDirectory(create: false)
            defer { close(fd) }
            let name = destination.lastPathComponent
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .success(()) : .failure(.removeFailed)
            }
            guard Self.safe(info) else { return .failure(.unsafeExistingFile) }
            guard unlinkat(fd, name, 0) == 0, fsync(fd) == 0 else {
                return .failure(.removeFailed)
            }
            return .success(())
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    private func write(clientID: String, key: String, replacing: Bool)
        -> Result<URL, CredentialFileError> {
        guard let destination = url(for: clientID), Self.validKey(key),
              let data = try? JSONSerialization.data(withJSONObject: [
                "clientID": UUID(uuidString: clientID)!.uuidString.lowercased(),
                "key": key,
              ], options: [.sortedKeys]), data.count <= 512 else {
            return .failure(.invalidCredential)
        }
        do {
            let directoryFD = try openDirectory(create: !replacing)
            defer { close(directoryFD) }
            let name = destination.lastPathComponent
            var info = stat()
            let exists = fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            if replacing {
                guard exists, Self.safe(info) else { return .failure(.unsafeExistingFile) }
            } else if exists {
                return .failure(.alreadyExists)
            } else if errno != ENOENT {
                return .failure(.unsafeExistingFile)
            }
            let temporary = ".tmp-\(UUID().uuidString.lowercased())"
            let tempFD = openat(directoryFD, temporary,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard tempFD >= 0 else { return .failure(.writeFailed) }
            defer { unlinkat(directoryFD, temporary, 0) }
            guard fchmod(tempFD, 0o600) == 0 else {
                close(tempFD)
                return .failure(.writeFailed)
            }
            let written = data.withUnsafeBytes { bytes -> Bool in
                guard let base = bytes.baseAddress else { return false }
                var offset = 0
                while offset < data.count {
                    let count = Darwin.write(tempFD, base.advanced(by: offset), data.count - offset)
                    if count <= 0 { return false }
                    offset += count
                }
                return fsync(tempFD) == 0
            }
            close(tempFD)
            guard written else { return .failure(.writeFailed) }
            let installed = replacing
                ? renameat(directoryFD, temporary, directoryFD, name) == 0
                : linkat(directoryFD, temporary, directoryFD, name, 0) == 0
            guard installed, fsync(directoryFD) == 0 else { return .failure(.writeFailed) }
            return .success(destination)
        } catch let error as CredentialFileError { return .failure(error) }
        catch { return .failure(.unsafeDirectory) }
    }

    private func openDirectory(create: Bool) throws -> Int32 {
        var info = stat()
        guard lstat(parent.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        if create && mkdir(directory.path, 0o700) != 0 && errno != EEXIST {
            throw CredentialFileError.unsafeDirectory
        }
        guard lstat(directory.path, &info) == 0, Self.safeDirectory(info) else {
            throw CredentialFileError.unsafeDirectory
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CredentialFileError.unsafeDirectory }
        guard fstat(fd, &info) == 0, Self.safeDirectory(info) else {
            close(fd)
            throw CredentialFileError.unsafeDirectory
        }
        return fd
    }

    private static func safeDirectory(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() &&
            info.st_mode & 0o077 == 0
    }

    private static func safeFile(name: String, in directoryFD: Int32) -> Bool {
        var info = stat()
        return fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && safe(info)
    }

    private static func safe(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() &&
            info.st_mode & 0o777 == 0o600 && info.st_size <= 512
    }

    private static func validKey(_ key: String) -> Bool {
        key.hasPrefix("ekb_v1_") && key.utf8.count == 71 &&
            key.dropFirst(7).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
