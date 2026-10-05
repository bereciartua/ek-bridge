import Foundation

@main
struct HTTPMessageTests {
    static let small = HTTPLimits(maxHeaderBytes: 64, maxHeaderFields: 3, maxBodyBytes: 8,
                                  maxChunkLineBytes: 16, maxTrailerBytes: 24)

    static func main() {
        let cases = table() + limitCases()
        expectContinue()
        flags()
        response()
        fuzz()
        print("HTTP message: \(cases) table cases at every split, 100-continue, flags, responses "
            + "and 10,000 fuzz cases passed")
    }

    static func table() -> Int {
        let h = "Host: a\r\n"
        let post = "POST /mcp HTTP/1.1\r\n\(h)"
        let chunked = "\(post)Transfer-Encoding: chunked\r\n\r\n"
        let ok = ["POST /mcp body="]
        let bad = ["error 400"]
        let rows: [(String, [String])] = [
            ("", []),
            ("GET /mcp HTTP/1.1\r\n\(h)\r\n", ["GET /mcp body="]),
            ("\(post)Content-Length: 5\r\n\r\nhello", ["POST /mcp body=hello"]),
            ("\(post)Content-Length:005  \r\n\r\nhello", ["POST /mcp body=hello"]),
            ("\(post)Content-Length: 0000000000000000001\r\n\r\nx", ["POST /mcp body=x"]),
            ("POST /mcp?x=1&y=%20 HTTP/1.1\r\n\(h)Content-Length: 0\r\n\r\n", ok),
            ("\r\n\(post)\r\n", ok),
            ("get /mcp HTTP/1.1\r\n\(h)\r\n", ["get /mcp body="]),
            ("OPTIONS * HTTP/1.1\r\n\(h)\r\n", ["OPTIONS * body="]),
            ("X-Y.Z~ /a/b HTTP/1.1\r\n\(h)\r\n", ["X-Y.Z~ /a/b body="]),
            // Chunked: extensions, upper-case hex, leading zeros and ignored trailers.
            (chunked + "5\r\nhello\r\n6;ext=1;q=\"a b\"\r\n world\r\n0\r\nX-Trailer: t\r\nY: \r\n\r\n",
             ["POST /mcp body=hello world"]),
            (chunked + "A \t;x\r\n0123456789\r\n000\r\n\r\n", ["POST /mcp body=0123456789"]),
            ("\(post)Transfer-Encoding: Chunked\r\n\r\n00000000000003\r\nabc\r\n0\r\n\r\n",
             ["POST /mcp body=abc"]),
            (chunked + "0\r\nContent-Length: 99\r\n\r\n", ok),
            (chunked + "g\r\n", bad),
            (chunked + "\r\n", bad),
            (chunked + "-5\r\n", bad),
            (chunked + "0x5\r\n", bad),
            (chunked + "5 x\r\n", bad),
            (chunked + "5;a\u{0}\r\n", bad),
            (chunked + "5\nhello\r\n0\r\n\r\n", bad),
            (chunked + "5\r\nhelloX\r\n0\r\n\r\n", bad),
            (chunked + "5\r\nhello\n0\r\n\r\n", bad),
            (chunked + "0\r\n folded: x\r\n\r\n", bad),
            (chunked + "0\r\nno colon\r\n\r\n", bad),
            (chunked + "10001\r\n", ["error 413"]),
            (chunked + "FFFFFFFFF\r\n", ["error 413"]),
            (chunked + "5;" + String(repeating: "e", count: 1100) + "\r\n", bad),
            (chunked + "0\r\nX: " + String(repeating: "t", count: 4100) + "\r\n\r\n", ["error 431"]),
            // Framing headers.
            ("\(post)Transfer-Encoding: gzip, chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: identity\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: chunked, chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n", bad),
            ("\(post)Transfer-Encoding:\r\n\r\n", bad),
            ("\(post)Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello", bad),
            ("\(post)Transfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 5\r\nContent-Length: 5\r\n\r\nhello", bad),
            ("\(post)content-length: 5\r\nCONTENT-LENGTH: 6\r\n\r\nhello!", bad),
            ("\(post)Host: a\r\n\r\n", bad),
            ("\(post)Authorization: Bearer a\r\nauthorization: Bearer a\r\n\r\n", bad),
            ("\(post)Content-Length: abc\r\n\r\n", bad),
            ("\(post)Content-Length: -1\r\n\r\n", bad),
            ("\(post)Content-Length: +5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 5,5\r\n\r\nhello", bad),
            ("\(post)Content-Length: 1 2\r\n\r\n", bad),
            ("\(post)Content-Length: \r\n\r\n", bad),
            ("\(post)Content-Length: 65537\r\n\r\n", ["error 413"]),
            ("\(post)Content-Length: 99999999999999999999\r\n\r\n", ["error 413"]),
            // Field syntax.
            ("\(post)X: a\u{0}b\r\n\r\n", bad),
            ("\(post)X: a\rb\r\n\r\n", bad),
            ("\(post)X: a\u{1}b\r\n\r\n", bad),
            ("\(post)X: a\u{7F}\r\n\r\n", bad),
            ("\(post)X: a\r\n\r\n", ok),
            ("\(post)X: a\n\r\n", bad),
            ("\(post)X: a\r\n b\r\n\r\n", bad),
            ("POST /mcp HTTP/1.1\r\n Host: a\r\n\r\n", bad),
            ("\(post)No colon\r\n\r\n", bad),
            ("\(post)X : a\r\n\r\n", bad),
            ("\(post)X\t: a\r\n\r\n", bad),
            ("\(post)X Y: a\r\n\r\n", bad),
            ("\(post): a\r\n\r\n", bad),
            ("\(post)Hōst: a\r\n\r\n", bad),
            ("\(post)X(: a\r\n\r\n", bad),
            // Request line.
            ("GET /mcp HTTP/1.1\n\(h)\r\n", bad),
            ("GET /mcp\rx HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/2.0\r\n\(h)\r\n", bad),
            ("GET /mcp http/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp\r\n\(h)\r\n", bad),
            ("GET  /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/1.1 \r\n\(h)\r\n", bad),
            (" GET /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("G(T /mcp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /m\u{7F}cp HTTP/1.1\r\n\(h)\r\n", bad),
            ("GET /mcp HTTP/1.1\r\n\r\n", bad),
            // Connection handling.
            ("GET /mcp HTTP/1.0\r\n\r\n", ["GET /mcp body= close"]),
            ("POST /mcp HTTP/1.0\r\nContent-Length: 2\r\n\r\nhi", ["POST /mcp body=hi close"]),
            ("POST /mcp HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", bad),
            ("\(post)Connection: keep-alive, Close\r\n\r\n", ["POST /mcp body= close"]),
            ("\(post)Connection: keep-alive\r\nConnection: close\r\n\r\n", ["POST /mcp body= close"]),
            ("\(post)Connection: keep-alive\r\n\r\n", ok),
            // Pipelining and partial input.
            ("\(post)Content-Length: 1\r\n\r\nA\(post)Content-Length: 1\r\n\r\nB",
             ["POST /mcp body=A", "POST /mcp body=B"]),
            (chunked + "1\r\nA\r\n0\r\n\r\nGET /x?q HTTP/1.1\r\n\(h)\r\n",
             ["POST /mcp body=A", "GET /x body="]),
            ("\(post)\r\nBAD\r\n", ["POST /mcp body=", "error 400"]),
            ("\(post)\r\nGET /mcp HTT", ["POST /mcp body=", "partial"]),
            ("\r\n", ["partial"]),
            ("POST /mcp HTTP/1.1\r\n", ["partial"]),
            ("\(post)Content-Length: 5\r\n\r\nhell", ["partial"]),
            (chunked + "5\r\nhel", ["partial"]),
            (chunked + "0\r\nX: y\r\n", ["partial"]),
            // Standard limits.
            ("\(post)X: \(String(repeating: "a", count: 16 * 1024))\r\n\r\n", ["error 431"]),
            (String(repeating: "a", count: 17 * 1024), ["error 431"]),
            ("\(post)" + (1..<64).map { "X\($0): v\r\n" }.joined() + "\r\n", ok),
            ("\(post)" + (1...64).map { "X\($0): v\r\n" }.joined() + "\r\n", ["error 431"]),
            ("\(post)Content-Length: 65536\r\n\r\n" + String(repeating: "b", count: 65536),
             ["POST /mcp body=<65536 bytes>"]),
            (chunked + "10000\r\n" + String(repeating: "b", count: 65536) + "\r\n0\r\n\r\n",
             ["POST /mcp body=<65536 bytes>"]),
            (chunked + "10000\r\n" + String(repeating: "b", count: 65536) + "\r\n1\r\n", ["error 413"]),
        ]
        for (input, expected) in rows { check(Array(input.utf8), expected) }

        // Field values are trimmed, keep inner HTAB, and map obs-text bytes to Latin-1 losslessly.
        var raw = Array("\(post)X-Tab: \t a\tb \t\r\nX-Latin: ".utf8)
        raw += [0xE9, 0xFF] + Array("\r\nX-Tab: second\r\n\r\n".utf8)
        check(raw, ok)
        let request = onlyRequest(raw)
        precondition(request.header("x-TAB") == "a\tb" && request.headerValues("X-Tab") == ["a\tb", "second"])
        precondition(request.header("x-latin") == "\u{E9}\u{FF}" && request.header("missing") == nil)
        precondition(request.headers.map(\.name) == ["host", "x-tab", "x-latin", "x-tab"])
        let query = onlyRequest(Array("POST /mcp?a=b?c HTTP/1.1\r\n\(h)\r\n".utf8))
        precondition(query.target == "/mcp?a=b?c" && query.path == "/mcp" && query.version == "HTTP/1.1")
        precondition(!query.wantsClose && query.body.isEmpty)
        return rows.count + 1
    }

    static func limitCases() -> Int {
        let start = "GET / HTTP/1.1\r\nHost: a\r\n"  // 25 bytes
        let rows: [(String, [String])] = [
            (start + "X: \(String(repeating: "a", count: 32))\r\n\r\n", ["GET / body="]),
            (start + "X: \(String(repeating: "a", count: 33))\r\n\r\n", ["error 431"]),
            (start + "A: 1\r\nB: 2\r\n\r\n", ["GET / body="]),
            (start + "A: 1\r\nB: 2\r\nC: 3\r\n\r\n", ["error 431"]),
            (start + "Content-Length: 8\r\n\r\n12345678", ["GET / body=12345678"]),
            (start + "Content-Length: 9\r\n\r\n123456789", ["error 413"]),
        ]
        let chunked = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"
        let chunkRows: [(String, [String])] = [
            ("4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n", ["POST / body=abcdefgh"]),
            ("4\r\nabcd\r\n4\r\nefgh\r\n1\r\n", ["error 413"]),
            ("9\r\n", ["error 413"]),
            ("8;abcdefghijkl\r\n12345678\r\n0\r\n\r\n", ["POST / body=12345678"]),
            ("8;abcdefghijklm\r\n", ["error 400"]),
            ("0\r\nX: abcdefghijklmnopq\r\n\r\n", ["POST / body="]),
            ("0\r\nX: abcdefghijklmnopqr\r\n\r\n", ["error 431"]),
        ]
        precondition(chunked.utf8.count == 56)
        for (input, expected) in rows { check(Array(input.utf8), expected, limits: small) }
        for (input, expected) in chunkRows { check(Array((chunked + input).utf8), expected, limits: small) }
        return rows.count + chunkRows.count
    }

    static func expectContinue() {
        let head = "POST /mcp HTTP/1.1\r\nHost: a\r\nExpect: 100-Continue\r\n"
        var parser = HTTPParser()
        precondition(isContinue(parser.feed(Data((head + "Content-Length: 5\r\n\r\n").utf8))))
        precondition(parser.isReadingBody)
        precondition(isNeedMore(parser.feed(Data())) && isNeedMore(parser.feed(Data("hel".utf8))))
        precondition(body(parser.feed(Data("lo".utf8))) == "hello")
        // Offered again for the next request on the same connection.
        precondition(isContinue(parser.feed(Data((head + "Transfer-Encoding: chunked\r\n\r\n2\r\nab").utf8))))
        precondition(isNeedMore(parser.feed(Data("\r\n0\r\n".utf8))))
        precondition(body(parser.feed(Data("\r\n".utf8))) == "ab")

        // The body already arrived, or there is none: no 100 Continue.
        var whole = HTTPParser()
        precondition(body(whole.feed(Data((head + "Content-Length: 2\r\n\r\nhi").utf8))) == "hi")
        precondition(body(whole.feed(Data((head + "Content-Length: 0\r\n\r\n").utf8))) == "")
        precondition(body(whole.feed(Data((head + "\r\n").utf8))) == "")
        var old = HTTPParser()
        let legacy = "POST /mcp HTTP/1.0\r\nExpect: 100-continue\r\nContent-Length: 2\r\n\r\n"
        precondition(isNeedMore(old.feed(Data(legacy.utf8))))
        // Header checks come first: a bad head is an error, never a 100 Continue.
        var rejected = HTTPParser()
        precondition(status(rejected.feed(Data((head + "Content-Length: 70000\r\n\r\n").utf8))) == 413)
    }

    static func flags() {
        var parser = HTTPParser()
        precondition(!parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 0)
        precondition(isNeedMore(parser.feed(Data("P".utf8))))
        precondition(parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 1)
        let rest = "OST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nab"
        precondition(isNeedMore(parser.feed(Data(rest.utf8))))
        precondition(parser.hasBufferedBytes && parser.isReadingBody && parser.bufferedByteCount == 2)
        precondition(body(parser.feed(Data("c".utf8))) == "abc")
        precondition(!parser.hasBufferedBytes && !parser.isReadingBody && parser.bufferedByteCount == 0)
        precondition(status(parser.feed(Data("BAD\r\n".utf8))) == 400)
        precondition(!parser.hasBufferedBytes && parser.bufferedByteCount == 0)
        precondition(status(parser.feed(Data("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8))) == 400)
        precondition(status(parser.feed(Data())) == 400)
    }

    static func response() {
        let allow = HTTPResponse(status: 405, headers: [("Allow", "POST")]).serialized(close: true)
        precondition(String(decoding: allow, as: UTF8.self) == "HTTP/1.1 405 Method Not Allowed\r\n"
            + "Allow: POST\r\nContent-Length: 0\r\nCache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n")

        let messy = HTTPResponse(status: 200, headers: [
            ("Content-Type", "application/json"), ("Content-Length", "99"), ("cache-control", "private"),
            ("Access-Control-Allow-Origin", "*"), ("Connection", "keep-alive"),
            ("Transfer-Encoding", "chunked"), ("X-Bad", "a\r\nInjected: x"), ("Bad Name", "x"),
            ("X-CONTENT-TYPE-OPTIONS", "nosniff"),
        ], body: Data("{}".utf8))
        let text = String(decoding: messy.serialized(close: false), as: UTF8.self)
        precondition(text == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\ncache-control: private\r\n"
            + "X-CONTENT-TYPE-OPTIONS: nosniff\r\nContent-Length: 2\r\n\r\n{}", text)
        let accepted = String(decoding: HTTPResponse(status: 202).serialized(close: false), as: UTF8.self)
        precondition(accepted.hasPrefix("HTTP/1.1 202 Accepted\r\n") && !accepted.contains("Connection"))
        precondition(accepted.components(separatedBy: "Cache-Control: no-store").count == 2)
        precondition(HTTPResponse.continueBytes == Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        for code in [100, 200, 202, 400, 401, 403, 404, 405, 406, 408, 413, 415, 421, 429, 431, 500, 503] {
            precondition(HTTPResponse.reason(code) != "Status")
        }
    }

    /// Mutates valid requests (flip, insert, delete, duplicate, long runs) and feeds each one whole and
    /// in random pieces: no crash, identical results, and bounded buffering throughout.
    static func fuzz() {
        let seeds = [
            "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47615\r\nContent-Type: application/json\r\n"
                + "Authorization: Bearer ekb_mcp_v1_abc\r\nContent-Length: 13\r\n\r\n{\"jsonrpc\":1}",
            "POST /mcp?x HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nExpect: 100-continue\r\n\r\n"
                + "4;e=1\r\nabcd\r\n3\r\nefg\r\n0\r\nT: x\r\n\r\n",
            "GET /mcp HTTP/1.0\r\nConnection: close\r\n\r\nGET / HTTP/1.1\r\nHost: b\r\n\r\n",
            "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\n\r\nhiPOST / HTTP/1.1\r\nHost: a\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n",
        ].map { Array($0.utf8) }
        let interesting: [UInt8] = [13, 10, 32, 9, 0, 58, 59, 48, 57, 70, 97, 0x7F, 0xFF]
        var rng = XorShift(state: 0x9E37_79B9_7F4A_7C15)
        for index in 0..<10_000 {
            var bytes = seeds[rng.below(seeds.count)]
            for _ in 0...rng.below(4) {
                let at = rng.below(bytes.count + 1)
                let byte = rng.below(2) == 0
                    ? interesting[rng.below(interesting.count)] : UInt8(rng.below(256))
                switch rng.below(16) {
                case 0..<5 where at < bytes.count: bytes[at] = byte
                case 5..<10: bytes.insert(byte, at: at)
                case 10..<14 where at < bytes.count: bytes.remove(at: at)
                case 14:
                    let end = min(bytes.count, at + rng.below(64))
                    bytes.insert(contentsOf: bytes[at..<end], at: at)
                case 15 where rng.below(4) == 0:
                    bytes.insert(contentsOf: repeatElement(byte, count: rng.below(20_000)), at: at)
                default: break
                }
            }
            var cuts: [Int] = []
            var cut = 0
            while true {
                cut += 1 + rng.below(rng.below(2) == 0 ? 8 : 300)
                if cut >= bytes.count { break }
                cuts.append(cut)
            }
            let limits = index % 3 == 0 ? small : .standard
            precondition(run(bytes, cuts: cuts, limits: limits) == run(bytes, cuts: [], limits: limits),
                         "fuzz case \(index)")
        }
    }

    // MARK: Helpers

    static func check(_ input: [UInt8], _ expected: [String], limits: HTTPLimits = .standard) {
        let shown = String(decoding: input.prefix(120), as: UTF8.self).debugDescription
        let actual = run(input, cuts: [], limits: limits, short: true)
        precondition(actual == expected, "\(shown): \(actual) != \(expected)")
        let whole = run(input, cuts: [], limits: limits)
        precondition(run(input, cuts: Array(0..<input.count), limits: limits) == whole, "\(shown) bytewise")
        let step = input.count > 2048 ? 97 : 1
        for cut in stride(from: 0, through: input.count, by: step) {
            precondition(run(input, cuts: [cut], limits: limits) == whole, "\(shown) split at \(cut)")
        }
        if input.count > 2048 {
            precondition(run(input, cuts: Array(stride(from: 0, to: input.count, by: 1000)),
                             limits: limits) == whole, "\(shown) in 1000-byte reads")
        }
    }

    /// Feeds `input` in pieces ending at `cuts`, draining pipelined requests after each read. Whether
    /// 100 Continue is offered depends on the split, so it isn't recorded.
    static func run(_ input: [UInt8], cuts: [Int], limits: HTTPLimits, short: Bool = false) -> [String] {
        var parser = HTTPParser(limits: limits)
        let bound = limits.maxHeaderBytes + limits.maxBodyBytes
        var out: [String] = []
        var from = 0
        for cut in cuts + [input.count] {
            var result = parser.feed(Data(input[from..<cut]))
            precondition(parser.bufferedByteCount <= bound + cut - from)
            from = cut
            drain: while true {
                switch result {
                case .needMore:
                    precondition(parser.bufferedByteCount <= bound)
                    break drain
                case .expectContinue:
                    precondition(parser.isReadingBody)
                case .request(let request):
                    out.append(describe(request, short: short))
                case .error(let status):
                    precondition(parser.bufferedByteCount == 0 && !parser.hasBufferedBytes)
                    out.append("error \(status)")
                    return out
                }
                result = parser.feed(Data())
            }
        }
        if parser.hasBufferedBytes { out.append("partial") }
        return out
    }

    static func describe(_ request: HTTPRequest, short: Bool) -> String {
        let text = request.body.count > 64 ? "<\(request.body.count) bytes>"
            : String(decoding: request.body, as: UTF8.self)
        let close = request.wantsClose ? " close" : ""
        if short { return "\(request.method) \(request.path) body=\(text)\(close)" }
        let headers = request.headers.map { "\($0.name)=\($0.value.debugDescription)" }.joined(separator: ",")
        return "\(request.method) \(request.target) \(request.version) [\(headers)] "
            + "\(request.body.base64EncodedString())\(close)"
    }

    static func onlyRequest(_ input: [UInt8]) -> HTTPRequest {
        var parser = HTTPParser()
        guard case .request(let request) = parser.feed(Data(input)) else { preconditionFailure("no request") }
        return request
    }

    static func isContinue(_ result: HTTPParseResult) -> Bool {
        if case .expectContinue = result { return true }
        return false
    }

    static func isNeedMore(_ result: HTTPParseResult) -> Bool {
        if case .needMore = result { return true }
        return false
    }

    static func body(_ result: HTTPParseResult) -> String? {
        guard case .request(let request) = result else { return nil }
        return String(decoding: request.body, as: UTF8.self)
    }

    static func status(_ result: HTTPParseResult) -> Int? {
        guard case .error(let status) = result else { return nil }
        return status
    }
}

/// Deterministic, so a failing fuzz case reproduces.
struct XorShift {
    var state: UInt64

    mutating func below(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(bound))
    }
}
