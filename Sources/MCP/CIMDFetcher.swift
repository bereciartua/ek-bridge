import Foundation
import Network
import Security

/// Fetches OAuth Client ID Metadata Documents (§22.6, T22). It's the app's first outbound HTTP, so
/// it's bounded: https to a DNS name, no proxies, no redirects, 16 KB, 5 s. The name is resolved
/// first and refused if any address isn't public, so nothing (not even a TCP SYN) reaches a private
/// one; the connection then goes to that checked address, with TLS verified for the name. The
/// connected address is checked again before any request bytes go out.
@MainActor
final class CIMDFetcher: CIMDFetching {
    typealias Completion = (Result<ClientMetadata, CIMDError>) -> Void
    typealias Response = (status: Int, headers: [(String, String)], body: Data)

    nonisolated static let maxBody = 16 * 1024
    nonisolated static let maxHeaderBytes = 8 * 1024
    /// Caps raw bytes read, chunk framing included.
    nonisolated static let maxResponseBytes = maxHeaderBytes + 4 * maxBody
    nonisolated static let timeout: TimeInterval = 5
    static let cacheLifetime: TimeInterval = 3600
    static let maxCacheEntries = 64

    private let now: () -> Date
    private var cache = [String: (metadata: ClientMetadata, expires: Date)]()
    private var waiting = [String: [Completion]]()

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func fetch(_ url: URL, completion: @escaping Completion) {
        let key = url.absoluteString
        guard Self.validateClientIDURL(url), let request = CIMDRequest(url: url) else {
            return Self.deliver(.failure(.invalidURL), to: completion)
        }
        if let hit = cache[key] {
            if hit.expires > now() { return Self.deliver(.success(hit.metadata), to: completion) }
            cache[key] = nil
        }
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        request.start { result in self.finish(key, result) }
    }

    private func finish(_ key: String, _ result: Result<ClientMetadata, CIMDError>) {
        if case .success(let metadata) = result {
            let time = now()
            if cache.count >= Self.maxCacheEntries { cache = cache.filter { $0.value.expires > time } }
            if cache.count >= Self.maxCacheEntries { cache.removeAll() }
            cache[key] = (metadata, time.addingTimeInterval(Self.cacheLifetime))
        }
        for completion in waiting.removeValue(forKey: key) ?? [] { completion(result) }
    }

    /// Never synchronously, so callers see one behavior for cache hits and fetches.
    private static func deliver(_ result: Result<ClientMetadata, CIMDError>,
                                to completion: @escaping Completion) {
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
    }

    // MARK: - Client ID URL

    /// The draft's rules (https, a path, no userinfo, fragment or dot segments), plus ours: the host
    /// is a DNS name, never an IP literal, and the path is more than "/".
    nonisolated static func validateClientIDURL(_ url: URL) -> Bool {
        let string = url.absoluteString
        guard string.utf8.count <= 2048, !string.contains("#"),
              let parts = URLComponents(string: string), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.encodedHost, isDNSName(host) else { return false }
        if let port = parts.port, !(1...65_535).contains(port) { return false }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains {
            let segment = $0.lowercased().replacingOccurrences(of: "%2e", with: ".")
            return segment == "." || segment == ".."
        }
    }

