import Foundation
import Network

@main
struct CIMDFetcherTests {
    @MainActor static func main() {
        let urls = urlCases()
        let addresses = addressCases()
        let responses = responseCases()
        let documents = documentCases()
        let live = liveFixture()
        print("CIMD fetcher: \(urls) URL, \(addresses) address, \(responses) response (at every split) and "
            + "\(documents) document cases, \(live) live HTTPS fixture checks passed")
    }

    // MARK: - URL

    static func urlCases() -> Int {
        let valid = [
            "https://example.com/client.json", "https://example.com:8443/a/b?x=1", "https://localhost:1234/c",
            "https://claude.ai/oauth/claude-code-client-metadata", "https://xn--bcher-kva.example/c",
            "https://A-b.Example.co.uk/c", "https://example.com/a/..b/.c", "https://example.com/c/",
        ]
        let invalid = [
            "http://example.com/c", "ftp://example.com/c", "https://example.com", "https://example.com/",
            "https://example.com/c#frag", "https://example.com/c#", "https://user@example.com/c",
            "https://user:pw@example.com/c", "https://@example.com/c", "https://example.com/a/../c",
            "https://example.com/./c", "https://example.com/a/..", "https://example.com/a/%2e%2e/c",
            "https://example.com/a/%2E/c", "https://example.com/a/.%2e", "https://127.0.0.1/c",
            "https://127.0.0.1:443/c", "https://[::1]/c", "https://[2606:4700::1111]/c",
            "https://2130706433/c", "https://0x7f.1/c", "https://127.1/c", "https://example.com./c",
            "https://.example.com/c", "https://-a.example/c", "https://a-.example/c", "https://a..b/c",
            "https://exa_mple.com/c", "https:///c", "https:/c", "https:example.com/c",
            "https://example.com:0/c", "https://example.com%2f/c",
            "https://" + String(repeating: "a", count: 64) + ".example/c",
            "https://example.com/" + String(repeating: "a", count: 2048),
        ]
        for string in valid {
            precondition(CIMDFetcher.validateClientIDURL(URL(string: string)!), "should accept \(string)")
        }
        for string in invalid {
            let accepted = URL(string: string).map(CIMDFetcher.validateClientIDURL) ?? false
            precondition(!accepted, "should refuse \(string)")
        }
        return valid.count + invalid.count
    }

    // MARK: - Address classifier

