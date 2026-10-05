"""Offline integration tests for the MCP server over real loopback sockets.

Runs build/mcp-server-test (the real listener, server, catalog, mapping,
pipeline, registry and journal, with fake EventKit and approvals) and talks to
it with http.client and raw sockets. Standard library only.

Usage: mcp_test.py HARNESS_BINARY TOOLS_JSON
"""

import base64
import http.client
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from concurrent.futures import ThreadPoolExecutor

LEGACY = "2025-11-25"
MODERN = "2026-07-28"
META_VERSION = "io.modelcontextprotocol/protocolVersion"
META_CAPS = "io.modelcontextprotocol/clientCapabilities"
META_INFO = "io.modelcontextprotocol/clientInfo"

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{name}: {detail}")


class Harness:
    def __init__(self, binary, approval="allow"):
        self.dir = tempfile.mkdtemp(prefix="ekb-mcp-test-")
        os.chmod(self.dir, 0o700)
        env = dict(os.environ, EVENTKIT_MCP_TEST_DIR=self.dir, EVENTKIT_MCP_TEST_APPROVAL=approval)
        self.proc = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, env=env, text=True)
        first = json.loads(self.proc.stdout.readline())
        self.port = first["port"]
        self.clients = first["clients"]
        self.lock = threading.Lock()

    def control(self, **command):
        with self.lock:
            self.proc.stdin.write(json.dumps(command) + "\n")
            self.proc.stdin.flush()
            return json.loads(self.proc.stdout.readline())

    def token(self, name):
        return self.clients[name]["token"]

    def activity(self):
        return self.control(cmd="activity")["activity"]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()