    /// LDH labels, and a last label starting with a letter, which rules out every IPv4 spelling
    /// (`127.1`, `0x7f.1`, `2130706433`).
    nonisolated static func isDNSName(_ host: String) -> Bool {
        let labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, let last = labels.last, last.first?.isLetter == true else {
            return false
        }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-"
                && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    // MARK: - Address classifier

    nonisolated static func isPublicAddress(_ endpoint: NWEndpoint) -> Bool {
        addressBytes(endpoint).map(isPublicAddress) ?? false
    }

    nonisolated static func isLoopbackAddress(_ endpoint: NWEndpoint) -> Bool {
        guard let bytes = addressBytes(endpoint) else { return false }
        if bytes.count == 4 { return bytes[0] == 127 }
        if let v4 = embeddedIPv4(bytes) { return v4[0] == 127 }
        return bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    nonisolated static func addressBytes(_ endpoint: NWEndpoint) -> [UInt8]? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): return [UInt8](address.rawValue)
        case .ipv6(let address): return [UInt8](address.rawValue)
        default: return nil
        }
    }

    /// 4 or 16 bytes. IPv4 is public unless in a special-purpose range; IPv6 must be global
    /// unicast (2000::/3) outside the special ranges, or a mapped or NAT64 public IPv4 address.
    nonisolated static func isPublicAddress(_ bytes: [UInt8]) -> Bool {
        if bytes.count == 4 { return isPublicIPv4(bytes) }
        guard bytes.count == 16 else { return false }
        if let v4 = embeddedIPv4(bytes) { return isPublicIPv4(v4) }
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        let blocked: [([UInt8], Int)] = [
            ([0x20, 0x01, 0x00], 23),        // IETF protocol assignments, Teredo, ORCHID, benchmarking
            ([0x20, 0x01, 0x0D, 0xB8], 32),  // documentation
            ([0x20, 0x02], 16),              // 6to4
            ([0x3F, 0xFF], 20),              // documentation (RFC 9637)
        ]
        return !blocked.contains { inPrefix(bytes, $0.0, $0.1) }
    }

    nonisolated private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        let blocked: [([UInt8], Int)] = [
            ([0], 8), ([10], 8), ([100, 64], 10), ([127], 8), ([169, 254], 16), ([172, 16], 12),
            ([192, 0, 0], 24), ([192, 0, 2], 24), ([192, 88, 99], 24), ([192, 168], 16),
            ([198, 18], 15), ([198, 51, 100], 24), ([203, 0, 113], 24),
            ([224], 4), ([240], 4),  // multicast; reserved and broadcast
        ]
        return !blocked.contains { inPrefix(b, $0.0, $0.1) }
    }

    /// The IPv4 address inside `::ffff:a.b.c.d` (mapped) or `64:ff9b::a.b.c.d` (NAT64).
    nonisolated private static func embeddedIPv4(_ b: [UInt8]) -> [UInt8]? {
        let mapped = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF]
        let nat64: [UInt8] = [0, 0x64, 0xFF, 0x9B] + [UInt8](repeating: 0, count: 8)
        return Array(b[0..<12]) == mapped || Array(b[0..<12]) == nat64 ? Array(b[12...]) : nil
    }

    nonisolated private static func inPrefix(_ bytes: [UInt8], _ prefix: [UInt8], _ bits: Int) -> Bool {
        for bit in 0..<bits {
            let index = bit / 8, mask = UInt8(0x80) >> (bit % 8)
            if bytes[index] & mask != (index < prefix.count ? prefix[index] : 0) & mask { return false }
        }
        return true
    }

    // MARK: - HTTP response

    enum ResponseStep {
        case incomplete
        case done(Response)
        case failed(CIMDError)
    }

    /// Parses a whole response read to the end of the connection.
    nonisolated static func parseResponse(_ data: Data, maxBody: Int) -> Result<Response, CIMDError> {
        switch parseResponseStep(data, maxBody: maxBody, atEOF: true) {
        case .done(let response): return .success(response)
        case .failed(let error): return .failure(error)
        case .incomplete: return .failure(.network("truncated response"))
        }
    }

    /// Fails as early as the bytes allow: a 3xx, a non-200, a non-JSON type or an oversize
    /// Content-Length fails as soon as the head has arrived. At EOF it never returns `.incomplete`.
    nonisolated static func parseResponseStep(_ data: Data, maxBody: Int, atEOF: Bool) -> ResponseStep {
        let bytes = [UInt8](data)
        let malformed = ResponseStep.failed(.network("malformed response"))
        let truncated = ResponseStep.failed(.network("truncated response"))
        guard let headEnd = find([13, 10, 13, 10], in: bytes, from: 0, limit: maxHeaderBytes) else {
            if bytes.count >= maxHeaderBytes { return .failed(.tooLarge) }
            return atEOF ? truncated : .incomplete
        }
        guard let head = String(bytes: bytes[..<headEnd], encoding: .isoLatin1) else { return malformed }
        let whitespace = CharacterSet(charactersIn: " \t")
        let lines = head.components(separatedBy: "\r\n")
        guard let status = statusCode(lines[0]) else { return malformed }
        var headers = [(String, String)]()
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return malformed }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: whitespace)
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(isTokenChar),
                  value.unicodeScalars.allSatisfy({ $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F) })
            else { return malformed }
            headers.append((name, value))
        }
        func values(_ name: String) -> [String] {
            headers.filter { $0.0.caseInsensitiveCompare(name) == .orderedSame }.map { $0.1.lowercased() }
        }

        if (300...399).contains(status) { return .failed(.redirected) }
        guard status == 200 else { return .failed(.httpStatus(status)) }
        let types = values("Content-Type")
        guard types.count == 1, isJSONType(types[0]) else {
            return .failed(.invalidDocument("content type isn't JSON"))
        }
        guard values("Content-Encoding").allSatisfy({ $0 == "identity" }) else { return malformed }

        let encodings = values("Transfer-Encoding"), lengths = Set(values("Content-Length"))
        let start = headEnd + 4
        if !encodings.isEmpty {
            guard encodings == ["chunked"], lengths.isEmpty else { return malformed }
            return dechunk(bytes, from: start, maxBody: maxBody, atEOF: atEOF).map { (status, headers, $0) }
        }
        if let length = lengths.first {
            guard lengths.count == 1, !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) })
            else { return malformed }
            guard length.count <= 9, let count = Int(length), count <= maxBody else {
                return .failed(.tooLarge)
            }
            guard bytes.count - start >= count else { return atEOF ? truncated : .incomplete }
            return .done((status, headers, Data(bytes[start..<start + count])))
        }
        if bytes.count - start > maxBody { return .failed(.tooLarge) }
        return atEOF ? .done((status, headers, Data(bytes[start...]))) : .incomplete
    }

    private enum BodyStep {
        case incomplete
        case done(Data)
        case failed(CIMDError)

        func map(_ transform: (Data) -> Response) -> ResponseStep {
            switch self {
            case .incomplete: return .incomplete
            case .done(let body): return .done(transform(body))
            case .failed(let error): return .failed(error)
            }
        }
    }

    nonisolated private static func dechunk(_ bytes: [UInt8], from start: Int, maxBody: Int,
                                            atEOF: Bool) -> BodyStep {
        let malformed = BodyStep.failed(.network("malformed response"))
        let short = atEOF ? BodyStep.failed(.network("truncated response")) : .incomplete
        var body = [UInt8](), position = start
        while true {
            guard let end = find([13, 10], in: bytes, from: position, limit: 256) else {
                return bytes.count - position >= 256 ? malformed : short
            }
            let line = String(decoding: bytes[position..<end], as: UTF8.self)
            let digits = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard (1...8).contains(digits.count), digits.allSatisfy(\.isHexDigit),
                  let size = Int(digits, radix: 16) else { return malformed }
            position = end + 2
            if size == 0 { break }
            guard body.count + size <= maxBody else { return .failed(.tooLarge) }
            guard bytes.count >= position + size + 2 else { return short }
            guard bytes[position + size] == 13, bytes[position + size + 1] == 10 else { return malformed }
            body += bytes[position..<position + size]
            position += size + 2
        }
        // Trailers are ignored, up to the blank line that ends them.
        while true {
            guard let end = find([13, 10], in: bytes, from: position, limit: 1024) else {
                return bytes.count - position >= 1024 ? malformed : short
            }
            if end == position { return .done(Data(body)) }
            position = end + 2
        }
    }

    /// The index of `needle` starting within `limit` bytes of `from`.
    nonisolated private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int,
                                         limit: Int) -> Int? {
        let last = min(bytes.count - needle.count, from + limit - needle.count)
        guard from <= last else { return nil }
        return (from...last).first { bytes[$0..<$0 + needle.count].elementsEqual(needle) }
    }

    nonisolated private static func statusCode(_ line: String) -> Int? {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0", parts[1].count == 3,
              parts[1].allSatisfy(\.isASCII), let code = Int(parts[1]), (100...599).contains(code)
        else { return nil }
        return code
    }

    nonisolated private static func isTokenChar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
            || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar))
    }

    /// `application/json` or any `application/…+json`, parameters ignored. `values` lowercases.
    nonisolated static func isJSONType(_ value: String) -> Bool {
        let type = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased()
        return type == "application/json" || (type.hasPrefix("application/") && type.hasSuffix("+json")
            && type.count > "application/+json".count)
    }

    // MARK: - Document

    /// Validates per the CIMD draft. We only support public clients, so the client must allow `none`:
    /// as its `token_endpoint_auth_method`, in `token_endpoint_auth_methods_supported`, or by giving
    /// neither. ChatGPT's document prefers `private_key_jwt` but lists `none` as supported, and picks
    /// a method our metadata advertises (`["none"]`).
    nonisolated static func parseDocument(_ body: Data,
                                          expectedClientID: String) -> Result<ClientMetadata, CIMDError> {
        func invalid(_ why: String) -> Result<ClientMetadata, CIMDError> { .failure(.invalidDocument(why)) }
        guard let doc = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return invalid("not a JSON object")
        }
        // Simple string comparison, per the draft: Swift's == would equate NFC and NFD spellings.
        guard let clientID = doc["client_id"] as? String,
              clientID.utf8.elementsEqual(expectedClientID.utf8) else {
            return invalid("client_id doesn't match the URL")
        }
        for key in ["client_secret", "client_secret_expires_at"] where doc[key] != nil {
            return invalid("\(key) isn't allowed")
        }
        let method = doc["token_endpoint_auth_method"], methods = doc["token_endpoint_auth_methods_supported"]
        let allowsNone = (method as? String) == "none"
            || (methods as? [Any])?.contains(where: { ($0 as? String) == "none" }) == true
        if (method != nil || methods != nil) && !allowsNone {
            return invalid("only public clients are supported")
        }
        if let keys = (doc["jwks"] as? [String: Any])?["keys"] as? [[String: Any]],
           keys.contains(where: { $0["d"] != nil }) {
            return invalid("private key material isn't allowed")
        }
        guard let list = doc["redirect_uris"] as? [Any], (1...20).contains(list.count) else {
            return invalid("redirect_uris must be a non-empty array")
        }
        var redirects = [String]()
        for item in list {
            guard let uri = item as? String, isRedirectURI(uri) else {
                return invalid("invalid redirect URI")
            }
            redirects.append(uri)
        }
        for key in ["client_name", "client_uri", "logo_uri"] where doc[key] != nil && !(doc[key] is String) {
            return invalid("\(key) must be a string")
        }
        let name = (doc["client_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (name?.count ?? 0) <= 200 else { return invalid("client_name is too long") }
        // A cosmetic link: dropped rather than failing the client if it isn't a web page.
        let clientURI = (doc["client_uri"] as? String).flatMap { uri in
            URLComponents(string: uri).flatMap { ["https", "http"].contains($0.scheme?.lowercased())
                && $0.host?.isEmpty == false && uri.utf8.count <= 2048 ? uri : nil }
        }
        return .success(ClientMetadata(clientID: clientID, clientName: name?.isEmpty == false ? name : nil,
                                       redirectURIs: redirects, clientURI: clientURI))
    }

    /// Absolute, no fragment, and not a scheme that runs in the browser page that redirects.
    nonisolated private static func isRedirectURI(_ uri: String) -> Bool {
        guard uri.utf8.count <= 2048, !uri.contains("#"), let parts = URLComponents(string: uri),
              let scheme = parts.scheme?.lowercased(), parts.fragment == nil else { return false }
        if ["javascript", "data", "vbscript", "file", "blob", "about"].contains(scheme) { return false }
        return !["https", "http"].contains(scheme) || parts.host?.isEmpty == false
    }
}

