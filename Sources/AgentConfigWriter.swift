import Foundation

// One-click agent setup (B07, D3) uses BridgeKitCore's AgentConfigWriter: it
// adds EK Bridge's entry to another app's config file, after a click, with a
// preview and a backup, never with a token. EK Bridge's names for it:

extension ConfigWriteError {
    var message: String { message(appName: AppIdentity.displayName) }
}

extension AgentConfigWriter {
    /// Backups are `<file>.ekbridge-backup-<suffix>`.
    @discardableResult
    static func apply(_ change: ConfigChange, backupSuffix: String,
                      fileManager: FileManager = .default) throws -> URL? {
        try apply(change, tag: "ekbridge", backupSuffix: backupSuffix, fileManager: fileManager)
    }
}
