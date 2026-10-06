import Foundation

/// Settings ▸ Developer ▸ Install Command-Line Tool: links the `bridge-client`
/// inside the app (`Contents/MacOS/bridge-client`) into `~/.local/bin`, which
/// needs no admin rights. Foundation only, so the unit test can use temporary folders.
struct CommandLineTool {
    static let name = "bridge-client"

    enum State: Equatable {
        /// This copy of the app has no bundled `bridge-client`.
        case unavailable
        case notInstalled
        /// The link points at this copy of the app.
        case installed
        /// Something else is at the link path: a link to another copy, or a file.
        case elsewhere
    }

    enum InstallError: Error, Equatable {
        case unavailable
        /// A file that isn't a symbolic link is in the way; it's never replaced.
        case notALink
        case failed(String)
    }

    let bundledURL: URL
    let linkURL: URL

    init(appURL: URL, home: URL) {
        bundledURL = appURL.appendingPathComponent("Contents/MacOS/\(Self.name)")
        linkURL = home.appendingPathComponent(".local/bin/\(Self.name)")
    }

    /// `~/.local/bin/bridge-client`, for display.
    var displayPath: String { (linkURL.path as NSString).abbreviatingWithTildeInPath }

    var state: State {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: bundledURL.path) else { return .unavailable }
        guard (try? files.attributesOfItem(atPath: linkURL.path)) != nil else { return .notInstalled }
        guard let destination = try? files.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return .elsewhere
        }
        let target = URL(fileURLWithPath: destination, relativeTo: linkURL.deletingLastPathComponent())
        return target.standardizedFileURL.resolvingSymlinksInPath().path
            == bundledURL.standardizedFileURL.resolvingSymlinksInPath().path ? .installed : .elsewhere
    }

    /// Creates `~/.local/bin` if needed and replaces a link that's already there
    /// (from another copy of the app), but never a regular file.
    func install() -> Result<URL, InstallError> {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: bundledURL.path) else { return .failure(.unavailable) }
        do {
            try files.createDirectory(at: linkURL.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            if let type = (try? files.attributesOfItem(atPath: linkURL.path))?[.type] as? FileAttributeType {
                guard type == .typeSymbolicLink else { return .failure(.notALink) }
                try files.removeItem(at: linkURL)
            }
            try files.createSymbolicLink(at: linkURL, withDestinationURL: bundledURL)
            return .success(linkURL)
        } catch {
            return .failure(.failed(error.localizedDescription))
        }
    }
}