#if EVENTKIT_MCP_TEST
/// Test-only: let the local HTTPS fixture through. Normal builds have no way to relax the guard.
private enum CIMDTestHooks {
    static var allowLoopback: Bool {
        getenv("EVENTKIT_MCP_TEST_CIMD_ALLOW_LOOPBACK").map { String(cString: $0) } == "1"
    }

    /// Skips the check before connecting, so tests can reach the one after it.
    static var skipResolveCheck: Bool {
        getenv("EVENTKIT_MCP_TEST_CIMD_SKIP_RESOLVE_CHECK").map { String(cString: $0) } == "1"
    }

    static var anchor: SecCertificate? {
        guard let path = getenv("EVENTKIT_MCP_TEST_CIMD_CA").map({ String(cString: $0) }),
              let pem = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let base64 = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        return Data(base64Encoded: base64).flatMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
}
#endif

/// One fetch, confined to its own queue; its result is delivered once, on the main actor.
private final class CIMDRequest: @unchecked Sendable {
    private let clientID: String
    private let host: String
    private let port: NWEndpoint.Port
    private let request: Data
    private let queue = DispatchQueue(label: "CIMDFetcher.request")
    private var connection: NWConnection?
    private var received = Data()
    private var sent = false
    private var untried = [NWEndpoint.Host]()
    private var onDone: (@MainActor (Result<ClientMetadata, CIMDError>) -> Void)?
    #if EVENTKIT_MCP_TEST
    private let allowLoopback = CIMDTestHooks.allowLoopback
    private let anchor = CIMDTestHooks.anchor
    private let skipResolveCheck = CIMDTestHooks.skipResolveCheck
    #endif