class Client:
    """One keep-alive HTTP connection."""

    def __init__(self, harness, token=None, host=None):
        self.h = harness
        self.token = token
        self.host = host or f"127.0.0.1:{harness.port}"
        self.conn = http.client.HTTPConnection("127.0.0.1", harness.port, timeout=70)
        self.next_id = 1

    def raw(self, method="POST", path="/mcp", body=b"", headers=None, auth=True,
            content_type="application/json"):
        all_headers = {"Host": self.host}
        if content_type:
            all_headers["Content-Type"] = content_type
        all_headers["Accept"] = "application/json, text/event-stream"
        if auth and self.token:
            all_headers["Authorization"] = "Bearer " + self.token
        all_headers.update(headers or {})
        if isinstance(body, (dict, list, str)):
            body = json.dumps(body).encode()
        if method in ("POST", "PUT") or body:
            all_headers.setdefault("Content-Length", str(len(body)))
        self.conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        for key, value in all_headers.items():
            if value is not None:
                self.conn.putheader(key, value)
        self.conn.endheaders(body if body else None)
        response = self.conn.getresponse()
        data = response.read()
        parsed = None
        if data and response.getheader("Content-Type", "").startswith("application/json"):
            parsed = json.loads(data)
        return response.status, dict(response.getheaders()), parsed, data

    def legacy(self, method, params=None, version=LEGACY, notify=False, rid=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = rid if rid is not None else self._id()
        headers = {"MCP-Protocol-Version": version} if version else {}
        return self.raw(body=message, headers=headers)

    def modern(self, method, params=None, name=None, rid=None, info=None, extra=None):
        params = dict(params or {})
        meta = {META_VERSION: MODERN, META_CAPS: {}}
        if info:
            meta[META_INFO] = info
        params["_meta"] = meta
        message = {"jsonrpc": "2.0", "id": rid if rid is not None else self._id(),
                   "method": method, "params": params}
        headers = {"MCP-Protocol-Version": MODERN, "Mcp-Method": method}
        if name is not None:
            headers["Mcp-Name"] = name
        headers.update(extra or {})
        return self.raw(body=message, headers=headers)

    def call(self, tool, arguments, modern=False, info=None):
        params = {"name": tool, "arguments": arguments}
        if modern:
            status, _, body, _ = self.modern("tools/call", params, name=tool, info=info)
        else:
            status, _, body, _ = self.legacy("tools/call", params)
        return status, body

    def _id(self):
        self.next_id += 1
        return self.next_id

    def close(self):
        self.conn.close()


# A small JSON Schema subset validator for tool outputs (no $ref across tools).
def validate(value, schema, root=None, path="$"):
    root = root or schema
    if "$ref" in schema:
        target = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            target = target[part]
        return validate(value, target, root, path)
    errors = []
    types = schema.get("type")
    if types:
        types = types if isinstance(types, list) else [types]

        def matches(t):
            return {
                "object": isinstance(value, dict),
                "array": isinstance(value, list),
                "string": isinstance(value, str),
                "boolean": isinstance(value, bool),
                "integer": isinstance(value, int) and not isinstance(value, bool),
                "number": isinstance(value, (int, float)) and not isinstance(value, bool),
                "null": value is None,
            }[t]
        if not any(matches(t) for t in types):
            return [f"{path}: expected {types}, got {type(value).__name__}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in enum")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing {key}")
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected {key}")
        for key, sub in props.items():
            if key in value:
                errors += validate(value[key], sub, root, f"{path}.{key}")
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            errors += validate(item, schema["items"], root, f"{path}[{index}]")
    return errors


def inline(value, shared):
    if isinstance(value, dict):
        if len(value) == 1 and isinstance(value.get("$ref"), str) and value["$ref"].startswith("#/$defs/"):
            name = value["$ref"][8:]
            if name in shared:
                return inline(shared[name], shared)
        return {k: inline(v, shared) for k, v in value.items()}
    if isinstance(value, list):
        return [inline(v, shared) for v in value]
    return value


def allows(mask, tool):
    bits = {"read": 1, "create": 2, "update": 4, "delete": 8, "complete": 16}
    verb, _, kind = tool.partition("_")
    return mask & bits.get(verb, 0)


def expected_tools(contract, grants):
    names = []
    for tool in contract["tools"]:
        name = tool["name"]
        if name == "list_collections":
            names.append(name)
            continue
        verb, _, kind = name.partition("_")
        resource = "calendar" if kind in ("event", "events") else "reminderList"
        bit = {"read": 1, "create": 2, "update": 4, "delete": 8, "complete": 16}[verb]
        if any(g["resource"] == resource and g["mask"] & bit for g in grants):
            names.append(name)
    return names


def text_of(result):
    return result["content"][0]["text"]


def main():
    harness_binary, tools_path = sys.argv[1], sys.argv[2]
    with open(tools_path) as f:
        contract = json.load(f)
    shared = {k: v for k, v in contract["$defs"].items() if k != "$comment"}
    catalog = {t["name"]: inline(t, shared) for t in contract["tools"]}

    h = Harness(harness_binary)
    try:
        run_core(h, catalog, contract)
        run_writes(h)
        run_limits(h)
    finally:
        h.close()

    a = Harness(harness_binary, approval="none")
    try:
        run_approvals(a)
    finally:
        a.close()

    t = Harness(harness_binary)
    try:
        run_auth_lockout(t)
    finally:
        t.close()

    if failures:
        print("MCP integration tests failed:")
        for failure in failures:
            print("  " + failure)
        sys.exit(1)
    print(f"MCP server: {checks} checks over loopback (both eras, §7.5 statuses, Host/Origin, "
          "concurrency, slow-loris, approvals, idempotency, limits, output schemas) passed")


def run_core(h, catalog, contract):
    c = Client(h, h.token("agent"))
    # A.1: legacy handshake. No session header, the version echoed.
    status, headers, body, _ = c.legacy("initialize", {
        "protocolVersion": LEGACY, "capabilities": {},
        "clientInfo": {"name": "claude-code", "version": "2.4.1"}}, version=None, rid=0)
    result = body["result"]
    check("initialize status", status == 200, status)
    check("initialize version", result["protocolVersion"] == LEGACY, result)
    check("initialize no session", "Mcp-Session-Id" not in headers, headers)
    check("initialize tools capability", result["capabilities"] == {"tools": {"listChanged": False}})
    check("initialize serverInfo", result["serverInfo"]["name"] == "eventkit-bridge" and
          result["serverInfo"]["title"] == "EventKit Bridge", result)
    check("initialize instructions", result["instructions"] == contract["serverInstructions"])
    check("legacy has no resultType", "resultType" not in result)
    check("legacy no-store", headers.get("Cache-Control") == "no-store", headers)
    check("nosniff", headers.get("X-Content-Type-Options") == "nosniff", headers)
    check("no CORS", not any(k.lower().startswith("access-control") for k in headers), headers)
    for asked, answered in [("2025-06-18", "2025-06-18"), ("2025-03-26", "2025-03-26"),
                            (MODERN, LEGACY), ("1999-01-01", LEGACY)]:
        _, _, body, _ = c.legacy("initialize", {"protocolVersion": asked, "capabilities": {}}, version=None)
        check(f"negotiate {asked}", body["result"]["protocolVersion"] == answered, body)
    status, _, body, data = c.legacy("notifications/initialized", notify=True)
    check("initialized notification 202", status == 202 and data == b"", (status, data))
    status, _, body, _ = c.legacy("ping")
    check("ping", status == 200 and body["result"] == {}, body)

    # tools/list follows the saved grants (Work: Read+Create, Groceries: Read+Create+Complete).
    _, _, body, _ = c.legacy("tools/list")
    names = [t["name"] for t in body["result"]["tools"]]
    check("A.1 visible tools", names == ["list_collections", "read_events", "create_event",
                                         "read_reminders", "create_reminder", "complete_reminder"], names)
    for tool in body["result"]["tools"]:
        check(f"definition {tool['name']}", tool == catalog[tool["name"]], tool["name"])
    check("legacy list has no ttl", "ttlMs" not in body["result"] and "nextCursor" not in body["result"])
    for name, grants in [
        ("none", []),
        ("reader", [{"resource": "calendar", "mask": 1}]),
        ("full", [{"resource": "calendar", "mask": 15}, {"resource": "reminderList", "mask": 31}]),
    ]:
        other = Client(h, h.token(name))
        _, _, body, _ = other.legacy("tools/list")
        got = [t["name"] for t in body["result"]["tools"]]
        check(f"visibility {name}", got == expected_tools(contract, grants), got)
        other.close()
    # No collection IDs in any definition.
    check("no IDs in definitions", "CAL-WORK" not in json.dumps(catalog))

    # A.1 read, validated against the output schema.
    status, body = c.call("read_events", {"calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00-04:00",
                                          "end": "2026-10-07T00:00:00-04:00"})
    result = body["result"]
    check("read_events ok", status == 200 and result["isError"] is False, body)
    event = result["structuredContent"]["events"][0]
    check("A.1 event", event == {"id": "EV1", "version": "1791200000.123456", "title": "Design review",
                                 "title_truncated": False, "start": "2026-10-06T10:00:00-04:00",
                                 "end": "2026-10-06T11:00:00-04:00", "all_day": False,
                                 "recurring": False, "time_zone": "GMT", "editable": True}, event)
    check("text mirrors structured", json.loads(text_of(result)) == result["structuredContent"])
    errors = validate(result["structuredContent"], catalog["read_events"]["outputSchema"])
    check("read_events schema", not errors, errors)
    allday = result["structuredContent"]["events"][1]
    check("all-day row", allday.get("start_date") == "2026-10-06" and allday.get("end_date") == "2026-10-06"
          and allday["editable"] is False, allday)

    _, body = c.call("list_collections", {})
    lc = body["result"]["structuredContent"]
    check("list_collections schema", not validate(lc, catalog["list_collections"]["outputSchema"]),
          validate(lc, catalog["list_collections"]["outputSchema"]))
    check("list_collections grants only", [x["id"] for x in lc["calendars"]] == ["CAL-WORK"] and
          [x["id"] for x in lc["reminder_lists"]] == ["LIST-GROC"], lc)
    check("list_collections actions", lc["calendars"][0]["actions"] == ["read", "create"] and
          lc["reminder_lists"][0]["actions"] == ["read", "create", "complete"], lc)
    check("list_collections zone", lc["time_zone"] == "America/New_York", lc)
    ghost = Client(h, h.token("ghost"))
    _, body = ghost.call("list_collections", {})
    row = body["result"]["structuredContent"]["calendars"][0]
    check("unavailable collection", row["available"] is False and row["name"] is None, row)
    _, body = ghost.call("read_events", {"calendar_id": "CAL-GONE", "start": "2026-10-06T00:00:00Z",
                                         "end": "2026-10-07T00:00:00Z"})
    check("target unavailable text", body["result"]["isError"] and "list_collections" in text_of(body["result"]),
          body)
    ghost.close()

    _, body = c.call("read_reminders", {"list_id": "LIST-GROC"})
    rr = body["result"]["structuredContent"]
    check("read_reminders schema", not validate(rr, catalog["read_reminders"]["outputSchema"]),
          validate(rr, catalog["read_reminders"]["outputSchema"]))

    # Argument problems are tool errors and never reach Activity.
    before = len(h.activity())
    _, body = c.call("read_events", {"calendar_id": "CAL-WORK", "start": "tomorrow at 9",
                                     "end": "2026-10-07T00:00:00-04:00"})
    check("A.3 invalid arguments", text_of(body["result"]) ==
          'Invalid arguments: start: expected an ISO 8601 date-time with an offset, like '
          '2026-10-06T09:00:00-04:00; got "tomorrow at 9". (code: invalid_arguments)', body)
    _, body = c.call("read_events", {"calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00Z",
                                     "end": "2026-10-07T00:00:00Z", "colour": "red"})
    check("unknown argument", body["result"]["isError"] and "colour" in text_of(body["result"]), body)
    _, body = c.call("read_events", "nope")
    check("arguments not an object", body["result"]["isError"], body)
    check("validation not in activity", len(h.activity()) == before)

    # A known tool the client can't see: forbidden, recorded with its target.
    _, body = c.call("delete_event", {"calendar_id": "CAL-WORK", "event_id": "EV1",
                                      "version": "1791200000.123456"})
    check("A.3 forbidden", text_of(body["result"]).startswith(
        "Not allowed: this agent can't delete events in that calendar.") and
        text_of(body["result"]).endswith("(code: forbidden)"), body)
    rows = h.activity()
    check("forbidden recorded", rows[0]["outcome"] == "forbidden" and rows[0]["targetID"] == "CAL-WORK" and
          rows[0]["via"] == "mcp", rows[0])
    # Unknown tool: a protocol error.
    status, body = c.call("make_coffee", {})
    check("unknown tool -32602", status == 200 and body["error"]["code"] == -32602, body)

    # Activity says via MCP and which agent, as it reported itself.
    read_row = next(r for r in h.activity() if r["command"] == "read_events" and r["outcome"] == "success")
    check("activity via/agent", read_row.get("via") == "mcp" and read_row.get("agent") == "claude-code 2.4.1",
          read_row)
    check("connection status", h.control(cmd="connection", client="agent")["connection"]["agent"] ==
          "claude-code 2.4.1")

    # Modern era: stateless, _meta on every request, headers must match.
    m = Client(h, h.token("agent"))
    status, _, body, _ = m.modern("server/discover", info={"name": "codex", "version": "0.98.0"})
    result = body["result"]
    check("discover", status == 200 and result["resultType"] == "complete" and
          result["supportedVersions"] == [MODERN, "2025-11-25", "2025-06-18", "2025-03-26"], body)
    check("discover names the client", result["_meta"]["dev.eventkitbridge/client"]["name"] == "agent", result)
    check("modern serverInfo", result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "eventkit-bridge")
    _, _, body, _ = m.modern("tools/list")
    check("modern list ttl", body["result"]["ttlMs"] == 30000 and body["result"]["cacheScope"] == "private", body)
    status, _, body, _ = m.modern("tools/call", {"name": "list_collections", "arguments": {}},
                                  name="list_collections")
    check("modern call", status == 200 and body["result"]["resultType"] == "complete", body)
    status, _, body, _ = m.modern("tools/call", {"name": "list_collections", "arguments": {}},
                                  name="=?base64?" + base64.b64encode(b"list_collections").decode() + "?=")
    check("base64 Mcp-Name", status == 200 and "result" in body, body)
    status, _, body, _ = m.modern("tools/call", {"name": "list_collections", "arguments": {}}, name="read_events")
    check("Mcp-Name mismatch", status == 400 and body["error"]["code"] == -32020, body)
    status, _, body, _ = m.modern("tools/list", extra={"Mcp-Method": "tools/call"})
    check("Mcp-Method mismatch", status == 400 and body["error"]["code"] == -32020, body)
    status, _, body, _ = m.modern("tools/list", extra={"MCP-Protocol-Version": LEGACY})
    check("version header mismatch", status == 400 and body["error"]["code"] == -32020, body)
    message = {"jsonrpc": "2.0", "id": 9, "method": "tools/list",
               "params": {"_meta": {META_VERSION: "2099-01-01", META_CAPS: {}}}}
    status, _, body, _ = m.raw(body=message, headers={"MCP-Protocol-Version": "2099-01-01", "Mcp-Method": "tools/list"})
    check("unsupported modern", status == 400 and body["error"]["code"] == -32022 and
          "2025-11-25" in body["error"]["data"]["supported"], body)
    message = {"jsonrpc": "2.0", "id": 10, "method": "tools/list", "params": {"_meta": {META_VERSION: MODERN}}}
    status, _, body, _ = m.raw(body=message, headers={"MCP-Protocol-Version": MODERN, "Mcp-Method": "tools/list"})
    check("missing capabilities", status == 400 and body["error"]["code"] == -32602, body)
    status, _, body, _ = m.modern("resources/list")
    check("modern unknown method 404", status == 404 and body["error"]["code"] == -32601, body)
    status, _, body, _ = c.legacy("resources/list")
    check("legacy unknown method 200", status == 200 and body["error"]["code"] == -32601, body)
    status, _, body, _ = c.legacy("tools/list", version=MODERN)
    check("legacy with modern header", status == 400 and body["error"]["code"] == -32602, body)
    status, _, body, _ = c.legacy("tools/list", version="2024-11-05")
    check("legacy unsupported header", status == 400 and body["error"]["code"] == -32022, body)
    status, _, body, _ = c.legacy("tools/list", version=None)
    check("no header is 2025-03-26", status == 200 and "result" in body, body)
    # IDs echo with their type.
    _, _, body, _ = c.legacy("ping", rid="abc")
    check("string id echo", body["id"] == "abc")
    _, _, body, _ = c.legacy("ping", rid=7)
    check("int id echo", body["id"] == 7 and isinstance(body["id"], int))
    status, _, body, _ = c.raw(body=b'{"jsonrpc":"2.0","id":null,"method":"ping"}')
    check("null id invalid", status == 400 and body["error"]["code"] == -32600, body)
    status, _, body, _ = c.raw(body=b"[{}]")
    check("batch rejected", status == 400 and body["error"]["code"] == -32600 and body["id"] is None, body)
    status, _, body, _ = c.raw(body=b"{nope")
    check("parse error", status == 400 and body["error"]["code"] == -32700, body)
    status, _, _, data = c.raw(body={"jsonrpc": "2.0", "id": 1, "result": {}})
    check("client response 202", status == 202 and data == b"", status)
    m.close()

    run_http_statuses(h)
    run_concurrency(h)
    c.close()


def run_http_statuses(h):
    c = Client(h, h.token("agent"))
    ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
    status, _, _, data = c.raw(path="/other", body=ping)
    check("404 path", status == 404 and b"/mcp" in data, status)
    status, _, _, _ = Client(h, h.token("agent"), host="evil.example").raw(body=ping)
    check("421 host", status == 421, status)
    status, _, _, _ = Client(h, h.token("agent"), host=f"127.0.0.1:{h.port + 1}").raw(body=ping)
    check("421 wrong port", status == 421, status)
    status, _, _, _ = Client(h, h.token("agent"), host=f"localhost:{h.port}").raw(body=ping)
    check("localhost host ok", status == 200, status)
    status, _, body, _ = c.raw(body=ping, headers={"Origin": "https://evil.example"})
    check("403 origin", status == 403 and "id" not in body, body)
    for header in ["Tailscale-Funnel-Request", "CF-Connecting-IP", "CF-Ray", "X-Forwarded-Host"]:
        status, _, body, _ = c.raw(body=ping, headers={header: "?1"})
        check(f"403 forwarded {header}", status == 403 and "Remote Access" in body["error"]["message"], body)
    for method in ["GET", "DELETE", "OPTIONS", "PUT"]:
        status, headers, _, _ = c.raw(method=method, body=b"")
        check(f"405 {method}", status == 405 and headers.get("Allow") == "POST", (method, status))
    status, _, _, _ = c.raw(body=ping, content_type="text/plain")
    check("415", status == 415, status)
    status, _, _, _ = c.raw(body=ping, content_type="application/json; charset=utf-8")
    check("charset ok", status == 200, status)
    status, _, _, _ = c.raw(body=ping, headers={"Accept": "text/html"})
    check("406", status == 406, status)
    status, _, _, _ = c.raw(body=ping, headers={"Accept": "*/*"})
    check("accept */*", status == 200, status)
    status, headers, body, _ = Client(h).raw(body=ping)
    check("401 missing", status == 401 and body["error"]["code"] == -32001 and body["id"] is None and
          headers.get("WWW-Authenticate") == 'Bearer realm="EventKit Bridge"', (status, headers))
    status, _, body2, _ = Client(h, "ekb_mcp_v1_" + "0" * 64).raw(body=ping)
    check("401 same body", status == 401 and body2 == body, body2)
    status, _, _, _ = Client(h, "garbage").raw(body=ping)
    check("401 malformed", status == 401, status)
    # Oversize body → 413 and close.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
                f"Content-Length: 70000\r\n\r\n".encode())
    reply = raw.recv(1024)
    check("413", reply.startswith(b"HTTP/1.1 413"), reply[:40])
    raw.close()
    # Duplicate Host → 400.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nHost: evil\r\n"
                f"Content-Length: 0\r\n\r\n".encode())
    check("400 duplicate host", raw.recv(1024).startswith(b"HTTP/1.1 400"))
    raw.close()
    # Keep-alive: several requests on one connection, then Connection: close.
    k = Client(h, h.token("agent"))
    statuses = [k.legacy("ping")[0] for _ in range(5)]
    sock = k.conn.sock
    check("keep-alive reuse", statuses == [200] * 5 and sock is not None and k.conn.sock is sock, statuses)
    status, headers, _, _ = k.raw(body=ping, headers={"Connection": "close"})
    check("connection close honored", status == 200 and headers.get("Connection") == "close", headers)
    # Pipelining: two requests in one write, answered in order.
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps(ping).encode()
    one = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
           f"Authorization: Bearer {h.token('agent')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
    raw.sendall(one + one)
    time.sleep(0.5)
    data = raw.recv(65536)
    check("pipelined", data.count(b"HTTP/1.1 200") == 2, data[:80])
    raw.close()
    # Slow loris: headers that never finish are cut off after 10 s with 408.
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.sendall(b"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n")
    raw.settimeout(14)
    started = time.time()
    try:
        data = raw.recv(1024)
    except socket.timeout:
        data = b""
    elapsed = time.time() - started
    check("slow loris 408", data.startswith(b"HTTP/1.1 408") and 9 <= elapsed <= 13, (data[:30], elapsed))
    raw.close()
    c.close()


