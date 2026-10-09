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
        self.remote_token = first.get("remoteToken")
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
        bit = {"read": 1, "get": 1, "create": 2, "update": 4, "delete": 8, "complete": 16}[verb]
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
        run_plan03_writes(h)
        run_limits(h)
    finally:
        h.close()

    a = Harness(harness_binary, approval="none")
    try:
        run_approvals(a)
    finally:
        a.close()

    q = Harness(harness_binary, approval="none")
    try:
        run_access_requests(q)
    finally:
        q.close()

    t = Harness(harness_binary)
    try:
        run_auth_lockout(t)
    finally:
        t.close()

    r = Harness(harness_binary)
    try:
        run_remote(r, catalog)
    finally:
        r.close()

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
    check("initialize serverInfo", result["serverInfo"]["name"] == "ek-bridge" and
          result["serverInfo"]["title"] == "EK Bridge", result)
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
    check("A.1 visible tools", names == ["list_collections", "read_events", "get_event", "create_event",
                                         "read_reminders", "get_reminder", "create_reminder",
                                         "complete_reminder"], names)
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
    check("A.1 event", {k: event[k] for k in ["id", "version", "title", "start", "end", "all_day", "recurring",
                                               "time_zone", "floating", "occurrence_start", "recurrence",
                                               "editable", "notes_preview", "has_notes", "availability"]} == {
        "id": "EV1", "version": "1791200000.123456", "title": "Design review",
        "start": "2026-10-06T14:00:00+00:00", "end": "2026-10-06T15:00:00+00:00", "all_day": False,
        "recurring": False, "time_zone": "GMT", "floating": False, "occurrence_start": None, "recurrence": None,
        "editable": {"fields": True, "times": True, "recurrence": True, "reason": None},
        "notes_preview": None, "has_notes": False, "availability": "busy"}, event)
    check("read_events page", result["structuredContent"]["truncated"] is False and
          result["structuredContent"]["next_cursor"] is None and len(result["structuredContent"]["events"]) == 3)
    weekly = result["structuredContent"]["events"][2]
    check("recurring occurrence row", weekly["occurrence_start"] == "2026-10-06T18:00:00+02:00" and
          weekly["start"] == "2026-10-06T18:00:00+02:00" and weekly["recurrence"]["summary"] == "Weekly on Tuesday"
          and weekly["alarms"] == [{"minutes_before": 10}] and weekly["structured_location"]["radius_m"] == 50
          and weekly["notes_preview"] == "Agenda: roadmap" and "attendees" not in weekly, weekly)
    check("text mirrors structured", json.loads(text_of(result)) == result["structuredContent"])
    errors = validate(result["structuredContent"], catalog["read_events"]["outputSchema"])
    check("read_events schema", not errors, errors)
    allday = result["structuredContent"]["events"][1]
    check("all-day row", allday.get("start_date") == "2026-10-06" and allday.get("end_date") == "2026-10-06"
          and allday["editable"]["times"] is True, allday)

    # Plan 03 reads: paging, get_event with attendees, get_reminder with notes.
    args = {"calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00-04:00", "end": "2026-10-07T00:00:00-04:00"}
    _, body = c.call("read_events", {**args, "limit": 2})
    page = body["result"]["structuredContent"]
    check("first page", [e["id"] for e in page["events"]] == ["EV1", "EV2"] and page["truncated"] is True
          and page["next_cursor"] == "v1:1791259200:0:EV2", page)
    _, body = c.call("read_events", {**args, "limit": 2, "cursor": page["next_cursor"]})
    rest = body["result"]["structuredContent"]
    check("second page", [e["id"] for e in rest["events"]] == ["EV3"] and rest["next_cursor"] is None, rest)
    _, body = c.call("read_events", {**args, "cursor": "page 2"})
    check("bad cursor", body["result"]["isError"] and "cursor: expected next_cursor" in text_of(body["result"]), body)
    status, body = c.call("get_event", {"calendar_id": "CAL-WORK", "event_id": "EV3",
                                        "occurrence_start": "2026-10-06T18:00:00+02:00"})
    full = body["result"].get("structuredContent", {"event": {}})
    check("get_event", status == 200 and full["event"]["notes"] == "Agenda: roadmap" and
          full["event"]["attendees"][0]["email"] == "sam@example.com" and full["event"]["organizer"]["is_you"],
          body)
    errors = validate(full, catalog["get_event"]["outputSchema"])
    check("get_event schema", not errors, errors)
    _, body = c.call("get_event", {"calendar_id": "CAL-WORK", "event_id": "EV3",
                                   "occurrence_start": "2026-10-13T18:00:00+02:00"})
    check("get_event other occurrence", body["result"]["isError"] and
          text_of(body["result"]).endswith("(code: occurrence_not_found)"), body)
    status, body = c.call("get_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1"})
    got = body["result"]["structuredContent"]
    check("get_reminder", status == 200 and got["reminder"]["notes"] == "Oat, not almond." and
          not validate(got, catalog["get_reminder"]["outputSchema"]), body)

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
    check("discover names the client", result["_meta"]["io.github.bereciartua.ekbridge/client"]["name"] == "agent", result)
    check("modern serverInfo", result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "ek-bridge")
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
          headers.get("WWW-Authenticate") == 'Bearer realm="EK Bridge"', (status, headers))
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
    run_hardening(h)
    c.close()


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout
    return int(out.strip() or 0)