    static func addressCases() -> Int {
        let open = [
            "8.8.8.8", "1.1.1.1", "11.0.0.1", "93.184.216.34", "100.63.255.255", "100.128.0.1",
            "126.255.255.255",
            "128.0.0.1", "169.253.255.255", "169.255.0.1", "172.15.255.255", "172.32.0.1", "192.0.1.1",
            "192.0.3.1", "192.88.98.1", "192.167.255.255", "192.169.0.1", "198.17.255.255", "198.20.0.1",
            "198.51.99.1", "203.0.112.1", "223.255.255.255",
            "2606:4700::1111", "2001:4860:4860::8888", "2a00:1450::1", "2001:200::1", "2003::1", "3ffe::1",
            "::ffff:8.8.8.8", "64:ff9b::8.8.8.8", "2001:db9::1",
        ]
        let blocked = [
            "0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.255", "127.0.0.1",
            "127.255.255.254", "169.254.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.0.0.1",
            "192.0.0.170", "192.0.2.1", "192.88.99.1", "192.168.0.1", "192.168.255.255", "198.18.0.1",
            "198.19.255.255", "198.51.100.1", "203.0.113.1", "224.0.0.1", "239.255.255.250", "240.0.0.1",
            "255.255.255.255",
            "::", "::1", "::127.0.0.1", "::8.8.8.8", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
            "::ffff:169.254.169.254",
            "::ffff:0.0.0.0", "::ffff:255.255.255.255", "64:ff9b::127.0.0.1", "64:ff9b::10.1.2.3",
            "64:ff9b:1::1", "100::1", "1::1", "2001::1", "2001:1ff::1", "2001:db8::1", "2002:7f00:1::1",
            "2002:808:808::1", "3fff::1", "3fff:fff::1", "4000::1", "5f00::1", "fc00::1", "fd12:3456::1",
            "fe80::1", "febf::1", "fec0::1", "ff02::1", "ff0e::1", "::ffff:0:7f00:1",
        ]
        func endpoint(_ string: String) -> NWEndpoint {
            if string.contains(":") { return .hostPort(host: .ipv6(IPv6Address(string)!), port: 443) }
            return .hostPort(host: .ipv4(IPv4Address(string)!), port: 443)
        }
        for string in open {
            precondition(CIMDFetcher.isPublicAddress(endpoint(string)), "should allow \(string)")
            precondition(!CIMDFetcher.isLoopbackAddress(endpoint(string)), "\(string) isn't loopback")
        }
        for string in blocked {
            precondition(!CIMDFetcher.isPublicAddress(endpoint(string)), "should block \(string)")
        }
        for string in ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"] {
            precondition(CIMDFetcher.isLoopbackAddress(endpoint(string)), "\(string) is loopback")
        }
        let link = NWEndpoint.hostPort(host: .ipv6(IPv6Address("fe80::1%lo0")!), port: 443)
        precondition(!CIMDFetcher.isPublicAddress(link))
        precondition(!CIMDFetcher.isPublicAddress(.hostPort(host: .name("example.com", nil), port: 443)))
        precondition(!CIMDFetcher.isPublicAddress(.unix(path: "/tmp/x")))
        precondition(!CIMDFetcher.isPublicAddress([8, 8, 8]) && !CIMDFetcher.isPublicAddress([]))
        precondition(CIMDFetcher.isPublicAddress([8, 8, 8, 8]))
        return open.count + blocked.count + 9
    }

    // MARK: - Response parser

    enum Expect {
        case body(String)
        case error(CIMDError)
        case malformed
        case notJSON
    }

    static func matches(_ result: Result<CIMDFetcher.Response, CIMDError>, _ expect: Expect) -> Bool {
        switch (result, expect) {
        case (.success(let response), .body(let body)):
            return response.status == 200 && response.body == Data(body.utf8)
        case (.failure(let error), .error(let expected)): return error == expected
        case (.failure(.network), .malformed): return true
        case (.failure(.invalidDocument), .notJSON): return true
        default: return false
        }
    }

    static func responseCases() -> Int {
        let ok = "HTTP/1.1 200 OK\r\n"
        let json = "\(ok)Content-Type: application/json\r\n"
        let chunked = "\(json)Transfer-Encoding: chunked\r\n\r\n"
        let big = String(repeating: "x", count: 65)
        let rows: [(String, Expect)] = [
            // Content-Length
            ("\(json)Content-Length: 2\r\n\r\n{}", .body("{}")),
            ("\(json)Content-Length: 02\r\n\r\n{}junk", .body("{}")),
            ("\(json)Content-Length: 0\r\n\r\n", .body("")),
            ("HTTP/1.0 200\r\ncontent-type: Application/JSON; charset=utf-8\r\ncontent-length:  2 \r\n\r\n{}",
             .body("{}")),
            ("\(ok)Content-Type: application/oauth-client+json\r\nContent-Length: 2\r\n\r\n{}", .body("{}")),
            ("\(json)Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}", .body("{}")),
            ("\(json)Content-Length: 64\r\n\r\n" + String(repeating: "y", count: 64),
             .body(String(repeating: "y", count: 64))),
            ("\(json)Content-Length: 5\r\n\r\n{}", .malformed),
            ("\(json)Content-Length: 65\r\n\r\n", .error(.tooLarge)),
            ("\(json)Content-Length: 99999999999999999999999\r\n\r\n", .error(.tooLarge)),
            ("\(json)Content-Length: abc\r\n\r\n{}", .malformed),
            ("\(json)Content-Length: -1\r\n\r\n{}", .malformed),
            ("\(json)Content-Length: 2, 2\r\n\r\n{}", .malformed),
            ("\(json)Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}x", .malformed),
            ("\(json)Content-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n{}", .malformed),
            // Chunked
            (chunked + "1\r\n{\r\n1;x=\"y\"\r\n}\r\n0\r\n\r\n", .body("{}")),
            (chunked + "A \r\n0123456789\r\n000\r\nX-Trailer: t\r\n\r\n", .body("0123456789")),
            (chunked + "0\r\n\r\n", .body("")),
            (chunked + "40\r\n" + String(repeating: "z", count: 64) + "\r\n0\r\n\r\n",
             .body(String(repeating: "z", count: 64))),
            (chunked + "41\r\n\(big)\r\n0\r\n\r\n", .error(.tooLarge)),
            (chunked + "40\r\n" + String(repeating: "z", count: 64) + "\r\n1\r\nz\r\n0\r\n\r\n",
             .error(.tooLarge)),
            (chunked + "FFFFFFFFF\r\n", .malformed),
            (chunked + "zz\r\nab\r\n0\r\n\r\n", .malformed),
            (chunked + "\r\n", .malformed),
            (chunked + "2\r\nabc\r\n0\r\n\r\n", .malformed),
            (chunked + "2\r\nab\r\n", .malformed),
            (chunked + "2\r\nab\r\n0\r\n", .malformed),
            ("\(json)Transfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n", .malformed),
            ("\(json)Transfer-Encoding: identity\r\n\r\n{}", .malformed),
            // Read to close
            ("\(json)\r\n{}", .body("{}")),
            ("\(json)\r\n" + String(repeating: "w", count: 64), .body(String(repeating: "w", count: 64))),
            ("\(json)\r\n\(big)", .error(.tooLarge)),
            // Status
            ("HTTP/1.1 301 Moved\r\nLocation: https://x/\r\n\r\n", .error(.redirected)),
            ("HTTP/1.1 302 Found\r\nLocation: /c\r\nContent-Type: application/json\r\n\r\n{}",
             .error(.redirected)),
            ("HTTP/1.1 307 Temporary Redirect\r\n\r\n", .error(.redirected)),
            ("HTTP/1.1 308 Permanent Redirect\r\n\r\n", .error(.redirected)),
            ("HTTP/1.1 300 Multiple Choices\r\n\r\n", .error(.redirected)),
            ("HTTP/1.1 304 Not Modified\r\n\r\n", .error(.redirected)),
            ("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n\r\n{}", .error(.httpStatus(404))),
            ("HTTP/1.1 500 Oops\r\n\r\n", .error(.httpStatus(500))),
            ("HTTP/1.1 204 No Content\r\n\r\n", .error(.httpStatus(204))),
            ("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n\r\n{}", .error(.httpStatus(201))),
            ("HTTP/1.1 103 Early Hints\r\n\r\n", .error(.httpStatus(103))),
            // Content type
            ("\(ok)Content-Type: text/html\r\nContent-Length: 2\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Length: 2\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Type: application/jsonp\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Type: text/json\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Type: application/+json\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Type: application/json-seq\r\n\r\n{}", .notJSON),
            ("\(ok)Content-Type: application/json\r\nContent-Type: text/html\r\n\r\n{}", .notJSON),
            ("\(json)Content-Encoding: gzip\r\n\r\n{}", .malformed),
            ("\(json)Content-Encoding: identity\r\n\r\n{}", .body("{}")),
            // Malformed heads
            ("", .malformed),
            ("HTTP/1.1 200 OK\r\n", .malformed),
            ("HTTP/1.1 200 OK\nContent-Type: application/json\n\n{}", .malformed),
            ("HTTP/2 200\r\n\r\n", .malformed),
            ("HTTP/1.1 20 OK\r\n\r\n", .malformed),
            ("HTTP/1.1 2000 OK\r\n\r\n", .malformed),
            ("HTTP/1.1 600 What\r\n\r\n", .malformed),
            ("http/1.1 200 OK\r\n\r\n", .malformed),
            ("\(json)X-Fold: a\r\n b\r\n\r\n{}", .malformed),
            ("\(json)No colon\r\n\r\n{}", .malformed),
            ("\(json): empty name\r\n\r\n{}", .malformed),
            ("\(json)Bad Name: x\r\n\r\n{}", .malformed),
            ("\(json)X: a\u{1}b\r\n\r\n{}", .malformed),
            ("\(ok)X: " + String(repeating: "h", count: 9000) + "\r\n\r\n", .error(.tooLarge)),
        ]
        for (raw, expect) in rows {
            let data = Data(raw.utf8)
            let final = CIMDFetcher.parseResponse(data, maxBody: 64)
            precondition(matches(final, expect), "\(raw.debugDescription): got \(final)")
            // Any prefix is either still incomplete or already the final answer.
            for split in stride(from: 0, to: data.count, by: data.count > 512 ? 97 : 1) {
                switch CIMDFetcher.parseResponseStep(data.prefix(split), maxBody: 64, atEOF: false) {
                case .incomplete: break
                case .done(let response):
                    precondition(matches(.success(response), expect), "\(raw.debugDescription) at \(split)")
                case .failed(let error):
                    precondition(matches(.failure(error), expect), "\(raw.debugDescription) at \(split)")
                }
            }
        }
        return rows.count
    }

    // MARK: - Document validator

    static let docID = "https://app.example/client.json"

    static func document(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    static func documentCases() -> Int {
        let base: [String: Any] = ["client_id": docID, "redirect_uris": ["https://app.example/cb"]]
        func with(_ changes: [String: Any?]) -> Data {
            var fields = base
            for (key, value) in changes { fields[key] = value }
            return document(fields)
        }

        let full = document([
            "client_id": docID, "client_name": " App ",
            "redirect_uris": ["https://app.example/cb", "http://127.0.0.1/cb", "com.example.app:/oauth"],
            "client_uri": "https://app.example", "logo_uri": "https://app.example/logo.png",
            "token_endpoint_auth_method": "none", "grant_types": ["authorization_code", "refresh_token"],
            "jwks": ["keys": [["kty": "EC", "x": "a", "y": "b"]]],
        ])
        let parsed = CIMDFetcher.parseDocument(full, expectedClientID: docID)
        precondition(parsed == .success(ClientMetadata(
            clientID: docID, clientName: "App",
            redirectURIs: ["https://app.example/cb", "http://127.0.0.1/cb", "com.example.app:/oauth"],
            clientURI: "https://app.example")), "\(parsed)")
        let minimal = CIMDFetcher.parseDocument(with([:]), expectedClientID: docID)
        precondition(minimal == .success(ClientMetadata(
            clientID: docID, clientName: nil, redirectURIs: ["https://app.example/cb"], clientURI: nil)))
        let blankName = CIMDFetcher.parseDocument(
            with(["client_name": "  ", "client_uri": "javascript:alert(1)"]), expectedClientID: docID)
        precondition(blankName == minimal, "\(blankName)")

        // A client that prefers another method but supports `none` is public to us. ChatGPT's
        // document as served in October 2026:
        let chatGPTID = "https://chatgpt.com/oauth/client.json"
        let chatGPT = CIMDFetcher.parseDocument(Data(#"""
            {"client_id":"https://chatgpt.com/oauth/client.json","client_uri":"https://chatgpt.com/",\#
            "redirect_uris":["https://chatgpt.com/connector_platform_oauth_redirect"],\#
            "token_endpoint_auth_method":"private_key_jwt",\#
            "token_endpoint_auth_methods_supported":["none","private_key_jwt"],\#
            "grant_types":["authorization_code","refresh_token"],"response_types":["code"],\#
            "client_name":"ChatGPT","logo_uri":"https://persistent.oaistatic.com/sonic/misc/openai-logo.png",\#
            "token_endpoint_auth_signing_alg":"RS256","jwks_uri":"https://chatgpt.com/oauth/jwks.json"}
            """#.utf8), expectedClientID: chatGPTID)
        precondition(chatGPT == .success(ClientMetadata(
            clientID: chatGPTID, clientName: "ChatGPT",
            redirectURIs: ["https://chatgpt.com/connector_platform_oauth_redirect"],
            clientURI: "https://chatgpt.com/")), "\(chatGPT)")
        for fields: [String: Any?] in [
            ["token_endpoint_auth_methods_supported": ["private_key_jwt", "none"]],
            ["token_endpoint_auth_method": "none", "token_endpoint_auth_methods_supported": ["private_key_jwt"]],
        ] {
            let parsed = CIMDFetcher.parseDocument(with(fields), expectedClientID: docID)
            precondition(parsed == minimal, "\(fields): \(parsed)")
        }

        let nfd = "https://app.example/cafe\u{301}"
        let bad: [(Data, String)] = [
            (Data("nope".utf8), "not JSON"), (Data("[]".utf8), "array"), (Data("\"x\"".utf8), "string"),
            (Data(), "empty"),
            (with(["client_id": "https://app.example/client.json/"]), "trailing slash"),
            (with(["client_id": "https://APP.example/client.json"]), "case"),
            (with(["client_id": "https://app.example:443/client.json"]), "explicit port"),
            (with(["client_id": nil]), "no client_id"), (with(["client_id": 5]), "numeric client_id"),
            (with(["redirect_uris": nil]), "no redirect_uris"), (with(["redirect_uris": []]), "empty list"),
            (with(["redirect_uris": "https://app.example/cb"]), "string redirect_uris"),
            (with(["redirect_uris": [1]]), "numeric URI"), (with(["redirect_uris": ["/cb"]]), "relative"),
            (with(["redirect_uris": ["javascript:alert(1)"]]), "javascript"),
            (with(["redirect_uris": ["data:text/html,x"]]), "data"),
            (with(["redirect_uris": ["https://app.example/cb#x"]]), "fragment"),
            (with(["redirect_uris": ["https:///cb"]]), "no host"),
            (with(["redirect_uris": Array(repeating: "https://app.example/cb", count: 21)]), "too many"),
            (with(["client_secret": "s"]), "secret"), (with(["client_secret": NSNull()]), "null secret"),
            (with(["client_secret_expires_at": 0]), "client_secret_expires_at"),
            (with(["token_endpoint_auth_method": "client_secret_basic"]), "basic"),
            (with(["token_endpoint_auth_method": "client_secret_post"]), "post"),
            (with(["token_endpoint_auth_method": "client_secret_jwt"]), "secret jwt"),
            (with(["token_endpoint_auth_method": "private_key_jwt"]), "private key jwt"),
            (with(["token_endpoint_auth_method": NSNull()]), "null method"),
            (with(["token_endpoint_auth_method": 1]), "numeric method"),
            (with(["token_endpoint_auth_method": "private_key_jwt",
                   "token_endpoint_auth_methods_supported": ["private_key_jwt"]]), "no none supported"),
            (with(["token_endpoint_auth_methods_supported": ["private_key_jwt"]]), "only jwt supported"),
            (with(["token_endpoint_auth_methods_supported": []]), "empty supported list"),
            (with(["token_endpoint_auth_methods_supported": "none"]), "string supported list"),
            (with(["token_endpoint_auth_method": "private_key_jwt",
                   "token_endpoint_auth_methods_supported": "none"]), "jwt with string supported list"),
            (with(["token_endpoint_auth_methods_supported": NSNull()]), "null supported list"),
            (with(["jwks": ["keys": [["kty": "EC", "d": "secret"]]]]), "private key"),
            (with(["client_name": 5]), "numeric name"), (with(["client_name": NSNull()]), "null name"),
            (with(["client_name": ["App"]]), "array name"),
            (with(["client_name": String(repeating: "n", count: 201)]), "long name"),
            (with(["client_uri": 5]), "numeric client_uri"), (with(["logo_uri": false]), "bool logo_uri"),
        ]
        for (body, label) in bad {
            let result = CIMDFetcher.parseDocument(body, expectedClientID: docID)
            guard case .failure(.invalidDocument) = result else { preconditionFailure("\(label): \(result)") }
        }
        // NFC and NFD spellings are different client IDs.
        let composed = CIMDFetcher.parseDocument(
            document(["client_id": nfd, "redirect_uris": ["https://a/cb"]]),
            expectedClientID: "https://app.example/caf\u{e9}")
        guard case .failure(.invalidDocument) = composed else { preconditionFailure("NFD matched NFC") }
        return bad.count + 7
    }

    // MARK: - Live fixture

    static let fixture = #"""
    import http.server, json, os, ssl, sys, threading, time
    cert, key, log = sys.argv[1:4]
    lock = threading.Lock()
    def note(line):
        with lock, open(log, 'a') as f:
            f.write(line + '\n')
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, *args):
            pass
        def handle(self):
            try:
                self.connection.do_handshake()
            except Exception:
                note('TLS failed')
                return
            note('TLS ok')
            super().handle()
        def reply(self, status, ctype, body, length=True, headers=()):
            self.send_response(status)
            if ctype:
                self.send_header('Content-Type', ctype)
            for k, v in headers:
                self.send_header(k, v)
            if length:
                self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True
            if not length:
                # The body ends where the connection does, so end it with TLS close_notify. An
                # abrupt close lets the client's TLS stack drop the last records unread (seen on
                # fast CI runners), which would test the race instead of the framing.
                self.wfile.flush()
                try:
                    self.connection.unwrap()
                except (OSError, ssl.SSLError):
                    pass
        def do_GET(self):
            note('GET ' + self.path)
            base = 'https://localhost:%d' % self.server.server_port
            def doc(path):
                return json.dumps({'client_id': base + path, 'client_name': 'Fixture',
                                   'redirect_uris': ['https://app.example/cb']}).encode()
            p = self.path
            if p in ('/client.json', '/untrusted.json', '/blocked.json'):
                self.reply(200, 'application/json', doc(p))
            elif p == '/chunked.json':
                body = doc(p)
                self.send_response(200)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Transfer-Encoding', 'chunked')
                self.end_headers()
                for i in range(0, len(body), 7):
                    self.wfile.write(b'%x\r\n%s\r\n' % (len(body[i:i + 7]), body[i:i + 7]))
                self.wfile.write(b'0\r\n\r\n')
                self.close_connection = True
            elif p == '/close.json':
                self.reply(200, 'application/oauth-client+json', doc(p), length=False)
            elif p == '/redirect.json':
                self.reply(302, 'application/json', b'{}', headers=[('Location', '/client.json')])
            elif p == '/big.json':
                self.reply(200, 'application/json', b' ' * 20000)
            elif p == '/big-close.json':
                self.reply(200, 'application/json', b' ' * 20000, length=False)
            elif p == '/slow.json':
                time.sleep(7)
                self.reply(200, 'application/json', doc(p))
            elif p == '/text.json':
                self.reply(200, 'text/html', doc(p))
            elif p == '/mismatch.json':
                self.reply(200, 'application/json', doc('/other.json'))
            else:
                self.reply(404, 'text/plain', b'no')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    # Exit with the test, even when it crashes before terminating this process.
    parent = os.getppid()
    def watch_parent():
        while os.getppid() == parent:
            time.sleep(0.5)
        os._exit(0)
    threading.Thread(target=watch_parent, daemon=True).start()
    print(server.server_port, flush=True)
    server.serve_forever()
    """#

    final class Clock {
        var now = Date()
    }

    final class Results {
        var calls = [String: [Result<ClientMetadata, CIMDError>]]()
    }

    @discardableResult
    static func run(_ command: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try! process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @MainActor static func spin(for seconds: TimeInterval, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    /// Fetches each path once (or as listed) concurrently and waits for every completion.
    @MainActor static func fetchAll(_ fetcher: CIMDFetcher, _ urls: [String], wait: TimeInterval = 10)
        -> (Results, TimeInterval) {
        let results = Results()
        let started = Date()
        for url in urls {
            fetcher.fetch(URL(string: url)!) { results.calls[url, default: []].append($0) }
        }
        let expected = urls.count
        spin(for: wait) { results.calls.values.map(\.count).reduce(0, +) == expected }
        let elapsed = Date().timeIntervalSince(started)
        spin(for: 0.2)
        for url in Set(urls) {
            precondition(results.calls[url]?.count == urls.filter { $0 == url }.count, "\(url) completions")
        }
        return (results, elapsed)
    }

    static func requests(_ log: URL, _ line: String) -> Int {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0 == line }.count
    }

    @MainActor static func liveFixture() -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cimd-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cert = directory.appendingPathComponent("cert.pem").path
        let key = directory.appendingPathComponent("key.pem").path
        let log = directory.appendingPathComponent("requests.log")
        let script = directory.appendingPathComponent("fixture.py")
        try! fixture.write(to: script, atomically: true, encoding: .utf8)
        let openssl = ["/opt/homebrew/bin/openssl", "/usr/bin/openssl"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }!
        let status = run(openssl, [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=localhost",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-addext", "extendedKeyUsage=serverAuth", "-addext", "basicConstraints=critical,CA:FALSE",
            "-addext", "keyUsage=critical,digitalSignature",
        ])
        precondition(status == 0, "openssl failed")

        let server = Process()
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = [script.path, cert, key, log.path]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try! server.run()
        defer { server.terminate() }
        var line = Data()
        while !line.contains(10) {
            let chunk = output.fileHandleForReading.availableData
            precondition(!chunk.isEmpty, "fixture didn't start")
            line += chunk
        }
        let port = Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!
        let base = "https://localhost:\(port)"
        var checks = 0

        setenv("EVENTKIT_MCP_TEST_CIMD_CA", cert, 1)
        setenv("EVENTKIT_MCP_TEST_CIMD_ALLOW_LOOPBACK", "1", 1)
        let clock = Clock()
        let fetcher = CIMDFetcher(now: { clock.now })
        let paths = ["/client.json", "/client.json", "/chunked.json", "/close.json", "/redirect.json",
                     "/big.json", "/big-close.json", "/slow.json", "/text.json", "/mismatch.json",
                     "/missing.json"]
        let (results, elapsed) = fetchAll(fetcher, paths.map { base + $0 })
        func result(_ path: String) -> Result<ClientMetadata, CIMDError> { results.calls[base + path]![0] }
        func fixtureDoc(_ path: String) -> Result<ClientMetadata, CIMDError> {
            .success(ClientMetadata(clientID: base + path, clientName: "Fixture",
                                    redirectURIs: ["https://app.example/cb"], clientURI: nil))
        }
        for path in ["/client.json", "/chunked.json", "/close.json"] {
            precondition(result(path) == fixtureDoc(path), "\(path): \(result(path))")
        }
        let twice = Array(repeating: fixtureDoc("/client.json"), count: 2)
        precondition(results.calls[base + "/client.json"]! == twice)
        precondition(result("/redirect.json") == .failure(.redirected))
        precondition(result("/big.json") == .failure(.tooLarge))
        precondition(result("/big-close.json") == .failure(.tooLarge))
        precondition(result("/slow.json") == .failure(.timedOut))
        precondition(result("/missing.json") == .failure(.httpStatus(404)))
        guard case .failure(.invalidDocument) = result("/text.json"),
              case .failure(.invalidDocument) = result("/mismatch.json") else {
            preconditionFailure("documents")
        }
        precondition(elapsed > 4.8 && elapsed < 6.5, "timeout took \(elapsed) s")
        // Two concurrent fetches made one request.
        precondition(requests(log, "GET /client.json") == 1)
        checks += paths.count + 2

        // Cached for an hour, then fetched again.
        _ = fetchAll(fetcher, [base + "/client.json"])
        precondition(requests(log, "GET /client.json") == 1, "cache miss")
        clock.now += 3599
        _ = fetchAll(fetcher, [base + "/client.json"])
        precondition(requests(log, "GET /client.json") == 1, "cache miss before an hour")
        clock.now += 2
        let (again, _) = fetchAll(fetcher, [base + "/client.json"])
        precondition(again.calls[base + "/client.json"]! == [fixtureDoc("/client.json")])
        precondition(requests(log, "GET /client.json") == 2, "cache didn't expire")
        checks += 3

        // Without the CA hook the self-signed certificate isn't trusted, so no request is made.
        unsetenv("EVENTKIT_MCP_TEST_CIMD_CA")
        let (untrusted, _) = fetchAll(CIMDFetcher(), [base + "/untrusted.json"])
        guard case .failure(.network) = untrusted.calls[base + "/untrusted.json"]![0] else {
            preconditionFailure("untrusted: \(untrusted.calls)")
        }
        precondition(requests(log, "GET /untrusted.json") == 0)
        checks += 1

        // Without the loopback hook, localhost is refused after resolving, before connecting at all;
        // an IP-literal host is refused before resolving.
        setenv("EVENTKIT_MCP_TEST_CIMD_CA", cert, 1)
        unsetenv("EVENTKIT_MCP_TEST_CIMD_ALLOW_LOOPBACK")
        let handshakes = requests(log, "TLS ok")
        let blockedURLs = [base + "/blocked.json", "https://127.0.0.1:\(port)/blocked.json",
                           "https://[::1]:\(port)/blocked.json"]
        let (blocked, blockedTime) = fetchAll(CIMDFetcher(), blockedURLs)
        precondition(blocked.calls[blockedURLs[0]]! == [.failure(.blockedAddress)], "\(blocked.calls)")
        precondition(blocked.calls[blockedURLs[1]]! == [.failure(.invalidURL)])
        precondition(blocked.calls[blockedURLs[2]]! == [.failure(.invalidURL)])
        precondition(blockedTime < 2, "blocked took \(blockedTime) s")
        spin(for: 0.3)
        precondition(requests(log, "GET /blocked.json") == 0, "a request reached a blocked address")
        precondition(requests(log, "TLS ok") == handshakes, "a blocked address was connected to")
        checks += 4

        // The check after connecting still holds when the first one is skipped (as if DNS changed
        // between resolving and connecting): TLS completes, but no request bytes go out.
        setenv("EVENTKIT_MCP_TEST_CIMD_SKIP_RESOLVE_CHECK", "1", 1)
        let (rebound, _) = fetchAll(CIMDFetcher(), [base + "/rebound.json"])
        unsetenv("EVENTKIT_MCP_TEST_CIMD_SKIP_RESOLVE_CHECK")
        precondition(rebound.calls[base + "/rebound.json"]! == [.failure(.blockedAddress)], "\(rebound.calls)")
        spin(for: 0.3)
        precondition(requests(log, "GET /rebound.json") == 0, "a request reached a blocked address")
        precondition(requests(log, "TLS ok") >= handshakes + 1, "the post-connect check didn't run")
        checks += 3
        unsetenv("EVENTKIT_MCP_TEST_CIMD_CA")
        return checks
    }
}
