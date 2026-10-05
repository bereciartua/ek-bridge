import Darwin
import Foundation
import Network

@main
struct MCPGateTests {
    static let port = 47615
    static let token = "ekb_mcp_v1_" + String(repeating: "0123456789abcdef", count: 4)

    static func main() {
        let gates = gateTable()
        unauthorizedResponse()
        let parses = jsonRPC()
        MainActor.assumeIsolated { headerValuesAndAgents() }
        listener()
        print("MCP gate: \(gates) endpoint checks in §7.4 order, A.4 401, \(parses) JSON-RPC parses, "
              + "Mcp-Name base64, agent names, loopback-only listener, port probe passed")
    }

    // MARK: Requests

    static func parse(_ text: String) -> HTTPRequest {
        var parser = HTTPParser()
        guard case .request(let request) = parser.feed(Data(text.utf8)) else {
            preconditionFailure("didn't parse: \(text)")
        }
        return request
    }

    /// A request with the good defaults; nil removes a header, a value replaces it.
    static func request(method: String = "POST", target: String = "/mcp",
                        _ overrides: [String: String?] = [:]) -> HTTPRequest {
        var headers: [(String, String?)] = [
            ("Host", "127.0.0.1:\(port)"),
            ("Content-Type", "application/json"),
            ("Accept", "application/json, text/event-stream"),
            ("Authorization", "Bearer \(token)"),
        ]
        for (name, value) in overrides {
            if let index = headers.firstIndex(where: { $0.0.lowercased() == name.lowercased() }) {
                headers[index].1 = value
            } else {
                headers.append((name, value))
            }
        }
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#
        var text = "\(method) \(target) HTTP/1.1\r\n"
        for (name, value) in headers { if let value { text += "\(name): \(value)\r\n" } }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        return parse(text)
    }

    enum Expect: Equatable {
        case proceed(String)
        case unauthenticated
        case status(Int, close: Bool)
    }

    static func verdict(_ request: HTTPRequest, origins: Set<String> = []) -> (Expect, HTTPResponse?) {
        switch MCPHTTPGate.check(request, port: port, allowedOrigins: origins) {
        case .proceed(let token): return (.proceed(token), nil)
        case .unauthenticated: return (.unauthenticated, nil)
        case .respond(let response, let close): return (.status(response.status, close: close), response)
        }
    }

    // MARK: §7.4, in order