def run_hardening(h):
    # A client that pipelines without reading replies can't grow memory:
    # the server stops reading while a few requests wait.
    before = rss_kb(h.proc.pid)
    raw = socket.create_connection(("127.0.0.1", h.port))
    raw.setblocking(False)
    chunk = b"GET /x HTTP/1.1\r\nHost: a\r\n\r\n" * 2000
    sent, deadline = 0, time.time() + 3
    while time.time() < deadline:
        try:
            sent += raw.send(chunk)
        except BlockingIOError:
            time.sleep(0.01)
        except (BrokenPipeError, ConnectionResetError):
            break  # The server may drop a client that floods it; also bounded.
    grown = rss_kb(h.proc.pid) - before
    raw.close()
    check("pipelined flood is bounded", grown < 50_000, f"sent {sent} bytes, RSS grew {grown} KB")
    # A trickle of one byte every 3 s doesn't extend the 10 s header deadline.
    raw = socket.create_connection(("127.0.0.1", h.port))
    started = time.time()
    data = b""
    for byte in b"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n":
        try:
            raw.sendall(bytes([byte]))
        except OSError:
            break
        raw.settimeout(3)
        try:
            data = raw.recv(1024)
            if data:
                break
        except socket.timeout:
            pass
    elapsed = time.time() - started
    check("trickle cut off at 10 s", data.startswith(b"HTTP/1.1 408") and elapsed < 14, (data[:30], elapsed))
    raw.close()
    # A malformed request pipelined behind a good one is answered after it.
    raw = socket.create_connection(("127.0.0.1", h.port))
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"}).encode()
    good = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{h.port}\r\nContent-Type: application/json\r\n"
            f"Authorization: Bearer {h.token('agent')}\r\nContent-Length: {len(body)}\r\n\r\n").encode() + body
    raw.sendall(good + b"BROKEN\r\n\r\n")
    raw.settimeout(5)
    data = b""
    try:
        while b"HTTP/1.1 400" not in data:
            more = raw.recv(65536)
            if not more:
                break
            data += more
    except socket.timeout:
        pass
    check("errors answered in order", data.startswith(b"HTTP/1.1 200") and b"HTTP/1.1 400" in data, data[:60])
    raw.close()
    # A second instance that can't bind leaves the running one's endpoint file alone.
    endpoint = os.path.join(h.dir, "mcp-endpoint.json")
    second = subprocess.run([HARNESS], env=dict(os.environ, EVENTKIT_MCP_TEST_DIR=h.dir,
                                                EVENTKIT_MCP_TEST_PORT=str(h.port)),
                            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=20)
    with open(endpoint) as f:
        owner = json.load(f)["pid"]
    check("second instance keeps the endpoint file", second.returncode != 0 and owner == h.proc.pid,
          (second.returncode, owner))


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
          and "all_day" in event.get("verified", []), event)
    timed = bodies[0]["result"]["structuredContent"]["event"]
    check("timed events keep the Mac's zone (F1)", timed["time_zone"] == "America/New_York" and
          timed["start"] == "2026-10-06T09:00:00-04:00", timed)
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
          "paused" in text_of(body["result"]), body)
    _, _, body, _ = c.legacy("tools/list")
    check("list while off", "result" in body and body["result"]["tools"], body)
    check("bridge_off recorded", h.activity()[0]["outcome"] == "error:bridge_off")
    h.control(cmd="bridge", on=True)
    _, body = c.call("list_collections", {})
    check("recovers without reconnect", body["result"]["isError"] is False, body)
    # Paused client: its token still authenticates and lists tools, but every
    # call is refused and recorded; resuming needs no reconnect or new token.
    check("pause", h.control(cmd="pause", client="full", on=True)["ok"] is True)
    _, body = c.call("list_collections", {})
    check("client_paused text", body["result"]["isError"] is True and
          text_of(body["result"]).endswith("(code: client_paused)") and
          "paused" in text_of(body["result"]), body)
    _, _, body, _ = c.legacy("tools/list")
    check("list while paused", "result" in body and body["result"]["tools"], body)
    row = h.activity()[0]
    check("client_paused recorded", row["outcome"] == "error:client_paused" and row["via"] == "mcp", row)
    check("resume", h.control(cmd="pause", client="full", on=False)["ok"] is True)
    _, body = c.call("list_collections", {})
    check("resumes without reconnect", body["result"]["isError"] is False, body)
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