def run_concurrency(h):
    # Two clients, 25 calls each: under each client's burst of 30.
    def one(index):
        client = Client(h, h.token("none" if index % 2 else "ghost"))
        try:
            if index % 4 < 2:
                status, body = client.call("list_collections", {}, modern=True)
            else:
                client.legacy("initialize", {"protocolVersion": LEGACY, "capabilities": {}}, version=None)
                status, body = client.call("list_collections", {})
            return status == 200 and body["result"]["isError"] is False
        finally:
            client.close()
    with ThreadPoolExecutor(max_workers=25) as pool:
        results = list(pool.map(one, range(50)))
    check("50 concurrent mixed-era calls", all(results), results.count(False))


def run_writes(h):
    c = Client(h, h.token("full"))
    info = {"name": "codex", "version": "0.98.0"}
    # A.2: modern create_reminder.
    status, body = c.call("create_reminder", {"list_id": "LIST-GROC", "title": "Buy oat milk",
                                              "due": {"date_time": "2026-11-05T09:00:00-05:00"}},
                          modern=True, info=info)
    result = body["result"]
    s = result["structuredContent"]
    check("A.2 create", status == 200 and not result["isError"] and s["list_id"] == "LIST-GROC" and
          s["idempotency_key"].startswith("ekb3_") and
          s["reminder"]["due"] == {"date_time": "2026-11-05T09:00:00-05:00", "time_zone": "America/New_York"},
          body)
    check("A.2 resultType/_meta", result["resultType"] == "complete" and
          "io.modelcontextprotocol/serverInfo" in result["_meta"], result)
    key = s["idempotency_key"]
    rows = h.activity()
    check("write recorded via mcp", rows[0]["command"] == "create_reminder" and rows[0]["outcome"] == "success"
          and rows[0]["agent"] == "codex 0.98.0", rows[0])
    # Same key + same arguments → the recorded result, marked repeated.
    status, body = c.call("create_reminder", {"list_id": "LIST-GROC", "title": "Buy oat milk",
                                              "due": {"date_time": "2026-11-05T09:00:00-05:00"},
                                              "idempotency_key": key})
    check("replay repeated", body["result"]["structuredContent"].get("repeated") is True and
          body["result"]["structuredContent"]["reminder"]["id"] == s["reminder"]["id"], body)
    # Same key, different arguments → conflict.
    _, body = c.call("create_reminder", {"list_id": "LIST-GROC", "title": "Something else",
                                         "idempotency_key": key})
    check("key conflict", body["result"]["isError"] and "idempotency_conflict" in text_of(body["result"]), body)
    _, body = c.call("create_reminder", {"list_id": "LIST-GROC", "title": "x", "idempotency_key": "made-up"})
    check("invalid key never replaced", body["result"]["isError"] and
          "invalid_idempotency_key" in text_of(body["result"]), body)
    # Every write tool end to end.
    calls = [
        ("create_event", {"calendar_id": "CAL-WORK", "title": "Dentist", "start": "2026-10-06T09:00:00-04:00",
                          "end": "2026-10-06T10:00:00-04:00"}),
        ("create_event", {"calendar_id": "CAL-WORK", "title": "Holiday", "all_day": True,
                          "start_date": "2026-12-24", "end_date": "2026-12-26"}),
        ("update_event", {"calendar_id": "CAL-WORK", "event_id": "EV1", "version": "1791200000.123456",
                          "title": "Design review", "start": "2026-10-06T11:00:00-04:00",
                          "end": "2026-10-06T12:00:00-04:00"}),
        ("delete_event", {"calendar_id": "CAL-WORK", "event_id": "EV1", "version": "1791200000.123456"}),
        ("update_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000",
                             "title": "Buy oat milk"}),
        ("complete_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000"}),
        ("delete_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000"}),
    ]
    bodies = []
    for tool, arguments in calls:
        status, body = c.call(tool, arguments)
        bodies.append(body)
        result = body.get("result", {})
        ok = status == 200 and result.get("isError") is False
        check(f"{tool} works", ok, body)
        if ok:
            errors = validate(result["structuredContent"], inline_schema(tool))
            check(f"{tool} output schema", not errors, errors)
    # That was 10 writes: the burst. The next one waits.
    event = bodies[1]["result"]["structuredContent"]["event"]
    check("all-day readback dates", event.get("start_date") == "2026-12-24" and event.get("end_date") == "2026-12-26"
          and event.get("verified") is True, event)
    _, body = c.call("delete_reminder", {"list_id": "LIST-GROC", "reminder_id": "R2", "version": "1"})
    check("write burst limited", "rate_limited" in text_of(body["result"]), body)
    _, body = c.call("create_event", {"calendar_id": "CAL-WORK", "title": "Gap", "start": "2026-03-08T02:30",
                                      "end": "2026-03-08T04:00"})
    check("DST gap", "nonexistent_local_time" in text_of(body["result"]), body)
    _, body = c.call("create_event", {"calendar_id": "CAL-WORK", "title": "Fold", "start": "2026-11-01T01:30",
                                      "end": "2026-11-01T03:00"})
    check("DST fold", "ambiguous_local_time" in text_of(body["result"]) and "-04:00 or -05:00" in
          text_of(body["result"]), body)
    # Bridge off: tool calls refused and recorded; listing still works.
    h.control(cmd="bridge", on=False)
    _, body = c.call("list_collections", {})
    check("bridge_off text", text_of(body["result"]).endswith("(code: bridge_off)") and
          "turned off" in text_of(body["result"]), body)
    _, _, body, _ = c.legacy("tools/list")
    check("list while off", "result" in body and body["result"]["tools"], body)
    check("bridge_off recorded", h.activity()[0]["outcome"] == "error:bridge_off")
    h.control(cmd="bridge", on=True)
    _, body = c.call("list_collections", {})
    check("recovers without reconnect", body["result"]["isError"] is False, body)
    # A grant change applies to the next call; revoke → unauthorized at HTTP level.
    reader = Client(h, h.token("reader"))
    reader.call("list_collections", {})
    h.control(cmd="grants", client="reader", grants=[])
    _, body = reader.call("read_events", {"calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00Z",
                                          "end": "2026-10-07T00:00:00Z"})
    check("grant change applies", "forbidden" in text_of(body["result"]), body)
    h.control(cmd="revoke", client="reader")
    status, _, _, _ = reader.legacy("ping")
    check("revoked token 401", status == 401, status)
    reader.close()
    c.close()


