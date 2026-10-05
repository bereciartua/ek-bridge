import Foundation

/// MCP-PLAN §7.3. Chunk-size lines and trailers get their own small caps, so a chunked request never
/// holds more than `maxBodyBytes` plus a few KiB of framing.
struct HTTPLimits {
    var maxHeaderBytes = 16 * 1024
    var maxHeaderFields = 64
    var maxBodyBytes = 64 * 1024
    var maxChunkLineBytes = 1024
    var maxTrailerBytes = 4 * 1024
    static let standard = HTTPLimits()
}

struct HTTPRequest {
    let method: String
    let target: String
    let path: String
    let version: String
    /// Names lowercased, values trimmed, in arrival order.
    let headers: [(name: String, value: String)]
    let body: Data

    func header(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.name == name }?.value
    }

    func headerValues(_ name: String) -> [String] {
        let name = name.lowercased()
        return headers.filter { $0.name == name }.map(\.value)
    }

    /// Comma-separated list members across every field with this name, lowercased.
    func headerTokens(_ name: String) -> [String] { listTokens(headerValues(name)) }

    /// HTTP/1.0 keep-alive is never honored: one request per 1.0 connection keeps the server simple.
    var wantsClose: Bool { version == "HTTP/1.0" || headerTokens("connection").contains("close") }
}

enum HTTPParseResult {
    case needMore
    case expectContinue
    case request(HTTPRequest)
    case error(status: Int)
}

/// Strict incremental HTTP/1.1 request parser. Every line must end in CRLF. Anything malformed is a
/// 400, including an unknown version (not 505) and any transfer-coding other than plain `chunked`
/// (not 501). An oversize head, too many fields or oversize trailers are 431; an oversize body is
/// 413. Decisions are made only at line and body boundaries, so results never depend on how the
/// bytes were split across reads.
struct HTTPParser {
    let limits: HTTPLimits
    private var buffer: [UInt8] = []
    private var start = 0        // first unconsumed byte
    private var scan = 0         // the search for LF resumes here
    private var state = State.head
    private var head = Head()
    private var body: [UInt8] = []
    private var trailerBytes = 0
    private var continueOffered = false

    private enum State {
        case head, fixedBody(Int), chunkSize, chunkData(Int), chunkEnd, trailers, failed(Int)
    }

    private struct Head {
        var bytes = 0
        var method = "", target = "", version = ""
        var hasRequestLine = false
        var expectsContinue = false
        var fields: [(name: String, value: String)] = []
    }

    private struct Failure: Error {
        let status: Int
        init(_ status: Int) { self.status = status }
    }

    init(limits: HTTPLimits = .standard) { self.limits = limits }

    /// True while part of a request is buffered (header timeout rather than idle timeout).
    var hasBufferedBytes: Bool {
        switch state {
        case .failed: return false
        case .head: return head.bytes > 0 || buffer.count > start
        default: return true
        }
    }

    var isReadingBody: Bool {
        switch state {
        case .head, .failed: return false
        default: return true
        }
    }

    /// Unconsumed bytes plus the body so far. Whenever `feed` returns `.needMore` this is at most
    /// `maxBodyBytes + max(maxHeaderBytes, maxTrailerBytes)`, provided the caller drains pipelined
    /// requests (empty feeds) before reading more from the socket.
    var bufferedByteCount: Int { buffer.count - start + body.count }

    /// Appends bytes and returns the next result. After `.expectContinue` (once per request) the
    /// caller writes `HTTPResponse.continueBytes` and keeps feeding. `.error` is final.
    mutating func feed(_ bytes: Data) -> HTTPParseResult {
        if case .failed(let status) = state { return .error(status: status) }
        buffer.append(contentsOf: bytes)
        do {
            let result = try advance()
            if start > 0 {
                buffer.removeSubrange(0..<start)
                scan -= start
                start = 0
            }
            return result
        } catch {
            state = .failed(error.status)
            buffer = []
            body = []
            head = Head()
            start = 0
            scan = 0
            return .error(status: error.status)
        }
    }

