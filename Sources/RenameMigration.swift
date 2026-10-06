import Darwin
import Foundation

// One-time move from the app's old identity (EventKit Bridge, 0.7.0 and
// earlier) to EK Bridge. Runs on launch before anything reads settings or the
// data folder:
//
// 1. Moves ~/Library/Application Support/EventKitBridge to …/EKBridge and leaves
//    a symlink at the old path, because users' scripts and agent configs name
//    key and token files there.
// 2. Copies the known settings from the old bundle ID's defaults, keeping any
//    value the new domain already has. The checklist's done and hidden flags
//    aren't copied: macOS asks for Calendar and Reminders access again under
//    the new bundle ID, so the checklist comes back for that.
// 3. Records that it ran, and asks Overview to show the rename notice once.
//
// The old defaults domain is left alone, so the old app still works if it is
// opened again before it's deleted.
struct RenameMigration {
    static let doneKey = "RenameMigrationDone"
    static let noticeKey = "RenameNoticePending"

    /// Every setting the app keeps, except the checklist's done and hidden flags.
    static let copiedKeys = [
        "DurableLocalBridgeEnabled",
        "DockIconMode", "ShowDeveloperTools", "LastPane", "ActivityLastViewed",
        "SetupChecklistSkipped",
        "MCPServerEnabled", "MCPServerPort", "MCPServerAllowedOrigins",
        "ApprovalDefaultAgent", "ApprovalDefaultCommandLine",
        "RemoteAccessEnabled", "MCPRemotePort", "RemoteAccessSecretPath", "RemoteAccessPublicAddress",
        "RemoteAccessAutoOff", "RemoteAccessOffAt", "RemoteAccessKeepAwake",
        "testCalendarIdentifier", "testReminderListIdentifier",
        "NSWindow Frame MainWindow",
    ]

    enum Outcome: Equatable {
        case alreadyDone
        /// A new install: nothing of the old app's was found.
        case nothingToMigrate
        case migrated(settings: Int, movedData: Bool)
        /// Nothing was recorded, so the next launch tries again.
        case failed(String)
    }

    let defaults: UserDefaults
    let legacyDefaults: UserDefaults?
    /// `~/Library/Application Support`.
    let support: URL

    var newFolder: URL { AppIdentity.dataFolder(inSupport: support) }
    var oldFolder: URL { support.appendingPathComponent(LegacyIdentity.dataFolderName, isDirectory: true) }

    /// Whether `run()` would do anything. Cheap; used to decide whether the old
    /// app has to quit first.
    var isPending: Bool {
        guard defaults.object(forKey: Self.doneKey) == nil else { return false }
        return Self.isRealDirectory(oldFolder) || !legacySettings.isEmpty
    }

    func run() -> Outcome {
        guard defaults.object(forKey: Self.doneKey) == nil else { return .alreadyDone }
        let settings = legacySettings
        let hasOldFolder = Self.isRealDirectory(oldFolder)
        guard hasOldFolder || !settings.isEmpty else {
            defaults.set(1, forKey: Self.doneKey)
            return .nothingToMigrate
        }
        if hasOldFolder, let problem = moveDataFolder() { return .failed(problem) }
        var copied = 0
        for (key, value) in settings where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        defaults.set(true, forKey: Self.noticeKey)
        defaults.set(1, forKey: Self.doneKey)
        return .migrated(settings: copied, movedData: hasOldFolder)
    }

    private var legacySettings: [String: Any] {
        guard let legacyDefaults else { return [:] }
        var result = [String: Any]()
        for key in Self.copiedKeys {
            if let value = legacyDefaults.object(forKey: key) { result[key] = value }
        }
        return result
    }

    /// Nil on success, else what went wrong in words for the alert.
    private func moveDataFolder() -> String? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: newFolder.path) || Self.isSymlink(newFolder) {
            // A folder made by an earlier, interrupted launch: only an empty one is replaced.
            let contents = (try? fileManager.contentsOfDirectory(atPath: newFolder.path)) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }), Self.isRealDirectory(newFolder),
                  (try? fileManager.removeItem(at: newFolder)) != nil else {
                return String(localized: "Both \(Self.display(oldFolder.path)) and \(Self.display(newFolder.path)) exist. Move one of them out of Application Support, then open \(AppIdentity.displayName) again.")
            }
        }
        guard rename(oldFolder.path, newFolder.path) == 0 else {
            let reason = String(cString: strerror(errno))
            return String(localized: "\(Self.display(oldFolder.path)) couldn't be renamed to \(AppIdentity.dataFolderName) (\(reason)). Check its permissions, then open \(AppIdentity.displayName) again.")
        }
        // Relative, so the link survives a renamed home folder. A missing link
        // only affects scripts that name the old path, so it isn't fatal.
        _ = symlink(AppIdentity.dataFolderName, oldFolder.path)
        return nil
    }

    static func isRealDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    private static func display(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