    static func gateTable() -> Int {
        let ok = Expect.proceed(token)
        let table: [(String, HTTPRequest, Expect)] = [
            ("good request", request(), ok),
            ("query ignored", request(target: "/mcp?session=1"), ok),
            // 1. Path, before everything else.
            ("wrong path", request(target: "/"), .status(404, close: false)),
            ("trailing slash", request(target: "/mcp/"), .status(404, close: false)),
            ("case matters", request(target: "/MCP"), .status(404, close: false)),
            ("well-known", request(method: "GET", target: "/.well-known/oauth-protected-resource"),
             .status(404, close: false)),
            ("bad path beats bad host", request(target: "/x", ["Host": "evil.example"]), .status(404, close: false)),
            // 2. Host.
            ("localhost", request(["Host": "localhost:\(port)"]), ok),
            ("Host case", request(["Host": "LocalHost:\(port)"]), ok),
            ("no port", request(["Host": "127.0.0.1"]), .status(421, close: true)),
            ("other port", request(["Host": "127.0.0.1:\(port + 1)"]), .status(421, close: true)),
            ("rebinding", request(["Host": "evil.example:\(port)"]), .status(421, close: true)),
            ("ipv6", request(["Host": "[::1]:\(port)"]), .status(421, close: true)),
            ("bad host beats GET", request(method: "GET", ["Host": "evil.example"]), .status(421, close: true)),
            ("bad host beats origin", request(["Host": "evil.example", "Origin": "https://evil.example"]),
             .status(421, close: true)),
            ("bad host beats no token", request(["Host": "evil.example", "Authorization": nil]),
             .status(421, close: true)),
            // 3. Origin.
            ("web page", request(["Origin": "https://evil.example"]), .status(403, close: false)),
            ("null origin", request(["Origin": "null"]), .status(403, close: false)),
            ("origin beats GET", request(method: "GET", ["Origin": "https://evil.example"]),
             .status(403, close: false)),
            // 4. Forwarded headers.
            ("tailscale", request(["Tailscale-Funnel-Request": "?1"]), .status(403, close: false)),
            ("cloudflare ip", request(["CF-Connecting-IP": "203.0.113.9"]), .status(403, close: false)),
            ("cloudflare ray", request(["cf-ray": "1"]), .status(403, close: false)),
            ("x-forwarded-host", request(["X-Forwarded-Host": "example.com"]), .status(403, close: false)),
            ("forwarded beats DELETE", request(method: "DELETE", ["CF-Ray": "1"]), .status(403, close: false)),
            // 5. Method.
            ("GET", request(method: "GET"), .status(405, close: false)),
            ("DELETE", request(method: "DELETE"), .status(405, close: false)),
            ("OPTIONS", request(method: "OPTIONS"), .status(405, close: false)),
            ("PUT", request(method: "PUT"), .status(405, close: false)),
            ("lowercase post", request(method: "post"), .status(405, close: false)),
            ("method beats content type", request(method: "GET", ["Content-Type": "text/plain"]),
             .status(405, close: false)),
            // 6. Content-Type.
            ("text/plain", request(["Content-Type": "text/plain"]), .status(415, close: false)),
            ("no content type", request(["Content-Type": nil]), .status(415, close: false)),
            ("json-ish", request(["Content-Type": "application/json-seq"]), .status(415, close: false)),
            ("charset", request(["Content-Type": "application/json; charset=utf-8"]), ok),
            ("case", request(["Content-Type": "Application/JSON"]), ok),
            ("content type beats accept", request(["Content-Type": "text/plain", "Accept": "text/html"]),
             .status(415, close: false)),
            // 7. Accept.
            ("SSE only", request(["Accept": "text/event-stream"]), .status(406, close: false)),
            ("html", request(["Accept": "text/html"]), .status(406, close: false)),
            ("no accept", request(["Accept": nil]), ok),
            ("wildcard", request(["Accept": "*/*"]), ok),
            ("application wildcard", request(["Accept": "application/*"]), ok),
            ("q values", request(["Accept": "text/html;q=0.9, Application/JSON;q=0.1"]), ok),
            ("accept beats auth", request(["Accept": "text/html", "Authorization": nil]),
             .status(406, close: false)),
            // 8. Authorization.
            ("no token", request(["Authorization": nil]), .unauthenticated),
            ("basic", request(["Authorization": "Basic dXNlcjpwYXNz"]), .unauthenticated),
            ("lowercase bearer", request(["Authorization": "bearer \(token)"]), ok),
            ("uppercase bearer", request(["Authorization": "BEARER \(token)"]), ok),
            ("extra space", request(["Authorization": "Bearer  \(token)"]), ok),
            ("bearer alone", request(["Authorization": "Bearer"]), .unauthenticated),
            ("junk token", request(["Authorization": "Bearer x"]), .unauthenticated),
            ("uppercase hex", request(["Authorization": "Bearer ekb_mcp_v1_" + String(token.dropFirst(11)).uppercased()]),
             .unauthenticated),
            ("short", request(["Authorization": "Bearer \(token.dropLast())"]), .unauthenticated),
            ("long", request(["Authorization": "Bearer \(token)0"]), .unauthenticated),
            ("wrong prefix", request(["Authorization": "Bearer ekb_mcp_v2_" + token.dropFirst(11)]),
             .unauthenticated),
            ("CLI key", request(["Authorization": "Bearer ekb_v1_" + String(repeating: "a", count: 64)]),
             .unauthenticated),
            ("token without scheme", request(["Authorization": token]), .unauthenticated),
        ]
        for (name, request, expected) in table {
            let (actual, _) = verdict(request)
            precondition(actual == expected, "\(name): expected \(expected), got \(actual)")
        }
        // An allowed Origin passes.
        precondition(verdict(request(["Origin": "https://allowed.example"]),
                             origins: ["https://allowed.example"]).0 == ok)
        precondition(verdict(request(["Origin": "https://ALLOWED.example"]),
                             origins: ["https://allowed.example"]).0 == .status(403, close: false))

        // Response details.
        let notFound = verdict(request(target: "/")).1!
        precondition(String(decoding: notFound.body, as: UTF8.self) == "Not found. The MCP endpoint is /mcp.\n")
        precondition(header(notFound, "Content-Type") == "text/plain; charset=utf-8")
        let misdirected = verdict(request(["Host": "evil.example"])).1!
        precondition(misdirected.body.isEmpty)
        let web = verdict(request(["Origin": "https://evil.example"])).1!
        let webBody = object(web.body)
        precondition(webBody["id"] == nil, "the Origin refusal has no id member")
        precondition(NSDictionary(dictionary: webBody).isEqual(to: [
            "jsonrpc": "2.0", "error": ["code": -32600, "message": "Requests from web pages aren't accepted."]]))
        precondition(header(web, "Content-Type") == "application/json")
        let tunnel = object(verdict(request(["X-Forwarded-Host": "x"])).1!.body)
        precondition(tunnel["id"] == nil)
        precondition((tunnel["error"] as! [String: Any])["message"] as? String ==
            "This port is only for agents on this Mac. Point your tunnel at the Remote Access port in EventKit Bridge.")
        let method = verdict(request(method: "GET")).1!
        precondition(header(method, "Allow") == "POST" && method.body.isEmpty)
        precondition(verdict(request(["Content-Type": "text/plain"])).1!.body.isEmpty)
        precondition(verdict(request(["Accept": "text/html"])).1!.body.isEmpty)
        // Throttled callers get 429 with Retry-After.
        let locked = MCPHTTPGate.lockedOut(retryAfter: 37)
        precondition(locked.status == 429 && header(locked, "Retry-After") == "37")
        return table.count + 2
    }

