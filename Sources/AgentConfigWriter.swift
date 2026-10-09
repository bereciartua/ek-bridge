import Foundation

// One-click agent setup (B07, D3): adds EK Bridge's entry to another app's
// JSON config file, after a click, with a preview and a backup, never with a
// token. Foundation-only and unit tested.
//
// Rules: refuse what doesn't parse (or isn't an object, or is over 1 MB);
// keep every other key and value and the user's formatting by inserting text
// instead of re-serializing; check the result means exactly "the old file plus
// this entry"; re-read before writing; back up first; write atomically.

struct DiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    let kind: Kind
    let text: String
}

/// What the preview shows and what `apply` writes.
struct ConfigChange: Equatable {
    enum Outcome: Equatable { case created, added, replaced, unchanged }

    let fileURL: URL
    /// nil when the file doesn't exist yet.
    let before: Data?
    let after: Data
    let outcome: Outcome
    let summary: String
    let diffLines: [DiffLine]
}

enum ConfigWriteError: Error, Equatable {
    case invalidJSON(String)
    case notAnObject
    /// `root` exists but isn't an object.
    case rootNotAnObject(String)
    case tooLarge
    case unreadable
    case unwritable(String)
    case changedSinceReading
    /// The insert didn't produce "the old file plus this entry" (never expected).
    case verificationFailed
    /// TOML (C07): the server is already there in another shape.
    case existingEntry(String)
    /// TOML (C07): `mcp_servers` is written inline, so no table can be added.
    case inlineTable(String)
    case notText

    var message: String {
        switch self {
        case .invalidJSON(let reason): String(localized: "The file isn't valid JSON (\(reason)), so EK Bridge won't change it.")
        case .notAnObject: String(localized: "The file doesn't hold a JSON object, so EK Bridge won't change it.")
        case .rootNotAnObject(let root): String(localized: "Its “\(root)” isn't an object, so EK Bridge won't change it.")
        case .tooLarge: String(localized: "The file is over 1 MB, so EK Bridge won't change it.")
        case .unreadable: String(localized: "The file can't be read.")
        case .unwritable(let reason): String(localized: "The file couldn't be written: \(reason)")
        case .changedSinceReading: String(localized: "The file changed while the preview was open. Nothing was written; try again.")
        case .verificationFailed: String(localized: "EK Bridge couldn't add its entry without changing anything else, so nothing was written.")
        case .existingEntry(let key): String(localized: "It already has a different “\(key)” entry, so EK Bridge won't change it.")
        case .inlineTable(let table): String(localized: "Its \(table) is written on one line, so EK Bridge won't change it.")
        case .notText: String(localized: "The file isn't UTF-8 text, so EK Bridge won't change it.")
        }
    }
}

enum AgentConfigWriter {
    static let maxBytes = 1_000_000

    // MARK: Merge (pure)

