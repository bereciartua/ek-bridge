import Foundation

/// Where the running app is, for Move to Applications. Foundation only, so
/// it's unit tested (Tests/InstallLocationTests.swift); `AppMover` supplies
/// the paths.
enum InstallLocation: Equatable {
    /// `/Applications/…` or `~/Applications/…` (also on another volume).
    case applications
    /// Under `/Volumes/`: opened from the disk image.
    case diskImage(volume: String)
    /// Gatekeeper's App Translocation copy; `original` is where the user
    /// opened it, when macOS says.
    case translocated(original: String?)
    case elsewhere(path: String)

    /// `originalPath` is `SecTranslocateCreateOriginalPathForURL`'s answer
    /// for a translocated app, else nil.
    static func classify(bundlePath: String, home: String, originalPath: String?) -> InstallLocation {
        let path = (bundlePath as NSString).standardizingPath
        if path.contains("/AppTranslocation/") {
            return .translocated(original: originalPath.map { ($0 as NSString).standardizingPath })
        }
        if isInApplications(path, home: home) { return .applications }
        if let volume = volume(of: path) { return .diskImage(volume: volume) }
        return .elsewhere(path: path)
    }

    static func isInApplications(_ path: String, home: String) -> Bool {
        let home = (home as NSString).standardizingPath
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return true }
        // An Applications folder at the root of another volume.
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 4 && parts[0] == "Volumes" && parts[2] == "Applications"
    }

    /// "/Volumes/EK Bridge" for a path inside a mounted volume.
    static func volume(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }

    /// The bundle to copy and, after the move, to clean up: the original
    /// for a translocated app (nil when unknown), else the running one.
    func sourcePath(running: String) -> String? {
        switch self {
        case .translocated(let original): original
        default: (running as NSString).standardizingPath
        }
    }

    /// Where the copy goes: `/Applications` when it's writable, else
    /// `~/Applications`.
    static func destination(bundleFileName: String, applicationsWritable: Bool, home: String) -> String {
        let folder = applicationsWritable ? "/Applications" : (home as NSString).appendingPathComponent("Applications")
        return (folder as NSString).appendingPathComponent(bundleFileName)
    }

    /// "Downloads", "the disk image", "a temporary location", for the prompt.
    func placeName(home: String) -> String {
        switch self {
        case .applications: return String(localized: "Applications")
        case .diskImage: return String(localized: "the disk image")
        case .translocated(let original):
            if let original, Self.volume(of: original) != nil { return String(localized: "the disk image") }
            return String(localized: "a temporary location")
        case .elsewhere(let path):
            let folder = ((path as NSString).deletingLastPathComponent as NSString)
            let downloads = ((home as NSString).standardizingPath as NSString).appendingPathComponent("Downloads")
            if folder.standardizingPath == downloads || path.hasPrefix(downloads + "/") {
                return String(localized: "Downloads")
            }
            return String(localized: "the “\(folder.lastPathComponent)” folder")
        }
    }

    /// After the move, what happens to the old copy: a disk image is
    /// offered for ejecting; anything else goes to the Trash.
    var leavesVolume: String? {
        switch self {
        case .diskImage(let volume): volume
        case .translocated(let original?): Self.volume(of: original)
        default: nil
        }
    }
}