def inline_schema(tool):
    return CATALOG[tool]["outputSchema"]


def run_limits(h):
    # 120/min with a burst of 30: the 31st quick call is limited, with a wait.
    c = Client(h, h.token("agent"))
    limited = None
    for _ in range(40):
        _, body = c.call("list_collections", {})
        if body["result"]["isError"] and "rate_limited" in text_of(body["result"]):
            limited = text_of(body["result"])
            break
    check("rate limited", limited is not None and "Wait" in limited, limited)
    check("rate_limited recorded", h.activity()[0]["outcome"] == "error:rate_limited")
    c.close()


def run_approvals(h):
    c = Client(h, h.token("ask"))
    create = {"list_id": "LIST-GROC", "title": "Buy oat milk"}
    # Allow.
    result = {}

    def call():
        result["body"] = c.call("create_reminder", create)[1]
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="answer", decision="allow")
    thread.join(10)
    check("approved write", result["body"]["result"]["isError"] is False, result)
    check("approval recorded", h.activity()[0].get("approval") == "user", h.activity()[0])
    # Reads never ask.
    _, body = c.call("read_reminders", {"list_id": "LIST-GROC"})
    check("reads never ask", body["result"]["isError"] is False, body)
    # Deny.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="answer", decision="deny")
    thread.join(10)
    check("A.3 declined", text_of(result["body"]["result"]) ==
          "Declined: the user declined this change in EventKit Bridge. Don't retry it unless the user asks you to. "
          "(code: approval_denied)", result)
    # Timeout.
    h.control(cmd="approval", mode="timeout")
    _, body = c.call("create_reminder", create)
    check("approval timeout", "approval_timed_out" in text_of(body["result"]) and "45 seconds" in
          text_of(body["result"]), body)
    h.control(cmd="approval", mode="none")
    # Access changes while the panel is up, then the user allows → scope_changed.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="grants", client="ask", grants=[
        {"resource": "reminderList", "targetID": "LIST-GROC", "mask": 3}])
    h.control(cmd="answer", decision="allow")
    thread.join(10)
    check("revision change during approval", "scope_changed" in text_of(result["body"]["result"]), result)
    h.control(cmd="grants", client="ask", grants=[
        {"resource": "calendar", "targetID": "CAL-WORK", "mask": 15},
        {"resource": "reminderList", "targetID": "LIST-GROC", "mask": 31}])
    # Disconnect while waiting → cancelled in Activity, nothing journaled.
    entries = h.control(cmd="journal_entries")["count"]
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                       "params": {"name": "create_reminder", "arguments": create}}).encode()
    raw.sendall((f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
                 f"Authorization: Bearer {h.token('ask')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body)
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    raw.close()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 0)
    wait_for(lambda: h.activity()[0]["outcome"] == "error:cancelled")
    check("disconnect cancels", h.activity()[0]["outcome"] == "error:cancelled", h.activity()[0])
    check("cancelled before journal", h.control(cmd="journal_entries")["count"] == entries)
    # Legacy notifications/cancelled withdraws a waiting approval.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    rid = c.next_id
    other = Client(h, h.token("ask"))
    status, _, _, _ = other.legacy("notifications/cancelled", {"requestId": rid}, notify=True)
    thread.join(10)
    check("notifications/cancelled", status == 202 and "cancelled" in text_of(result["body"]["result"]), result)
    other.close()
    # Bridge turned off while waiting → scope_changed.
    thread = threading.Thread(target=call)
    thread.start()
    wait_for(lambda: h.control(cmd="pending")["pending"] == 1)
    h.control(cmd="bridge", on=False)
    thread.join(10)
    check("bridge off while waiting", "scope_changed" in text_of(result["body"]["result"]), result)
    h.control(cmd="bridge", on=True)
    c.close()


def run_auth_lockout(h):
    # Over 120 failed authentications a minute: unauthenticated requests get
    # 429 and a closed connection; valid tokens are never affected.
    ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
    statuses = []
    for _ in range(125):
        statuses.append(Client(h, "ekb_mcp_v1_" + "1" * 64).raw(body=ping)[0])
    check("lockout 429", statuses[-1] == 429 and statuses[0] == 401, statuses[-5:])
    status, headers, _, _ = Client(h).raw(body=ping)
    check("missing token locked out", status == 429 and "Retry-After" in headers, status)
    status, _, _, _ = Client(h, h.token("agent")).legacy("ping")
    check("valid token unaffected", status == 200, status)
    unauthorized = [r for r in h.activity() if r["outcome"] == "unauthorized"]
    check("failed auth coalesced", 1 <= len(unauthorized) <= 2, len(unauthorized))
    counters = h.control(cmd="counters")
    check("counters", counters["authFailures"] >= 125 and counters["requests"] > 125, counters)


def wait_for(condition, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


if __name__ == "__main__":
    with open(sys.argv[2]) as handle:
        _contract = json.load(handle)
    _shared = {k: v for k, v in _contract["$defs"].items() if k != "$comment"}
    CATALOG = {t["name"]: inline(t, _shared) for t in _contract["tools"]}
    main()