    init?(url: URL) {
        guard let parts = URLComponents(string: url.absoluteString), let host = parts.encodedHost,
              let number = UInt16(exactly: parts.port ?? 443), let port = NWEndpoint.Port(rawValue: number)
        else { return nil }
        let target = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        let authority = host + (parts.port.map { ":\($0)" } ?? "")
        // The version is "–" when unbundled; header values stay ASCII.
        let version = AppIdentity.version
        let agent = version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }
            ? version : "0"
        let head = "GET \(target) HTTP/1.1\r\nHost: \(authority)\r\nAccept: application/json\r\n"
            + "Accept-Encoding: identity\r\nUser-Agent: EventKitBridge/\(agent)\r\n"
            + "Connection: close\r\n\r\n"
        self.clientID = url.absoluteString
        self.host = host
        self.port = port
        self.request = Data(head.utf8)
    }

    func start(_ done: @escaping @MainActor (Result<ClientMetadata, CIMDError>) -> Void) {
        queue.async { [self] in
            onDone = done
            queue.asyncAfter(deadline: .now() + CIMDFetcher.timeout) { [self] in finish(.failure(.timedOut)) }
            // getaddrinfo blocks, so it runs off this queue and the timeout still fires.
            DispatchQueue.global(qos: .utility).async { [self] in
                let addresses = resolve()
                queue.async { [self] in connect(addresses) }
            }
        }
    }

