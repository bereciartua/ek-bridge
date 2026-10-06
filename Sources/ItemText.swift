import Foundation

/// A field the core refuses, as an outcome code.
struct FieldError: Error, Equatable {
    let code: String
    init(_ code: String) { self.code = code }
}

/// Notes, location and URL rules shared by events and reminders (plan 03 §9).
/// Pure, so the core, the MCP mapping and the tests apply exactly the same
/// checks. Errors are core outcome codes.
enum ItemText {
    static let maxNotesBytes = 8_000
    static let maxLocationBytes = 500
    static let maxURLBytes = 2_048
    /// List reads show this much of the notes; `get_*` shows up to `maxReadNotesBytes`.
    static let notesPreviewBytes = 300
    static let maxReadNotesBytes = 16_000
    static let allowedURLSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    enum Change<Value: Equatable>: Equatable {
        case keep
        case clear
        case set(Value)

        var isKeep: Bool { if case .keep = self { return true } else { return false } }
        var value: Value? { if case .set(let value) = self { return value } else { return nil } }
    }

    /// NFC, CR LF → LF, and no control characters but tab and newline.
    /// Nil when the text has a NUL or another control character.
    static func normalized(_ text: String) -> String? {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .precomposedStringWithCanonicalMapping
        for scalar in unified.unicodeScalars {
            if scalar == "\t" || scalar == "\n" { continue }
            if scalar.properties.generalCategory == .control { return nil }
        }
        return unified
    }

    /// Notes keep their leading and trailing whitespace. Blank text means
    /// "clear", which only an update may ask for.
    static func notes(_ raw: Any?, present: Bool, creating: Bool) -> Result<Change<String>, FieldError> {
        guard present else { return .success(.keep) }
        if raw is NSNull { return creating ? .failure(FieldError("invalid_notes")) : .success(.clear) }
        guard let text = raw as? String, let value = normalized(text) else { return .failure(FieldError("invalid_notes")) }
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return creating ? .failure(FieldError("invalid_notes")) : .success(.clear)
        }
        guard value.utf8.count <= maxNotesBytes else { return .failure(FieldError("notes_too_long")) }
        return .success(.set(value))
    }

    /// Location text is trimmed and kept on one line.
    static func location(_ raw: Any?, present: Bool, creating: Bool) -> Result<Change<String>, FieldError> {
        guard present else { return .success(.keep) }
        if raw is NSNull { return creating ? .failure(FieldError("invalid_location")) : .success(.clear) }
        guard let text = raw as? String, let normal = normalized(text), !normal.contains("\n")
        else { return .failure(FieldError("invalid_location")) }
        let value = normal.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return creating ? .failure(FieldError("invalid_location")) : .success(.clear) }
        guard value.utf8.count <= maxLocationBytes else { return .failure(FieldError("location_too_long")) }
        return .success(.set(value))
    }

    static func url(_ raw: Any?, present: Bool, creating: Bool) -> Result<Change<String>, FieldError> {
        guard present else { return .success(.keep) }
        if raw is NSNull { return creating ? .failure(FieldError("invalid_url")) : .success(.clear) }
        guard let text = raw as? String else { return .failure(FieldError("invalid_url")) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return creating ? .failure(FieldError("invalid_url")) : .success(.clear)
        }
        if let problem = urlProblem(text) { return .failure(FieldError(problem)) }
        return .success(.set(text))
    }

    /// Nil for a URL the bridge may write: stored exactly as given, so it must
    /// already be valid (no percent-encoding added) and read back unchanged.
    static func urlProblem(_ text: String) -> String? {
        guard text.utf8.count <= maxURLBytes, normalized(text) == text,
              !text.contains(where: { $0.isWhitespace }),
              let components = URLComponents(string: text),
              let url = URL(string: text, encodingInvalidCharacters: false),
              url.absoluteString == text,
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty
        else { return "invalid_url" }
        guard allowedURLSchemes.contains(scheme) else { return "url_scheme_not_allowed" }
        switch scheme {
        case "mailto", "tel":
            guard !components.path.isEmpty else { return "invalid_url" }
        default:
            guard let host = components.host, !host.isEmpty else { return "invalid_url" }
        }
        return nil
    }

    static func schemeAllowed(_ url: String) -> Bool {
        guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
        return allowedURLSchemes.contains(scheme)
    }

    /// The first `maxBytes` of `text`, cut at a character boundary.
    static func prefix(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            result.append(character)
            used += size
        }
        return (result, true)
    }
}

/// A place with coordinates: an event's structured location, or the place a
/// location alarm watches.
struct PlaceSpec: Equatable {
    let title: String
    let latitude: Double
    let longitude: Double
    /// Meters; nil leaves EventKit's default.
    let radius: Double?

    /// Core shape: {"title", "latitude", "longitude", "radius"?}.
    static func parse(_ raw: Any?) -> PlaceSpec? {
        guard let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: ["title", "latitude", "longitude", "radius"]),
              let rawTitle = object["title"] as? String,
              let normal = ItemText.normalized(rawTitle), !normal.contains("\n"),
              let latitude = finite(object["latitude"]), (-90...90).contains(latitude),
              let longitude = finite(object["longitude"]), (-180...180).contains(longitude)
        else { return nil }
        let title = normal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= ItemText.maxLocationBytes else { return nil }
        var radius: Double?
        if let raw = object["radius"] {
            guard let value = finite(raw), (1...100_000).contains(value) else { return nil }
            radius = value
        }
        return PlaceSpec(title: title, latitude: latitude, longitude: longitude, radius: radius)
    }

    var core: [String: Any] {
        var result: [String: Any] = ["title": title, "latitude": latitude, "longitude": longitude]
        if let radius { result["radius"] = radius }
        return result
    }

    /// Coordinates within 1e-6°, radius within 1 m (§14). A requested radius
    /// of nil accepts whatever default the provider stored.
    func matches(_ saved: PlaceSpec) -> Bool {
        title == saved.title &&
            abs(latitude - saved.latitude) <= 1e-6 && abs(longitude - saved.longitude) <= 1e-6 &&
            (radius == nil || saved.radius.map { abs($0 - radius!) <= 1 } == true)
    }

    private static func finite(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

enum EventKitText {
    /// Empty text from EventKit reads as no value.
    static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