    static func header(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    static func object(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: Appendix A.4

    static func unauthorizedResponse() {
        let response = MCPHTTPGate.unauthorized()
        precondition(response.status == 401)
        precondition(header(response, "WWW-Authenticate") == #"Bearer realm="EventKit Bridge""#)
        precondition(header(response, "Content-Type") == "application/json")
        precondition(response.headers.count == 2)
        precondition(!response.headers.contains { $0.value.contains("resource_metadata") })
        let expected = #"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"EventKit Bridge doesn't recognize this agent's token. Copy the setup again from the client's page in EventKit Bridge."}}"#
        precondition(NSDictionary(dictionary: object(response.body))
                     .isEqual(to: object(Data(expected.utf8))), "A.4 body")
        precondition((object(response.body)["id"] as? NSNull) != nil, "id is null, not missing")
        let wire = String(decoding: response.serialized(close: false), as: UTF8.self)
        let head = wire.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\r\n")
        precondition(head[0] == "HTTP/1.1 401 Unauthorized")
        let lines = Set(head.dropFirst())
        for line in [#"WWW-Authenticate: Bearer realm="EventKit Bridge""#, "Content-Type: application/json",
                     "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
                     "Content-Length: \(response.body.count)"] {
            precondition(lines.contains(line), "missing \(line)")
        }
        precondition(!lines.contains { $0.lowercased().hasPrefix("access-control-") })
        precondition(lines.count == 5)
    }

    // MARK: JSON-RPC

    static func jsonRPC() -> Int {
        enum Parsed: Equatable {
            case request(JSONRPCID, String, Int)
            case notification(String)
            case response
            case failure(JSONRPCParseError)
        }
        func parsed(_ text: String) -> Parsed {
            switch JSONRPC.parse(Data(text.utf8)) {
            case .success(.request(let id, let method, let params)): return .request(id, method, params.count)
            case .success(.notification(let method, _)): return .notification(method)
            case .success(.response): return .response
            case .failure(let error): return .failure(error)
            }
        }
        let table: [(String, Parsed)] = [
            (#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#, .request(.int(1), "tools/list", 0)),
            (#"{"jsonrpc":"2.0","id":"abc","method":"ping","params":{"a":1}}"#, .request(.string("abc"), "ping", 1)),
            (#"{"jsonrpc":"2.0","id":"","method":"ping"}"#, .request(.string(""), "ping", 0)),
            (#"{"jsonrpc":"2.0","id":-7,"method":"ping"}"#, .request(.int(-7), "ping", 0)),
            (#"{"jsonrpc":"2.0","id":3.0,"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#, .failure(.invalidRequest)),
            // A float-typed id can't be echoed with its type (§8.5).
            (#"{"jsonrpc":"2.0","id":1.0,"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":1e3,"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, .notification("notifications/initialized")),
            (#"{"jsonrpc":"2.0","id":4,"result":{}}"#, .response),
            (#"{"jsonrpc":"2.0","id":4,"error":{"code":-1,"message":"x"}}"#, .response),
            (#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#, .failure(.invalidRequest)),
            ("[]", .failure(.invalidRequest)),
            ("\"ping\"", .failure(.invalidRequest)),
            ("{", .failure(.parse)),
            ("", .failure(.parse)),
            (#"{"jsonrpc":"2.0","id":5,"method":"ping","params":[1]}"#, .failure(.invalidRequestWithID(.int(5)))),
            (#"{"jsonrpc":"2.0","id":"s","method":"ping","params":"x"}"#, .failure(.invalidRequestWithID(.string("s")))),
            (#"{"jsonrpc":"2.0","method":"ping","params":[1]}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"1.0","id":6,"method":"ping"}"#, .failure(.invalidRequestWithID(.int(6)))),
            (#"{"id":6,"method":"ping"}"#, .failure(.invalidRequestWithID(.int(6)))),
            (#"{"jsonrpc":2.0,"id":6,"method":"ping"}"#, .failure(.invalidRequestWithID(.int(6)))),
            (#"{"jsonrpc":"1.0","method":"ping"}"#, .failure(.invalidRequest)),
            (#"{"jsonrpc":"2.0","id":7}"#, .failure(.invalidRequestWithID(.int(7)))),
            (#"{"jsonrpc":"2.0","id":8,"method":""}"#, .failure(.invalidRequestWithID(.int(8)))),
            (#"{"jsonrpc":"2.0","id":9,"method":5}"#, .failure(.invalidRequestWithID(.int(9)))),
        ]
        for (text, expected) in table {
            let actual = parsed(text)
            precondition(actual == expected, "\(text): expected \(expected), got \(actual)")
        }
        // Errors echo the id with its type; the Origin refusal omits it.
        precondition(String(decoding: JSONRPC.error(id: .string("7"), code: -32600, message: "m"), as: UTF8.self)
                     == #"{"error":{"code":-32600,"message":"m"},"id":"7","jsonrpc":"2.0"}"#)
        precondition(String(decoding: JSONRPC.error(id: nil, code: -32600, message: "m"), as: UTF8.self)
                     == #"{"error":{"code":-32600,"message":"m"},"id":null,"jsonrpc":"2.0"}"#)
        precondition(String(decoding: JSONRPC.error(id: nil, code: -32600, message: "m", omitID: true),
                            as: UTF8.self) == #"{"error":{"code":-32600,"message":"m"},"jsonrpc":"2.0"}"#)
        precondition(String(decoding: JSONRPC.result(id: .int(7), [:]), as: UTF8.self)
                     == #"{"id":7,"jsonrpc":"2.0","result":{}}"#)
        precondition(JSONRPCID.int(1).key != JSONRPCID.string("1").key)
        // Ids up to 2^53 round-trip exactly.
        precondition(parsed(#"{"jsonrpc":"2.0","id":9007199254740992,"method":"ping"}"#)
                     == .request(.int(9_007_199_254_740_992), "ping", 0))
        // Larger integers too: the response echoes the id exactly (§8.5).
        precondition(parsed(#"{"jsonrpc":"2.0","id":9007199254740993,"method":"ping"}"#)
                     == .request(.int(9_007_199_254_740_993), "ping", 0))
        precondition(parsed(#"{"jsonrpc":"2.0","id":9223372036854775807,"method":"ping"}"#)
                     == .request(.int(Int.max), "ping", 0))
        let echoed = String(decoding: JSONRPC.result(id: .int(9_007_199_254_740_993), [:]), as: UTF8.self)
        precondition(echoed.contains(#""id":9007199254740993"#), echoed)
        return table.count
    }

    // MARK: Mcp-Name and clientInfo

    @MainActor
    static func headerValuesAndAgents() {
        precondition(MCPServer.decodeHeaderValue("Claude Code") == "Claude Code")
        precondition(MCPServer.decodeHeaderValue("=?base64?Q2xhdWRlIENvZGU=?=") == "Claude Code")
        let unicode = Data("Zoë’s agent ✓".utf8).base64EncodedString()
        precondition(MCPServer.decodeHeaderValue("=?base64?\(unicode)?=") == "Zoë’s agent ✓")
        precondition(MCPServer.decodeHeaderValue("=?base64?!!!?=") == nil, "invalid base64")
        precondition(MCPServer.decodeHeaderValue("=?base64?/w==?=") == nil, "not UTF-8")
        precondition(MCPServer.decodeHeaderValue("=?base64??=") == "")
        precondition(MCPServer.decodeHeaderValue("=?base64?Q2xhdWRl") == "=?base64?Q2xhdWRl",
                     "an unterminated form is taken literally")

        precondition(MCPServer.agentName(["name": "Claude Code", "version": "2.4.1"]) == "Claude Code 2.4.1")
        precondition(MCPServer.agentName(["name": "codex"]) == "codex")
        precondition(MCPServer.agentName(["name": "codex", "version": 2]) == "codex")
        precondition(MCPServer.agentName(["version": "1.0"]) == nil)
        precondition(MCPServer.agentName(["name": 7, "version": "1.0"]) == nil)
        precondition(MCPServer.agentName(["name": "Evil\u{1b}[2J\nAgent", "version": "\t1.0 "]) == "Evil [2J Agent 1.0")
        precondition(MCPServer.agentName(["name": "  ", "version": ""]) == nil)
        let long = MCPServer.agentName(["name": String(repeating: "n", count: 60), "version": "10.20.30"])!
        precondition(long == String(repeating: "n", count: 60) + " 10.", "cut at 64 bytes")
        precondition(ClientRegistry.validAgent(long))
    }

    // MARK: Listener parameters and the port probe

    static func listener() {
        let parameters = LoopbackHTTPServer.parameters(port: port)
        guard case .hostPort(let host, let boundPort) = parameters.requiredLocalEndpoint else {
            preconditionFailure("the listener must pin a local host and port")
        }
        if case .ipv4(let address) = host {
            precondition(address == IPv4Address.loopback, "\(address)")
        } else {
            preconditionFailure("expected an IPv4 literal, got \(host)")
        }
        precondition("\(host)" == "127.0.0.1" && LoopbackHTTPServer.host == "127.0.0.1")
        precondition(boundPort.rawValue == UInt16(port))
        precondition(parameters.acceptLocalOnly)
        precondition(parameters.allowLocalEndpointReuse)
        for other in [1024, 65535] {
            guard case .hostPort(let otherHost, let otherPort) =
                    LoopbackHTTPServer.parameters(port: other).requiredLocalEndpoint else {
                preconditionFailure("port \(other)")
            }
            precondition("\(otherHost)" == "127.0.0.1" && otherPort.rawValue == UInt16(other))
        }

        // A port this test holds is busy; once closed, it's free.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0 && listen(fd, 1) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        precondition(named == 0)
        let held = Int(UInt16(bigEndian: address.sin_port))
        precondition(held > 0)
        precondition(!PortProbe.isFree(held), "a listening port is busy")
        close(fd)
        precondition(PortProbe.isFree(held), "free after closing")
    }
}