    private mutating func advance() throws(Failure) -> HTTPParseResult {
        while true {
            switch state {
            case .failed(let status):
                return .error(status: status)
            case .head:
                guard let line = try nextLine(cap: limits.maxHeaderBytes - head.bytes, tooLong: 431) else {
                    return .needMore
                }
                head.bytes += line.count + 2
                if let request = try headLine(line) { return .request(request) }
            case .fixedBody(let length):
                guard buffer.count - start >= length else { return offerContinue() }
                body.append(contentsOf: buffer[start..<start + length])
                start += length
                return .request(finish())
            case .chunkSize:
                guard let line = try nextLine(cap: limits.maxChunkLineBytes, tooLong: 400) else {
                    return offerContinue()
                }
                let size = try chunkSize(line)
                state = size == 0 ? .trailers : .chunkData(size)
            case .chunkData(let remaining):
                let take = min(remaining, buffer.count - start)
                body.append(contentsOf: buffer[start..<start + take])
                start += take
                guard take == remaining else {
                    state = .chunkData(remaining - take)
                    return offerContinue()
                }
                state = .chunkEnd
            case .chunkEnd:
                guard buffer.count - start >= 2 else { return offerContinue() }
                guard buffer[start] == cr, buffer[start + 1] == lf else { throw Failure(400) }
                start += 2
                state = .chunkSize
            case .trailers:
                guard let line = try nextLine(cap: limits.maxTrailerBytes - trailerBytes, tooLong: 431) else {
                    return offerContinue()
                }
                trailerBytes += line.count + 2
                if line.isEmpty { return .request(finish()) }
                _ = try field(line)
            }
        }
    }

    /// The next line without its CRLF, or nil until a whole one is buffered. `cap` includes the CRLF.
    private mutating func nextLine(cap: Int, tooLong: Int) throws(Failure) -> [UInt8]? {
        scan = max(scan, start)
        guard let end = buffer[scan...].firstIndex(of: lf) else {
            scan = buffer.count
            // Any completion of this partial line would exceed the cap already.
            if buffer.count - start >= cap { throw Failure(tooLong) }
            return nil
        }
        if end + 1 - start > cap { throw Failure(tooLong) }
        guard end > start, buffer[end - 1] == cr else { throw Failure(400) }
        let line = Array(buffer[start..<end - 1])
        if line.contains(cr) { throw Failure(400) }
        start = end + 1
        scan = start
        return line
    }

    private mutating func headLine(_ line: [UInt8]) throws(Failure) -> HTTPRequest? {
        guard head.hasRequestLine else {
            // RFC 9112 §2.2: empty lines before the request line are ignored (they still count).
            if !line.isEmpty { try requestLine(line) }
            return nil
        }
        if line.isEmpty { return try endHead() }
        let field = try field(line)
        guard head.fields.count < limits.maxHeaderFields else { throw Failure(431) }
        if Self.singletons.contains(field.name), head.fields.contains(where: { $0.name == field.name }) {
            throw Failure(400)
        }
        head.fields.append(field)
        return nil
    }

    private static let singletons: Set<String> = ["content-length", "host", "authorization"]