def run_plan03_writes(h):
    """Partial updates, nulls, spans, moves and series deletes, end to end."""
    c = Client(h, h.token("mover"))
    work = {"calendar_id": "CAL-WORK", "version": "1791200000.123456"}

    def ok(tool, arguments, name):
        status, body = c.call(tool, arguments)
        result = body.get("result", {})
        good = status == 200 and result.get("isError") is False
        check(name, good, body)
        if good:
            errors = validate(result["structuredContent"], inline_schema(tool))
            check(f"{name} schema", not errors, errors)
            return result["structuredContent"]
        return {}

    s = ok("update_event", {**work, "event_id": "EV1", "title": "Renamed"}, "partial update")
    check("only the title verified", s.get("event", {}).get("verified") == ["title"], s)
    s = ok("update_event", {**work, "event_id": "EV1", "notes": None, "location": None, "url": None,
                            "alarms": None, "availability": None, "structured_location": None}, "nulls clear")
    check("cleared fields verified", s.get("event", {}).get("verified") ==
          ["alarms", "availability", "location", "notes", "structured_location", "url"], s)
    s = ok("update_event", {**work, "event_id": "EV3", "occurrence_start": "2026-10-06T18:00:00+02:00",
                            "span": "future", "start": "2026-10-06T19:00:00+02:00",
                            "end": "2026-10-06T20:00:00+02:00"}, "span future")
    check("a future split may have a new ID", s.get("event", {}).get("id") == "EV3-future", s)
    s = ok("update_event", {**work, "event_id": "EV1", "target_calendar_id": "CAL-HOME"}, "move")
    check("move result names the new calendar", s.get("calendar_id") == "CAL-HOME", s)
    _, body = c.call("update_event", {**work, "event_id": "EV1", "target_calendar_id": "CAL-HOLIDAYS"})
    check("move needs Create on the destination", body["result"]["isError"] and
          text_of(body["result"]).endswith("(code: forbidden)"), body)
    s = ok("update_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000",
                               "target_list_id": "LIST-HOME"}, "reminder move")
    check("reminder move result", s.get("list_id") == "LIST-HOME", s)
    s = ok("update_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000",
                               "notes": "Oat, not almond.", "priority": "high"}, "reminder partial update")
    check("reminder fields verified", s.get("reminder", {}).get("verified") == ["notes", "priority"] and
          s.get("reminder", {}).get("priority") == "high", s)
    s = ok("create_event", {"calendar_id": "CAL-WORK", "title": "Weekly sync", "start": "2026-10-13T10:00",
                            "end": "2026-10-13T11:00", "time_zone": "Europe/Madrid", "notes": "Agenda",
                            "location": "Sala 2", "url": "https://meet.example.com/abc",
                            "alarms": [{"minutes_before": 15}],
                            "recurrence": {"frequency": "weekly", "weekdays": ["TU"]}}, "create with every field")
    check("saved in the requested zone", s.get("event", {}).get("time_zone") == "Europe/Madrid" and
          s["event"]["start"] == "2026-10-13T10:00:00+02:00", s)
    ok("delete_event", {**work, "event_id": "EV3", "occurrence_start": "2026-10-06T18:00:00+02:00", "span": "all"},
       "delete a series")
    ok("delete_reminder", {"list_id": "LIST-GROC", "reminder_id": "R1", "version": "1791200002.000000",
                           "scope": "series"}, "delete a repeating reminder")
    _, body = c.call("update_event", {**work, "event_id": "EV1"})
    check("nothing to change", body["result"]["isError"] and
          text_of(body["result"]).endswith("(code: nothing_to_change)"), body)
    _, body = c.call("create_event", {"calendar_id": "CAL-WORK", "title": "x", "start": "2026-10-06T09:00:00Z",
                                      "end": "2026-10-06T10:00:00Z", "url": "javascript:alert(1)"})
    check("scheme refused", text_of(body["result"]).endswith("(code: url_scheme_not_allowed)"), body)
    _, body = c.call("list_collections", {})
    calendars = {x["id"]: x for x in body["result"]["structuredContent"]["calendars"]}
    check("availabilities listed", calendars["CAL-WORK"]["availabilities"] == ["busy", "free", "tentative"] and
          calendars["CAL-HOLIDAYS"]["availabilities"] == [], calendars)
    move_rows = [r for r in h.activity() if r["command"] == "update_event" and r.get("outcome") == "success"]
    check("a move is recorded on the source calendar", move_rows and move_rows[0]["targetID"] == "CAL-WORK",
          move_rows[:1])
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


