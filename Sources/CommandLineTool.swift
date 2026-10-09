import Foundation

/// Settings ▸ Advanced ▸ Install Command-Line Tool: links the `bridge-client`
/// inside the app (`Contents/MacOS/bridge-client`) into `~/.local/bin`, which
/// needs no admin rights. Foundation only, so the unit test can use temporary folders.
struct CommandLineTool {
    static let name = "bridge-client"
    /// The source checkout's launcher, the same as `ConnectCommand.sourceProgram`.
    static let sourceProgram = "python3 client.py"
    /// Where `brew install --cask` links `bridge-client` (Apple silicon, Intel).
    static let homebrewBins = [URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]

    enum State: Equatable {
        /// This copy of the app has no bundled `bridge-client`.
        case unavailable
        case notInstalled
        /// The link points at this copy of the app.
        case installed
        /// Something else is at the link path: a link to another copy, or a file.
        case elsewhere
    }

    /// How copied commands start, so they run as pasted.
    enum Program: Equatable {
        /// `bridge-client` is on the PATH and runs this copy: the `~/.local/bin`
        /// link, or Homebrew's.
        case onPath
        /// No link to this copy: the app's own `bridge-client`, by its full path.
        case bundled(path: String)
        /// This copy has no `bridge-client` (a build without one): the source
        /// checkout's launcher, run in the checkout.
        case source

        var text: String {
            switch self {
            case .onPath: CommandLineTool.name
            case .bundled(let path): CommandLineTool.shellWord(path)
            case .source: CommandLineTool.sourceProgram
            }
        }
    }

    enum InstallError: Error, Equatable {
        case unavailable
        /// A file that isn't a symbolic link is in the way; it's never replaced.
        case notALink
        case failed(String)
    }

    let bundledURL: URL
    let linkURL: URL
    /// Links a package manager made (Homebrew's cask): they count for copied
    /// commands, but Settings only installs and reports the `~/.local/bin` one.
    let packageLinkURLs: [URL]
    /// The app path shown in copied commands; the UI review build shows the
    /// installed location instead of its build folder.
    let displayBundledURL: URL

    init(appURL: URL, home: URL, packageBins: [URL] = Self.homebrewBins, displayAppURL: URL? = nil) {
        bundledURL = appURL.appendingPathComponent("Contents/MacOS/\(Self.name)")
        linkURL = home.appendingPathComponent(".local/bin/\(Self.name)")
        packageLinkURLs = packageBins.map { $0.appendingPathComponent(Self.name) }
        displayBundledURL = (displayAppURL ?? appURL).appendingPathComponent("Contents/MacOS/\(Self.name)")
    }

    /// `~/.local/bin/bridge-client`, for display.
    var displayPath: String { (linkURL.path as NSString).abbreviatingWithTildeInPath }

    var state: State {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: bundledURL.path) else { return .unavailable }
        guard (try? files.attributesOfItem(atPath: linkURL.path)) != nil else { return .notInstalled }
        return pointsAtBundled(linkURL) ? .installed : .elsewhere
    }

    /// `bridge-client` when a link on the PATH runs this copy, else the
    /// bundled one by its full path, so a copied command works without
    /// installing anything first.
    var program: Program {
        switch state {
        case .unavailable: return .source
        case .installed: return .onPath
        case .notInstalled, .elsewhere:
            return packageLinkURLs.contains(where: pointsAtBundled) ? .onPath : .bundled(path: displayBundledURL.path)
        }
    }

    /// True when Homebrew (not Settings) linked `bridge-client` to this copy.
    var linkedByPackageManager: Bool {
        state != .installed && state != .unavailable && packageLinkURLs.contains(where: pointsAtBundled)
    }

    /// Whether `link` is a symbolic link that resolves to this copy's `bridge-client`.
    private func pointsAtBundled(_ link: URL) -> Bool {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
            return false
        }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
        return target.standardizedFileURL.resolvingSymlinksInPath().path
            == bundledURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A path as one shell word: as is when it has only safe characters, else in single quotes.
    static func shellWord(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-")
        if path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