    private mutating func requestLine(_ line: [UInt8]) throws(Failure) {
        let parts = line.split(separator: sp, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[0].allSatisfy(isTokenByte),
              !parts[1].isEmpty, parts[1].allSatisfy({ $0 > 0x20 && $0 < 0x7F }) else { throw Failure(400) }
        let version = ascii(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw Failure(400) }
        head.method = ascii(parts[0])
        head.target = ascii(parts[1])
        head.version = version
        head.hasRequestLine = true
    }

    /// A header or trailer field. A leading SP/HTAB (obs-fold), a missing colon or whitespace before
    /// it all fail the token check on the name.
    private func field(_ line: [UInt8]) throws(Failure) -> (name: String, value: String) {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")), colon > 0,
              line[..<colon].allSatisfy(isTokenByte) else { throw Failure(400) }
        var value = line[(colon + 1)...]
        while let first = value.first, first == sp || first == tab { value.removeFirst() }
        while let last = value.last, last == sp || last == tab { value.removeLast() }
        guard value.allSatisfy(isFieldValueByte) else { throw Failure(400) }
        return (ascii(line[..<colon]).lowercased(), latin1(value))
    }

    private mutating func endHead() throws(Failure) -> HTTPRequest? {
        let fields = head.fields
        let values = { (name: String) in fields.filter { $0.name == name }.map(\.value) }
        let lengths = values("content-length")
        let codings = values("transfer-encoding")
        if head.version == "HTTP/1.1" && values("host").isEmpty { throw Failure(400) }
        head.expectsContinue = head.version == "HTTP/1.1"
            && values("expect").contains { $0.lowercased() == "100-continue" }
        if !codings.isEmpty {
            // Chunked framing is undefined in 1.0, and a request with both framings is a smuggling risk.
            guard lengths.isEmpty, head.version == "HTTP/1.1", listTokens(codings) == ["chunked"] else {
                throw Failure(400)
            }
            state = .chunkSize
            return nil
        }
        guard let text = lengths.first else { return finish() }
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { throw Failure(400) }
        let digits = text.drop { $0 == "0" }
        guard digits.count <= 9, let length = Int(digits.isEmpty ? "0" : digits),
              length <= limits.maxBodyBytes else { throw Failure(413) }
        if length == 0 { return finish() }
        state = .fixedBody(length)
        return nil
    }

    private func chunkSize(_ line: [UInt8]) throws(Failure) -> Int {
        let digits = line.prefix { hexValue($0) != nil }
        var rest = line[digits.endIndex...]
        while let first = rest.first, first == sp || first == tab { rest.removeFirst() }
        // Chunk extensions are ignored, but they still have to be printable.
        guard !digits.isEmpty, rest.isEmpty || rest.first == UInt8(ascii: ";"),
              rest.allSatisfy(isFieldValueByte) else { throw Failure(400) }
        let significant = digits.drop { $0 == UInt8(ascii: "0") }
        guard significant.count <= 8 else { throw Failure(413) }
        let size = significant.reduce(0) { $0 * 16 + hexValue($1)! }
        guard body.count + size <= limits.maxBodyBytes else { throw Failure(413) }
        return size
    }

    private mutating func offerContinue() -> HTTPParseResult {
        guard head.expectsContinue, !continueOffered else { return .needMore }
        continueOffered = true
        return .expectContinue
    }

    private mutating func finish() -> HTTPRequest {
        let request = HTTPRequest(method: head.method, target: head.target,
                                  path: String(head.target.prefix { $0 != "?" }),
                                  version: head.version, headers: head.fields, body: Data(body))
        head = Head()
        body = []
        trailerBytes = 0
        continueOffered = false
        state = .head
        return request
    }
}

struct HTTPResponse {
    var status: Int
    var headers: [(name: String, value: String)] = []
    var body = Data()

    static let continueBytes = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    /// Always `Content-Length`, never chunked, never CORS (§7.3). Framing and `Connection` are ours
    /// alone, and a caller field that would break the framing is dropped rather than written.
    func serialized(close: Bool) -> Data {
        var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var names: Set<String> = []
        for (name, value) in headers {
            let lower = name.lowercased()
            guard !Self.reserved.contains(lower), !lower.hasPrefix("access-control-"), !name.isEmpty,
                  name.utf8.allSatisfy(isTokenByte), value.utf8.allSatisfy(isFieldValueByte) else { continue }
            text += "\(name): \(value)\r\n"
            names.insert(lower)
        }
        text += "Content-Length: \(body.count)\r\n"
        if !names.contains("cache-control") { text += "Cache-Control: no-store\r\n" }
        if !names.contains("x-content-type-options") { text += "X-Content-Type-Options: nosniff\r\n" }
        if close { text += "Connection: close\r\n" }
        var data = Data((text + "\r\n").utf8)
        data.append(body)
        return data
    }

    private static let reserved: Set<String> = ["content-length", "transfer-encoding", "connection"]

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 408: return "Request Timeout"
        case 413: return "Content Too Large"
        case 415: return "Unsupported Media Type"
        case 421: return "Misdirected Request"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}

private let cr: UInt8 = 13
private let lf: UInt8 = 10
private let sp: UInt8 = 32
private let tab: UInt8 = 9

private func isTokenByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
         UInt8(ascii: "0")...UInt8(ascii: "9"):
        return true
    default:
        return "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
}

/// HTAB, visible ASCII, SP and obs-text; every other control byte (NUL, CR, LF, DEL …) is refused.
private func isFieldValueByte(_ byte: UInt8) -> Bool { byte == tab || (byte >= 0x20 && byte != 0x7F) }

private func hexValue(_ byte: UInt8) -> Int? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(byte - UInt8(ascii: "a")) + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(byte - UInt8(ascii: "A")) + 10
    default: return nil
    }
}

private func ascii<S: Collection<UInt8>>(_ bytes: S) -> String { String(decoding: bytes, as: UTF8.self) }

/// Header bytes are Latin-1 (RFC 9110 §5.5), which maps every byte losslessly.
private func latin1<S: Sequence<UInt8>>(_ bytes: S) -> String {
    String(String.UnicodeScalarView(bytes.map { Unicode.Scalar($0) }))
}

private func listTokens(_ values: [String]) -> [String] {
    values.flatMap { $0.split(separator: ",") }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased() }
        .filter { !$0.isEmpty }
}