def run_access_requests(h):
    """C04: a write one action short on a calendar it can read asks for access.
    The answer arrives within the agent's 55 s and counts as the approval."""
    c = Client(h, h.token("reader"))
    create = {"calendar_id": "CAL-WORK", "title": "Dentist",
              "start": "2026-10-06T09:00:00-04:00", "end": "2026-10-06T10:00:00-04:00"}
    reset = [{"resource": "calendar", "targetID": "CAL-WORK", "mask": 1}]
    for mode, ok, approval in [("allowOnce", True, "access_once"), ("allowAlways", True, "access_always"),
                               ("notNow", False, "access_denied"), ("timeout", False, "access_timeout")]:
        h.control(cmd="grants", client="reader", grants=reset)
        h.control(cmd="access", mode=mode)
        started = time.monotonic()
        _, body = c.call("create_event", create)
        elapsed = time.monotonic() - started
        result = body["result"]
        check(f"access {mode} answers in time", elapsed < 55, elapsed)
        check(f"access {mode} result", result["isError"] is (not ok), result)
        row = h.activity()[0]
        check(f"access {mode} recorded", row.get("approval") == approval and
              row["outcome"] == ("success" if ok else "forbidden"), row)
        if not ok:
            check(f"access {mode} agent text", text_of(result) ==
                  "Not allowed: the user didn't allow this agent to create events in that calendar. "
                  "Don't retry unless the user asks you to. (code: forbidden)", result)
    asked = h.control(cmd="access", mode="refuse")["asked"]
    check("access asked four times", asked == 4, asked)
    # Throttled or ineligible: refused as before, with the usual text.
    h.control(cmd="grants", client="reader", grants=reset)
    _, body = c.call("create_event", create)
    check("access refused without a panel", "grant Create for this connection" in text_of(body["result"]), body)
    # Reads never ask.
    h.control(cmd="access", mode="allowOnce")
    _, body = c.call("read_reminders", {"list_id": "LIST-GROC"})
    check("reads never ask", body["result"]["isError"] is True and
          h.control(cmd="access", mode="refuse")["asked"] == 4, body)


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
          "Declined: the user declined this change in EK Bridge. Don't retry it unless the user asks you to. "
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


SECRET = "q7Zk2vN4bXwP9sL1mT6hYa"
PREFIX = "/r/" + SECRET
REMOTE_HOST = "remote.test"


class Remote(Client):
    """A client of the Remote Access port, as a tunnel would forward it."""

    def __init__(self, harness, port, token=None, host=REMOTE_HOST, forwarded="203.0.113.7"):
        self.h = harness
        self.token = token
        self.host = host
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        self.next_id = 1
        self.forwarded = forwarded

    def raw(self, method="POST", path=PREFIX + "/mcp", body=b"", headers=None, auth=True,
            content_type="application/json"):
        all_headers = {"X-Forwarded-For": self.forwarded, "Tailscale-Funnel-Request": "?1"}
        all_headers.update(headers or {})
        return Client.raw(self, method, path, body, all_headers, auth, content_type)


def form(fields):
    from urllib.parse import urlencode
    return urlencode(fields).encode()


