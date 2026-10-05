import Foundation

/// The browser pages of the authorization endpoint. Self-contained (no external resources), and the
/// CSP lets only this response's own inline script and style run, so an escaping slip still can't
/// execute script. Every interpolated value goes through `escape`.
enum OAuthPages {
    static func closed() -> HTTPResponse {
        page(403, title: "Pairing isn't open", body: """
            <h1>Pairing isn’t open</h1>
            <p>In \(escape(AppIdentity.displayName)) on your Mac, open the client you want to use and \
            choose Connect a Cloud App. Then start connecting again from the app.</p>
            """)
    }

    static func error(_ status: Int, title: String, message: String) -> HTTPResponse {
        page(status, title: title, body: "<h1>\(escape(title))</h1>\n<p>\(escape(message))</p>")
    }

    /// Shows the code the Mac also shows and polls `authorize/status` every 2 s until the user answers.
    static func pairing(_ request: PairingRequest, clientName: String) -> HTTPResponse {
        let nonce = randomNonce()
        let script = """
            (function () {
              var status = document.getElementById("status");
              var url = "authorize/status?request=" + encodeURIComponent(document.body.dataset.request);
              function later() { setTimeout(poll, 2000); }
              function poll() {
                fetch(url, { cache: "no-store", credentials: "omit" })
                  .then(function (response) { return response.json(); })
                  .then(function (answer) {
                    if (typeof answer.redirect === "string") {
                      status.textContent = "Returning to the app…";
                      location.replace(answer.redirect);
                    } else if (answer.status === "expired") {
                      status.textContent = "This request expired or was replaced. "
                        + "Start connecting again from the app.";
                    } else { later(); }
                  }, later);
              }
              later();
            })();
            """
        let body = """
            <h1>Connect \(escape(request.appName)) to \(escape(AppIdentity.displayName))</h1>
            <p>Check that \(escape(AppIdentity.displayName)) on your Mac shows this code, then choose \
            Allow there.</p>
            <p class="code" aria-label="Pairing code">\(escape(request.code))</p>
            <dl>
            <dt>Client</dt><dd>\(escape(clientName))</dd>
            <dt>Returns to</dt><dd>\(escape(request.redirectHost))</dd>
            </dl>
            <p id="status" role="status">Waiting for you to answer on your Mac…</p>
            <noscript><p>This page needs JavaScript to continue after you answer on your Mac.</p></noscript>
            <script nonce="\(nonce)">\(script)</script>
            """
        return page(200, title: "Connect \(request.appName)", body: body, nonce: nonce,
                    dataRequest: request.id.uuidString.lowercased())
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// Headers shared by every page and redirect of the authorization endpoint.
    static let securityHeaders: [(name: String, value: String)] = [
        ("X-Frame-Options", "DENY"),
        ("Referrer-Policy", "no-referrer"),
        ("Cache-Control", "no-store"),
    ]

    private static func page(_ status: Int, title: String, body: String, nonce: String = randomNonce(),
                             dataRequest: String? = nil) -> HTTPResponse {
        let data = dataRequest.map { " data-request=\"\(escape($0))\"" } ?? ""
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="referrer" content="no-referrer">
            <title>\(escape(title)) – \(escape(AppIdentity.displayName))</title>
            <style nonce="\(nonce)">\(style)</style>
            </head>
            <body\(data)>
            <main>
            \(body)
            </main>
            </body>
            </html>

            """
        let policy = "default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; "
            + "connect-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'; "
            + "frame-ancestors 'none'"
        return HTTPResponse(status: status, headers: [
            ("Content-Type", "text/html; charset=utf-8"),
            ("Content-Security-Policy", policy),
        ] + securityHeaders, body: Data(html.utf8))
    }

    private static let style = """
        :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #1c1c1e; --card: #2c2c2e; --text: #f5f5f7; --muted: #a1a1a6; }
        }
        body { margin: 0; background: var(--bg); color: var(--text);
               font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        main { max-width: 32rem; margin: 10vh auto; padding: 2rem; background: var(--card);
               border-radius: 14px; }
        h1 { font-size: 1.4rem; line-height: 1.3; margin: 0 0 1rem; overflow-wrap: anywhere; }
        p, dd { overflow-wrap: anywhere; }
        .code { font: 600 2.4rem/1.2 ui-monospace, Menlo, monospace; letter-spacing: 0.08em;
                text-align: center; margin: 1.5rem 0; }
        dl { display: grid; grid-template-columns: auto 1fr; gap: 0.25rem 1rem; color: var(--muted); }
        dd { margin: 0; }
        #status { color: var(--muted); }
        @media (max-width: 36rem) { main { margin: 0; border-radius: 0; padding: 1.5rem 1rem; } }
        """

    private static func randomNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return Data(bytes).base64EncodedString()
    }
}