    private func connect(_ addresses: [NWEndpoint.Host]?) {
        guard onDone != nil else { return }
        guard let addresses, let first = addresses.first else {
            return finish(.failure(.network("The name didn't resolve.")))
        }
        var checked = addresses.allSatisfy { allowed(.hostPort(host: $0, port: port)) }
        #if EVENTKIT_MCP_TEST
        if skipResolveCheck { checked = true }
        #endif
        guard checked else { return finish(.failure(.blockedAddress)) }
        // Each checked address in turn (an IPv6 address without a route falls back to IPv4), with a
        // shorter connect timeout when there's more than one, all within the overall 5 s.
        untried = Array(addresses.dropFirst().prefix(3))
        attempt(first, timeout: untried.isEmpty ? Int(CIMDFetcher.timeout) : 2)
    }

    private func attempt(_ address: NWEndpoint.Host, timeout: Int) {
        let connection = NWConnection(host: address, port: port, using: parameters(timeout: timeout))
        self.connection = connection
        connection.stateUpdateHandler = { [self] state in changed(state) }
        connection.start(queue: queue)
    }

    /// Every address the name resolves to, or nil if it doesn't resolve.
    private func resolve() -> [NWEndpoint.Host]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        var hosts = [NWEndpoint.Host]()
        var cursor: UnsafeMutablePointer<addrinfo>? = list
        while let info = cursor {
            if let address = info.pointee.ai_addr {
                switch Int32(info.pointee.ai_family) {
                case AF_INET:
                    var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if let ipv4 = IPv4Address(Data(bytes: &raw, count: MemoryLayout<in_addr>.size)) {
                        hosts.append(.ipv4(ipv4))
                    }
                case AF_INET6:
                    var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if let ipv6 = IPv6Address(Data(bytes: &raw, count: MemoryLayout<in6_addr>.size)) {
                        hosts.append(.ipv6(ipv6))
                    }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        return hosts
    }

    private func parameters(timeout: Int) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        // The connection goes to an address, so the name for SNI and certificate checks is set here.
        sec_protocol_options_set_tls_server_name(security, host)
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(security, "http/1.1")
        #if EVENTKIT_MCP_TEST
        if let anchor {
            let host = host
            sec_protocol_options_set_verify_block(security, { _, trust, complete in
                let trust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                complete(SecTrustEvaluateWithError(trust, nil))
            }, queue)
        }
        #endif
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = timeout
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // A proxy would make the checked address the proxy's, not the server's.
        parameters.preferNoProxies = true
        return parameters
    }

    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard let remote = connection?.currentPath?.remoteEndpoint, allowed(remote) else {
                return finish(.failure(.blockedAddress))
            }
            connection?.send(content: request, completion: .contentProcessed { [self] error in
                if let error { finish(.failure(.network("\(error)"))) }
            })
            sent = true
            receive()
        // Once sent, the reads report failures: a server closing without close_notify fails the
        // connection, possibly before the last bytes are read.
        case .waiting(let error) where !sent, .failed(let error) where !sent:
            guard !untried.isEmpty else { return finish(.failure(.network("\(error)"))) }
            connection?.stateUpdateHandler = nil
            connection?.forceCancel()
            attempt(untried.removeFirst(), timeout: 2)
        default:
            break
        }
    }

    private func allowed(_ remote: NWEndpoint) -> Bool {
        #if EVENTKIT_MCP_TEST
        if allowLoopback && CIMDFetcher.isLoopbackAddress(remote) { return true }
        #endif
        return CIMDFetcher.isPublicAddress(remote)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [self] data, _, isComplete, error in
            guard onDone != nil else { return }
            if let data { received.append(data) }
            guard received.count <= CIMDFetcher.maxResponseBytes else { return finish(.failure(.tooLarge)) }
            let atEOF = isComplete || error != nil
            switch CIMDFetcher.parseResponseStep(received, maxBody: CIMDFetcher.maxBody, atEOF: atEOF) {
            case .incomplete: receive()
            case .failed(let failure): finish(.failure(failure))
            case .done(let response):
                finish(CIMDFetcher.parseDocument(response.body, expectedClientID: clientID))
            }
        }
    }

    private func finish(_ result: Result<ClientMetadata, CIMDError>) {
        guard let done = onDone else { return }
        onDone = nil
        connection?.stateUpdateHandler = nil
        // Not a graceful close: nothing more, not even a close_notify, goes to a blocked address.
        connection?.forceCancel()
        connection = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
    }
}