    /// The file after adding `entry` under `root` ▸ `key`, and what that does.
    static func merge(current: Data?, root: String = "mcpServers", key: String,
                      entry: SetupJSON) throws -> (after: Data, outcome: ConfigChange.Outcome) {
        let text = current.map { String(decoding: $0, as: UTF8.self) } ?? ""
        guard (current?.count ?? 0) <= maxBytes else { throw ConfigWriteError.tooLarge }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let body = SetupJSON.object([(root, .object([(key, entry)]))]).pretty(unit: "  ", level: 0)
            return (Data((body + "\n").utf8), current == nil ? .created : .added)
        }
        let object = try parse(Data(text.utf8))
        let entryValue = try JSONSerialization.jsonObject(with: Data(entry.text.utf8))
        var servers: [String: Any]?
        if let existing = object[root] {
            guard let dictionary = existing as? [String: Any] else { throw ConfigWriteError.rootNotAnObject(root) }
            servers = dictionary
            if let old = dictionary[key], (old as AnyObject).isEqual(entryValue) {
                return (Data(text.utf8), .unchanged)
            }
        }
        let scanner = JSONScanner(text)
        guard let top = scanner.topObject() else { throw ConfigWriteError.invalidJSON("no object") }
        // One-line files stay on one line; an empty "{}" becomes a block.
        let compact = !scanner.members(of: top).isEmpty && !scanner.slice(top.open...top.close).contains("\n")
        let unit = scanner.indentUnit(inside: top) ?? "  "
        var result: String
        let outcome: ConfigChange.Outcome
        if let rootMember = scanner.member(root, in: top), let rootObject = scanner.objectSpan(at: rootMember.valueStart) {
            if let existing = scanner.member(key, in: rootObject) {
                // Replace the old value only.
                let rendered = compact ? entry.text : entry.pretty(unit: unit, level: 2)
                result = scanner.replacing(existing.valueStart..<existing.valueEnd, with: rendered)
                outcome = .replaced
            } else {
                result = scanner.inserting(member: (key, entry), into: rootObject, level: 2, unit: unit, compact: compact)
                outcome = .added
            }
        } else {
            result = scanner.inserting(member: (root, .object([(key, entry)])), into: top, level: 1,
                                       unit: unit, compact: compact)
            outcome = .added
        }
        // The result must mean exactly the old file with this entry set.
        var expected = object
        var expectedServers = servers ?? [:]
        expectedServers[key] = entryValue
        expected[root] = expectedServers
        guard let parsed = try? parse(Data(result.utf8)),
              (parsed as NSDictionary).isEqual(to: expected) else { throw ConfigWriteError.verificationFailed }
        if !result.hasSuffix("\n") && text.hasSuffix("\n") { result += "\n" }
        return (Data(result.utf8), outcome)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "parse error"
            throw ConfigWriteError.invalidJSON(reason)
        }
        guard let object = value as? [String: Any] else { throw ConfigWriteError.notAnObject }
        return object
    }

    // MARK: Preview

    /// Reads the file (if any) and builds the change. `fileURL` is the path as
    /// configured; a symbolic link is followed, so dotfile setups keep their link.
    static func preview(fileURL: URL, root: String = "mcpServers", key: String, entry: SetupJSON,
                        fileManager: FileManager = .default) throws -> ConfigChange {
        let target = fileURL.resolvingSymlinksInPath()
        let before = try read(target, fileManager: fileManager)
        let merged = try merge(current: before, root: root, key: key, entry: entry)
        let name = fileURL.lastPathComponent
        let summary: String = switch merged.outcome {
        case .created: String(localized: "Creates \(name) with “\(key)” under \(root)")
        case .added: String(localized: "Adds “\(key)” to \(root)")
        case .replaced: String(localized: "Replaces the existing “\(key)” entry")
        case .unchanged: String(localized: "Already set up: “\(key)” is there and up to date")
        }
        return ConfigChange(fileURL: target, before: before, after: merged.after, outcome: merged.outcome,
                            summary: summary, diffLines: diff(before ?? Data(), merged.after))
    }

    // MARK: TOML (C07)

    /// Codex's config.toml after appending `table` ("[mcp_servers.<key>]" and
    /// its lines). Nothing else in the file is touched. Refuses when the
    /// server is already defined differently, or in any other shape (a dotted
    /// key, a line in [mcp_servers], an inline mcp_servers), since TOML
    /// can't define it twice.
    static func appendTOML(current: Data?, key: String, table: String) throws -> (after: Data, outcome: ConfigChange.Outcome) {
        guard let current else { return (Data((table + "\n").utf8), .created) }
        guard let text = String(data: current, encoding: .utf8) else { throw ConfigWriteError.notText }
        let tableLines = table.components(separatedBy: "\n")
        let header = normalizedHeader(tableLines[0])
        let wanted = tableLines.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let lines = text.components(separatedBy: "\n")
        let bareKey = key.replacingOccurrences(of: "\"", with: "")
        var inServers = false
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { index += 1; continue }
            if line.hasPrefix("[") {
                let name = normalizedHeader(line)
                inServers = name == "[mcp_servers]"
                if name == header {
                    // The same table: identical is "already set up", anything else is refused.
                    var body = [String]()
                    var next = index + 1
                    while next < lines.count, !lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                        let entry = lines[next].trimmingCharacters(in: .whitespaces)
                        if !entry.isEmpty && !entry.hasPrefix("#") { body.append(entry) }
                        next += 1
                    }
                    if body == wanted { return (current, .unchanged) }
                    throw ConfigWriteError.existingEntry(key)
                }
                if name.hasPrefix(String(header.dropLast()) + ".") { throw ConfigWriteError.existingEntry(key) }
                index += 1
                continue
            }
            let compact = line.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
            if compact.hasPrefix("mcp_servers=") { throw ConfigWriteError.inlineTable("mcp_servers") }
            if compact.hasPrefix("mcp_servers.\(bareKey).") || compact.hasPrefix("mcp_servers.\(bareKey)=")
                || (inServers && (compact.hasPrefix("\(bareKey)=") || compact.hasPrefix("\(bareKey)."))) {
                throw ConfigWriteError.existingEntry(key)
            }
            index += 1
        }
        var after = text
        if !after.isEmpty && !after.hasSuffix("\n") { after += "\n" }
        if !after.isEmpty { after += "\n" }
        after += table + "\n"
        return (Data(after.utf8), .added)
    }

    /// "[ mcp_servers . "ek-bridge" ]" → "[mcp_servers.ek-bridge]".
    private static func normalizedHeader(_ line: String) -> String {
        var header = line
        if let comment = header.range(of: "#", options: .backwards), !header[comment.lowerBound...].contains("]") {
            header = String(header[..<comment.lowerBound])
        }
        return header.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    static func previewTOML(fileURL: URL, key: String, table: String,
                            fileManager: FileManager = .default) throws -> ConfigChange {
        let target = fileURL.resolvingSymlinksInPath()
        let before = try read(target, fileManager: fileManager)
        let appended = try appendTOML(current: before, key: key, table: table)
        let name = fileURL.lastPathComponent
        let summary: String = switch appended.outcome {
        case .created: String(localized: "Creates \(name) with the “\(key)” server")
        case .unchanged: String(localized: "Already set up: “\(key)” is there and up to date")
        default: String(localized: "Adds the “\(key)” server at the end")
        }
        return ConfigChange(fileURL: target, before: before, after: appended.after, outcome: appended.outcome,
                            summary: summary, diffLines: diff(before ?? Data(), appended.after))
    }

    static func read(_ url: URL, fileManager: FileManager) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxBytes else { throw ConfigWriteError.tooLarge }
        guard let data = fileManager.contents(atPath: url.path) else { throw ConfigWriteError.unreadable }
        return data
    }

    /// Changed lines with up to two lines of context on each side.
    static func diff(_ before: Data, _ after: Data, context: Int = 2) -> [DiffLine] {
        let old = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        let new = String(decoding: after, as: UTF8.self).components(separatedBy: "\n")
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let removed = old[prefix..<(old.count - suffix)]
        let added = new[prefix..<(new.count - suffix)]
        guard !removed.isEmpty || !added.isEmpty else { return [] }
        let leading = new[max(0, prefix - context)..<prefix]
        let trailingStart = new.count - suffix
        let trailing = new[trailingStart..<min(new.count, trailingStart + context)]
        return leading.map { DiffLine(kind: .context, text: $0) }
            + removed.map { DiffLine(kind: .removed, text: $0) }
            + added.map { DiffLine(kind: .added, text: $0) }
            + trailing.filter { !$0.isEmpty }.map { DiffLine(kind: .context, text: $0) }
    }

    // MARK: Apply

    /// Writes the change after checking the file is still what the preview
    /// read. Returns the backup's URL (nil for a new file).
    @discardableResult
    static func apply(_ change: ConfigChange, backupSuffix: String,
                      fileManager: FileManager = .default) throws -> URL? {
        guard change.outcome != .unchanged else { return nil }
        let url = change.fileURL
        let current = try read(url, fileManager: fileManager)
        guard current == change.before else { throw ConfigWriteError.changedSinceReading }
        let folder = url.deletingLastPathComponent()
        do {
            if !fileManager.fileExists(atPath: folder.path) {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
            var backup: URL?
            var permissions = 0o600
            if current != nil {
                permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o600
                let copy = folder.appendingPathComponent("\(url.lastPathComponent).ekbridge-backup-\(backupSuffix)")
                try? fileManager.removeItem(at: copy)
                try fileManager.copyItem(at: url, to: copy)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                backup = copy
            }
            let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).ekbridge-\(UUID().uuidString)")
            guard fileManager.createFile(atPath: temporary.path, contents: change.after,
                                         attributes: [.posixPermissions: permissions]) else {
                throw ConfigWriteError.unwritable(String(localized: "couldn't create a temporary file"))
            }
            if current != nil {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
            return backup
        } catch let error as ConfigWriteError {
            throw error
        } catch {
            throw ConfigWriteError.unwritable(error.localizedDescription)
        }
    }

    /// "20261008-154210", for backup names.
    static func backupSuffix(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

/// A small JSON tokenizer over the file's text: finds objects, their members
/// and value spans, so an entry can be inserted without re-serializing the file.
/// Works on Unicode scalars; offsets are indices into `scalars`.
struct JSONScanner {
    struct ObjectSpan { let open: Int; let close: Int }
    struct Member { let keyStart: Int; let valueStart: Int; let valueEnd: Int }

    let scalars: [Unicode.Scalar]

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    func slice(_ range: ClosedRange<Int>) -> String { string(range.lowerBound..<(range.upperBound + 1)) }

    func string(_ range: Range<Int>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[range])
        return String(view)
    }

    private func isSpace(_ index: Int) -> Bool {
        index < scalars.count && [" ", "\t", "\n", "\r"].contains(scalars[index])
    }

    private func skipSpace(_ index: Int) -> Int {
        var index = index
        while isSpace(index) { index += 1 }
        return index
    }

    /// The end (exclusive) of the string starting at `index` (a quote).
    private func stringEnd(_ index: Int) -> Int? {
        var i = index + 1
        while i < scalars.count {
            if scalars[i] == "\\" { i += 2; continue }
            if scalars[i] == "\"" { return i + 1 }
            i += 1
        }
        return nil
    }

    /// The end (exclusive) of the value starting at `index`.
    func valueEnd(_ index: Int) -> Int? {
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "\"": return stringEnd(index)
        case "{", "[":
            var depth = 0
            var i = index
            while i < scalars.count {
                switch scalars[i] {
                case "\"": guard let end = stringEnd(i) else { return nil }; i = end; continue
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default: break
                }
                i += 1
            }
            return nil
        default:
            var i = index
            while i < scalars.count, !isSpace(i), ![",", "}", "]"].contains(scalars[i]) { i += 1 }
            return i
        }
    }

    func topObject() -> ObjectSpan? {
        let start = skipSpace(0)
        guard start < scalars.count, scalars[start] == "{", let end = valueEnd(start) else { return nil }
        return ObjectSpan(open: start, close: end - 1)
    }

    func objectSpan(at index: Int) -> ObjectSpan? {
        guard index < scalars.count, scalars[index] == "{", let end = valueEnd(index) else { return nil }
        return ObjectSpan(open: index, close: end - 1)
    }

    /// The object's members in order.
    func members(of object: ObjectSpan) -> [(key: String, member: Member)] {
        var result = [(key: String, member: Member)]()
        var i = skipSpace(object.open + 1)
        while i < object.close, scalars[i] == "\"" {
            guard let keyEnd = stringEnd(i) else { break }
            let keyText = string(i..<keyEnd)
            let key = (try? JSONSerialization.jsonObject(with: Data(keyText.utf8), options: .fragmentsAllowed)) as? String
            var j = skipSpace(keyEnd)
            guard j < object.close, scalars[j] == ":" else { break }
            j = skipSpace(j + 1)
            guard let end = valueEnd(j) else { break }
            result.append((key ?? "", Member(keyStart: i, valueStart: j, valueEnd: end)))
            i = skipSpace(end)
            if i < object.close, scalars[i] == "," { i = skipSpace(i + 1) }
        }
        return result
    }

    /// The last member with this key (JSON parsers keep the last duplicate).
    func member(_ key: String, in object: ObjectSpan) -> Member? {
        members(of: object).last { $0.key == key }?.member
    }

    /// The indentation of an object's first member, or nil on one line.
    func indentUnit(inside object: ObjectSpan) -> String? {
        guard let first = members(of: object).first?.member else { return nil }
        var start = first.keyStart
        while start > object.open, scalars[start - 1] != "\n" { start -= 1 }
        guard start > object.open else { return nil }
        let indent = string(start..<first.keyStart)
        guard !indent.isEmpty, indent.unicodeScalars.allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        // The top object's members sit one level in; inner objects are handled by the caller's level.
        return indent
    }

    func replacing(_ range: Range<Int>, with text: String) -> String {
        string(0..<range.lowerBound) + text + string(range.upperBound..<scalars.count)
    }

    /// Adds `"key": value` as the object's last member, at `level` (for pretty files).
    func inserting(member: (String, SetupJSON), into object: ObjectSpan, level: Int, unit: String,
                   compact: Bool) -> String {
        let key = SetupJSON.string(member.0).text
        let existing = members(of: object)
        if compact {
            let text = key + ":" + member.1.text
            if let last = existing.last?.member {
                return replacing(last.valueEnd..<last.valueEnd, with: "," + text)
            }
            return replacing((object.open + 1)..<object.close, with: text)
        }
        let indent = String(repeating: unit, count: level)
        let closing = String(repeating: unit, count: level - 1)
        let text = indent + key + ": " + member.1.pretty(unit: unit, level: level)
        if let last = existing.last?.member {
            return replacing(last.valueEnd..<last.valueEnd, with: ",\n" + text)
        }
        // An empty object: "{}" or "{ }" becomes a block.
        return replacing((object.open + 1)..<object.close, with: "\n" + text + "\n" + closing)
    }
}