def run_remote(h, catalog):
    h.control(cmd="remote_start")
    wait_for(lambda: h.control(cmd="remote_port")["port"] is not None)
    port = h.control(cmd="remote_port")["port"]
    token = h.remote_token
    ping = {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}

    # The secret path comes first: anything else is 404, even with a bad Host.
    for path in ["/", "/mcp", "/r/wrong/mcp", "/r/" + SECRET + "x/mcp", "/.well-known/oauth-authorization-server",
                 "/.well-known/oauth-protected-resource", PREFIX + "/other"]:
        status, _, _, _ = Remote(h, port, token, host="evil.example").raw(path=path, body=ping)
        check(f"remote 404 {path}", status == 404, status)
    status, _, _, _ = Remote(h, port, token, host="evil.example").raw(body=ping)
    check("remote 421 host", status == 421, status)
    for host in [REMOTE_HOST, f"127.0.0.1:{port}", f"localhost:{port}"]:
        status, _, body, _ = Remote(h, port, token, host=host).raw(body=ping)
        check(f"remote host {host}", status == 200 and "result" in body, (status, body))
    status, _, _, _ = Remote(h, port, token).raw(body=ping, headers={"Origin": "https://evil.example"})
    check("remote 403 origin", status == 403, status)

    # Credentials stay apart: local tokens are refused remotely and vice versa.
    status, headers, body, _ = Remote(h, port, h.token("cloud")).raw(body=ping)
    challenge = headers.get("WWW-Authenticate", "")
    check("local token refused remotely", status == 401 and
          f'resource_metadata="https://{REMOTE_HOST}/.well-known/oauth-protected-resource{PREFIX}/mcp"' in challenge,
          (status, challenge))
    status, _, _, _ = Client(h, token).raw(body=ping)
    check("remote token refused locally", status == 401, status)

    # A remote call: same pipeline, recorded as remote.
    remote = Remote(h, port, token)
    _, _, body, _ = remote.raw(body=ping)
    names = [t["name"] for t in body["result"]["tools"]]
    check("remote tools follow grants", names == ["list_collections", "read_events", "get_event", "create_event",
                                                  "read_reminders", "get_reminder", "create_reminder"], names)
    status, body = remote.call("read_events", {"calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00Z",
                                               "end": "2026-10-07T00:00:00Z"})
    check("remote read", status == 200 and body["result"]["isError"] is False, body)
    row = h.activity()[0]
    check("activity via remote", row["via"] == "remote" and row["outcome"] == "success", row)
    # Pausing refuses remote calls too, without touching the remote token.
    h.control(cmd="pause", client="cloud", on=True)
    status, body = remote.call("list_collections", {})
    check("remote paused", status == 200 and "client_paused" in text_of(body["result"]), body)
    check("remote paused row", h.activity()[0]["via"] == "remote" and
          h.activity()[0]["outcome"] == "error:client_paused", h.activity()[0])
    h.control(cmd="pause", client="cloud", on=False)
    status, body = remote.call("list_collections", {})
    check("remote resumed", status == 200 and body["result"]["isError"] is False, body)

    # Cloud access off: the remote token stops working at once.
    h.control(cmd="set_cloud", client="cloud", on=False)
    status, _, _, _ = Remote(h, port, token).raw(body=ping)
    check("cloud access off refuses", status == 401, status)
    h.control(cmd="set_cloud", client="cloud", on=True)
    token = h.control(cmd="issue_remote_token", client="cloud")["token"]
    remote = Remote(h, port, token)
    status, _, _, _ = remote.raw(body=ping)
    check("new remote token works", status == 200, status)

    # Health: only for a nonce the app issued in the last 30 s, once.
    status, _, _, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=madeup", body=b"")
    check("health unknown nonce 404", status == 404, status)
    nonce = h.control(cmd="nonce")["nonce"]
    status, _, body, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
    check("health ok", status == 200 and body["nonce"] == nonce and body["tunnel"] == "Tailscale Funnel", body)
    status, _, _, _ = Remote(h, port).raw(method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
    check("health nonce single use", status == 404, status)

    # A candidate address being tested (Switch Tunnel…, plan 08 T05): its Host
    # gets the health check only, never MCP, OAuth or discovery, and only while set.
    candidate = "quiet-river-1234.trycloudflare.com"
    def candidate_health():
        nonce = h.control(cmd="nonce")["nonce"]
        status, _, body, _ = Remote(h, port, host=candidate).raw(
            method="GET", path=PREFIX + "/health?nonce=" + nonce, body=b"")
        return status, body, nonce
    check("candidate host 421 before the test", candidate_health()[0] == 421)
    h.control(cmd="remote_candidate", origin="https://" + candidate)
    status, body, nonce = candidate_health()
    check("candidate health", status == 200 and body["nonce"] == nonce, (status, body))
    for method, path in [("POST", PREFIX + "/mcp"), ("GET", PREFIX + "/oauth/authorize?client_id=x"),
                         ("POST", PREFIX + "/oauth/token"), ("POST", PREFIX + "/oauth/register"),
                         ("GET", "/.well-known/oauth-protected-resource" + PREFIX + "/mcp"),
                         ("GET", "/.well-known/oauth-authorization-server" + PREFIX)]:
        status, _, _, _ = Remote(h, port, token, host=candidate).raw(method=method, path=path, body=json.dumps(ping).encode())
        check(f"candidate host 421 {method} {path}", status == 421, status)
    status, _, body, _ = Remote(h, port, token).raw(body=ping)
    check("the address in use keeps working", status == 200 and "result" in body, status)
    h.control(cmd="remote_candidate", origin=None)
    check("candidate host 421 after", candidate_health()[0] == 421)

    run_oauth(h, port, catalog)

    # Remote limits are stricter: 15 calls in a burst.
    limited = None
    for _ in range(30):
        _, body = remote.call("list_collections", {})
        if body["result"]["isError"]:
            limited = text_of(body["result"])
            break
    check("remote rate limit", limited is not None and "rate_limited" in limited, limited)

    # Failed authentication locks out one forwarded address, not others.
    statuses = [Remote(h, port, "ekb_mcpr_v1_" + "0" * 64, forwarded="198.51.100.9").raw(body=ping)[0]
                for _ in range(32)]
    check("remote lockout per address", statuses[0] == 401 and statuses[-1] == 429, statuses[-3:])
    status, _, _, _ = Remote(h, port, "ekb_mcpr_v1_" + "0" * 64, forwarded="198.51.100.10").raw(body=ping)
    check("other address unaffected", status == 401, status)
    # A valid credential is never locked out, even from a locked address (anyone can claim one).
    status, _, _, _ = Remote(h, port, token, forwarded="198.51.100.9").raw(body=ping)
    check("valid token bypasses lockout", status == 200, status)
    status, _, _, _ = Remote(h, port, None, forwarded="198.51.100.9").raw(body=ping, auth=False)
    check("no token from locked address", status == 429, status)
    # Only the last X-Forwarded-For entry (the one the tunnel appended) counts.
    status, _, _, _ = Remote(h, port, "ekb_mcpr_v1_" + "0" * 64,
                             forwarded="198.51.100.9, 198.51.100.11").raw(body=ping)
    check("spoofed leading X-Forwarded-For ignored", status == 401, status)


def status_url(page):
    """The page polls `authorize/status?request=<id>` relative to itself."""
    import re
    found = re.search(rb'data-request="([0-9A-Za-z-]+)"', page)
    return PREFIX + "/oauth/authorize/status?request=" + found.group(1).decode() if found else None


def run_oauth(h, port, catalog):
    import base64 as b64
    import hashlib
    import re
    from urllib.parse import urlparse, parse_qs, urlencode
    resource = f"https://{REMOTE_HOST}{PREFIX}/mcp"
    issuer = f"https://{REMOTE_HOST}{PREFIX}"
    o = Remote(h, port)
    status, _, prm, _ = o.raw(method="GET", path=f"/.well-known/oauth-protected-resource{PREFIX}/mcp", body=b"")
    check("PRM", status == 200 and prm["resource"] == resource and prm["authorization_servers"] == [issuer], prm)
    status, _, asm, _ = o.raw(method="GET", path=f"/.well-known/oauth-authorization-server{PREFIX}", body=b"")
    check("AS metadata", status == 200 and asm["issuer"] == issuer and
          asm["code_challenge_methods_supported"] == ["S256"], asm)
    callback = "https://claude.ai/api/mcp/auth_callback"
    register = lambda: o.raw(path=PREFIX + "/oauth/register", body={"redirect_uris": [callback],
                                                                      "client_name": "claude.ai"})
    status, _, body, _ = register()
    check("DCR needs pairing", status == 403, (status, body))
    h.control(cmd="open_pairing", client="cloud")
    status, _, reg, _ = register()
    check("DCR", status == 201 and reg["client_id"].startswith("dcr_"), (status, reg))
    verifier = "v" * 64
    challenge = b64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    query = urlencode({"response_type": "code", "client_id": reg["client_id"], "redirect_uri": callback,
                       "code_challenge": challenge, "code_challenge_method": "S256", "state": "xyz",
                       "resource": resource})
    status, headers, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query, body=b"",
                                     content_type=None)
    pending = h.control(cmd="pairings")["pending"]
    check("authorize page", status == 200 and len(pending) == 1 and
          pending[0]["code"].replace(" ", "").encode() in page.replace(b" ", b""), (status, pending))
    check("authorize page headers", "DENY" in headers.get("X-Frame-Options", "") and
          "no-store" in headers.get("Cache-Control", ""), headers)
    status_path = status_url(page)
    check("status URL in page", status_path is not None, page[:200])
    h.control(cmd="answer_pairing", allow=True)
    status, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    redirect = body.get("redirect", "") if isinstance(body, dict) else ""
    params = parse_qs(urlparse(redirect).query)
    check("redirect with code", redirect.startswith(callback) and params.get("state") == ["xyz"] and
          params.get("iss") == [issuer] and "code" in params, body)
    code = params.get("code", [""])[0]
    token_request = lambda fields: o.raw(path=PREFIX + "/oauth/token", body=form(fields),
                                         content_type="application/x-www-form-urlencoded")
    status, _, bad, _ = token_request({"grant_type": "authorization_code", "code": code, "client_id": reg["client_id"],
                                       "redirect_uri": callback, "code_verifier": "w" * 64})
    check("PKCE mismatch", status == 400 and bad["error"] == "invalid_grant", bad)
    # The code was spent by the failed attempt; start again.
    h.control(cmd="open_pairing", client="cloud")
    status, _, _, page = o.raw(method="GET", path=PREFIX + "/oauth/authorize?" + query, body=b"", content_type=None)
    status_path = status_url(page)
    h.control(cmd="answer_pairing", allow=True)
    _, _, body, _ = o.raw(method="GET", path=status_path, body=b"", content_type=None)
    code = parse_qs(urlparse(body["redirect"]).query)["code"][0]
    status, _, tokens, _ = token_request({"grant_type": "authorization_code", "code": code,
                                          "client_id": reg["client_id"], "redirect_uri": callback,
                                          "code_verifier": verifier, "resource": resource})
    check("token exchange", status == 200 and tokens["access_token"].startswith("ekb_oat_v1_") and
          tokens["token_type"].lower() == "bearer", tokens)
    check("connection listed", h.control(cmd="oauth_connections", client="cloud")["count"] == 1)
    m = Remote(h, port, tokens["access_token"])
    status, body = m.call("list_collections", {})
    check("MCP with OAuth token", status == 200 and body["result"]["isError"] is False, body)
    # Refresh rotates; presenting the old refresh token again revokes the connection.
    status, _, rotated, _ = token_request({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                           "client_id": reg["client_id"]})
    check("refresh", status == 200 and rotated["refresh_token"] != tokens["refresh_token"], rotated)
    status, _, _, _ = Remote(h, port, rotated["access_token"]).raw(body={"jsonrpc": "2.0", "id": 1,
                                                                        "method": "tools/list"})
    check("rotated access works", status == 200, status)
    status, _, reuse, _ = token_request({"grant_type": "refresh_token", "refresh_token": tokens["refresh_token"],
                                         "client_id": reg["client_id"]})
    check("refresh reuse detected", status == 400 and reuse["error"] == "invalid_grant", reuse)
    status, _, _, _ = Remote(h, port, rotated["access_token"]).raw(body={"jsonrpc": "2.0", "id": 1,
                                                                        "method": "tools/list"})
    check("reuse revoked the connection", status == 401, status)
    check("no connections left", h.control(cmd="oauth_connections", client="cloud")["count"] == 0)


def wait_for(condition, seconds=10):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return False


if __name__ == "__main__":
    HARNESS = sys.argv[1]
    with open(sys.argv[2]) as handle:
        _contract = json.load(handle)
    _shared = {k: v for k, v in _contract["$defs"].items() if k != "$comment"}
    CATALOG = {t["name"]: inline(t, _shared) for t in _contract["tools"]}
    main()
