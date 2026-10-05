#!/usr/bin/env python3
"""Tests for bridge-mcp (the stdio launcher) against the real MCP server.

Usage: launcher_test.py BRIDGE_MCP_TEST_BINARY MCP_SERVER_TEST_BINARY

Both binaries must be built with -D EVENTKIT_MCP_TEST. The harness
(Tests/MCPServerHarness.swift) serves on an ephemeral loopback port from a
fresh private temp folder, and the launcher is pointed at that folder through
EVENTKIT_TEST_SUPPORT_DIR. Nothing touches the real app, registry or tokens.
"""

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

PRODUCT = "EventKit Bridge"
NOT_RUNNING = (f"{PRODUCT} isn't running, or its MCP server is off. "
               f"Open {PRODUCT} and turn on Settings ▸ MCP Server.")
SQUATTER = (f"Another program is using {PRODUCT}'s port. "
            f"Open {PRODUCT} and check Settings ▸ MCP Server.")
BAD_ENDPOINT = f"{PRODUCT}'s endpoint file isn't valid, so nothing was sent. Quit and reopen {PRODUCT}."
REJECTED = (f"{PRODUCT} doesn't recognize this client's token. "
            f"Open the client in {PRODUCT} and check MCP access.")
MODERN = "2026-07-28"


def lines_to_queue(stream, sink):
    for line in iter(stream.readline, b""):
        sink.put(line.decode())
    sink.put(None)


class Harness:
    """The MCP server harness, driven over its stdin control channel."""

    def __init__(self, binary: Path, directory: Path, log: Path):
        env = {k: v for k, v in os.environ.items() if not k.startswith("EVENTKIT_")}
        env["EVENTKIT_MCP_TEST_DIR"] = str(directory)
        self.directory = directory
        self.log = open(log, "wb")
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, env=env)
        self.lines = queue.Queue()
        threading.Thread(target=lines_to_queue, args=(self.process.stdout, self.lines),
                         daemon=True).start()
        first = self.lines.get(timeout=15)
        if first is None:
            raise RuntimeError(f"harness exited; see {log}")
        hello = json.loads(first)
        self.port = hello["port"]
        self.clients = hello["clients"]
        self.pid = self.process.pid

    def control(self, **command):
        self.process.stdin.write((json.dumps(command) + "\n").encode())
        self.process.stdin.flush()
        return json.loads(self.lines.get(timeout=10))

    def requests(self):
        return self.control(cmd="counters")["requests"]

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.log.close()


class Relay:
    """One bridge-mcp stdio session."""

    def __init__(self, binary: Path, args, env):
        self.process = subprocess.Popen([str(binary), *args], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        self.out, self.err = queue.Queue(), queue.Queue()
        for stream, sink in ((self.process.stdout, self.out), (self.process.stderr, self.err)):
            threading.Thread(target=lines_to_queue, args=(stream, sink), daemon=True).start()
        self.stderr = []

    def send(self, message):
        line = message if isinstance(message, str) else json.dumps(message)
        self.process.stdin.write((line + "\n").encode())
        self.process.stdin.flush()

    def recv(self, timeout=10.0):
        """The next stdout line as JSON, or None when nothing arrives in time."""
        try:
            line = self.out.get(timeout=timeout)
        except queue.Empty:
            return None
        if line is None:
            return None
        if not line.endswith("\n") or "\n" in line[:-1]:
            raise AssertionError(f"reply isn't exactly one line: {line!r}")
        return json.loads(line)

    def call(self, message, timeout=10.0):
        self.send(message)
        return self.recv(timeout)

    def close(self, timeout=10.0):
        """Closes stdin (EOF) and returns the exit code."""
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            code = self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            self.process.kill()
            code = "timeout"
        self.drain()
        return code

    def drain(self):
        while True:
            try:
                line = self.err.get(timeout=0.5)
            except queue.Empty:
                return
            if line is None:
                return
            self.stderr.append(line.rstrip("\n"))


def request(id_, method, params=None):
    message = {"jsonrpc": "2.0", "id": id_, "method": method}
    if params is not None:
        message["params"] = params
    return message


def call_tool(id_, name, arguments, modern=False):
    params = {"name": name, "arguments": arguments}
    if modern:
        params["_meta"] = {"io.modelcontextprotocol/protocolVersion": MODERN,
                           "io.modelcontextprotocol/clientCapabilities": {},
                           "io.modelcontextprotocol/clientInfo": {"name": "launcher-test", "version": "1"}}
    return request(id_, "tools/call", params)


INITIALIZE = request(0, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                       "clientInfo": {"name": "launcher-test", "version": "1"}})


def main() -> int:
    launcher = Path(sys.argv[1]).resolve()
    harness_binary = Path(sys.argv[2]).resolve()
    tmp = Path(tempfile.mkdtemp(prefix="eventkit-launcher-test-"))
    support = tmp / "support"
    support.mkdir(mode=0o700)
    os.chmod(support, 0o700)
    failures, stderr_seen = [], []
    checks = 0
    harness = None
    relays = []

    def expect(name, condition, detail=""):
        nonlocal checks
        checks += 1
        if not condition:
            failures.append(f"{name}: {detail}")

    def env(directory=support, server=harness_binary, **extra):
        values = {k: v for k, v in os.environ.items()
                  if not k.startswith(("EVENTKIT_", "CLAUDE_CODE_"))}
        values["EVENTKIT_TEST_SUPPORT_DIR"] = str(directory)
        if server is not None:
            values["EVENTKIT_MCP_TEST_SERVER_PATH"] = str(server)
        values.update({k: str(v) for k, v in extra.items()})
        return values

    def relay(args, **env_options):
        session = Relay(launcher, args, env(**env_options))
        relays.append(session)
        return session

    def finish(session):
        code = session.close()
        stderr_seen.extend(session.stderr)
        return code

    def run(args, **env_options):
        process = subprocess.run([str(launcher), *args], capture_output=True, timeout=30,
                                 env=env(**env_options), stdin=subprocess.DEVNULL)
        err = process.stderr.decode()
        stderr_seen.extend(err.splitlines())
        return process.returncode, process.stdout.decode(), err

    def error_of(reply):
        return (reply or {}).get("error") or {}

    def write_private(path: Path, text: str, mode=0o600):
        path.write_text(text)
        os.chmod(path, mode)
        return path

    def fake_support(name, endpoint):
        """A support folder with the agent's token and a hand-written endpoint file."""
        directory = tmp / name
        (directory / "client-credentials").mkdir(parents=True, mode=0o700)
        os.chmod(directory, 0o700)
        source = support / "client-credentials" / f"{agent_id}.mcp-token"
        write_private(directory / "client-credentials" / f"{agent_id}.mcp-token", source.read_text())
        write_private(directory / "mcp-endpoint.json", json.dumps(endpoint))
        return directory

    try:
        harness = Harness(harness_binary, support, tmp / "harness.log")
        port, clients = harness.port, harness.clients
        url = f"http://127.0.0.1:{port}/mcp"
        agent_id, full_id = clients["agent"]["id"], clients["full"]["id"]
        agent_token = (support / "client-credentials" / f"{agent_id}.mcp-token").read_text()

        # Legacy handshake, list and calls; notifications produce no output.
        session = relay(["--client", agent_id])
        reply = session.call(INITIALIZE)
        expect("initialize", (reply or {}).get("id") == 0 and
               reply["result"]["protocolVersion"] == "2025-11-25", f"{reply!r}")
        session.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        reply = session.call(request(1, "tools/list"))
        names = [t["name"] for t in (reply or {}).get("result", {}).get("tools", [])]
        expect("tools/list", "list_collections" in names and "read_events" in names, f"{names!r}")
        reply = session.call(call_tool(2, "list_collections", {}))
        result = (reply or {}).get("result", {})
        expect("list_collections", reply and reply["id"] == 2 and result.get("isError") is False and
               "calendars" in result.get("structuredContent", {}), f"{reply!r}"[:300])
        reply = session.call(call_tool("r-3", "read_events", {
            "calendar_id": "CAL-WORK", "start": "2026-10-06T00:00:00-04:00",
            "end": "2026-10-07T00:00:00-04:00"}))
        events = (reply or {}).get("result", {}).get("structuredContent", {}).get("events", [])
        expect("read_events with a string id", reply and reply["id"] == "r-3" and len(events) == 2,
               f"{reply!r}"[:300])
        # Modern request: MCP-Protocol-Version, Mcp-Method and Mcp-Name come
        # from the message, or the server answers 400 -32020.
        reply = session.call(call_tool(4, "read_reminders", {"list_id": "LIST-GROC"}, modern=True))
        expect("modern tools/call headers", (reply or {}).get("result", {}).get("resultType") == "complete",
               f"{reply!r}"[:300])
        reply = session.call(call_tool(5, "lïst_collections", {}, modern=True))
        expect("base64 Mcp-Name", error_of(reply).get("code") == -32602 and reply["id"] == 5,
               f"{reply!r}"[:300])
        reply = session.call(request(6, "resources/list", {"_meta": {
            "io.modelcontextprotocol/protocolVersion": MODERN,
            "io.modelcontextprotocol/clientCapabilities": {}}}))
        expect("modern unknown method (HTTP 404 body)", error_of(reply).get("code") == -32601 and
               reply["id"] == 6, f"{reply!r}")
        session.send("{not json")
        session.send("x" * ((1 << 20) + 1))
        session.send(json.dumps([request(7, "ping")]))
        reply = session.call(request(8, "ping"))
        expect("bad lines skipped, relay continues", reply == {"jsonrpc": "2.0", "id": 8, "result": {}},
               f"{reply!r}")
        expect("notifications and bad lines produce no output", session.recv(0.5) is None)
        code = finish(session)
        expect("EOF exits 0", code == 0, f"exit {code}")
        expect("bad lines logged", "bridge-mcp: skipped a line that isn't valid JSON." in session.stderr and
               "bridge-mcp: skipped a message longer than 1 MiB." in session.stderr and
               any("batches" in line for line in session.stderr), f"{session.stderr!r}")

        # Concurrent requests answer in completion order; cancellation drops
        # the reply and the server records `cancelled`.
        session = relay(["--client", full_id])
        session.send(call_tool(10, "create_reminder", {"list_id": "LIST-GROC", "title": "slow one"}))
        session.send(call_tool(11, "list_collections", {}))
        first, second = session.recv(), session.recv(5)
        expect("completion order", (first or {}).get("id") == 11 and (second or {}).get("id") == 10,
               f"{first!r} {second!r}"[:300])
        session.send(call_tool(12, "create_reminder", {"list_id": "LIST-GROC", "title": "slow cancel"}))
        time.sleep(0.3)
        session.send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                      "params": {"requestId": 12, "reason": "user"}})
        expect("cancelled request gets no reply", session.recv(3) is None)
        outcomes = []
        for _ in range(25):
            outcomes = [row["outcome"] for row in harness.control(cmd="activity")["activity"]
                        if row.get("command") == "create_reminder"]
            if "error:cancelled" in outcomes:
                break
            time.sleep(0.2)
        expect("activity records error:cancelled", "error:cancelled" in outcomes, f"{outcomes!r}")
        # EOF with a request in flight: its reply is still written.
        session.send(call_tool(13, "create_reminder", {"list_id": "LIST-GROC", "title": "slow at eof"}))
        time.sleep(0.2)
        started = time.time()
        code = finish(session)
        expect("EOF waits for in-flight replies", code == 0 and time.time() - started < 5.5, f"exit {code}")

        # 401 after a token reset: the launcher re-reads the file and retries.
        session = relay(["--client", agent_id])
        expect("before reset", (session.call(request(1, "tools/list")) or {}).get("result") is not None)
        expect("reset_token", harness.control(cmd="reset_token", client="agent")["ok"] is True)
        reply = session.call(request(2, "tools/list"))
        expect("401 → re-read token → success", (reply or {}).get("result") is not None, f"{reply!r}"[:200])
        finish(session)
        expect("token re-read logged", any("new token" in line for line in session.stderr),
               f"{session.stderr!r}")
        agent_token = (support / "client-credentials" / f"{agent_id}.mcp-token").read_text()

        stranger = write_private(tmp / "stranger.mcp-token", "ekb_mcp_v1_" + os.urandom(32).hex())
        session = relay(["--token-file", str(stranger)])
        reply = session.call(request(1, "tools/list"))
        expect("unknown token → -32001", error_of(reply) == {"code": -32001, "message": REJECTED} and
               reply["id"] == 1, f"{reply!r}")
        finish(session)

        # headers
        good = ["headers", "--client", agent_id, "--url", url]
        code, out, err = run(good)
        expect("headers prints the token", code == 0 and
               json.loads(out) == {"Authorization": "Bearer " + agent_token} and not err, f"{code} {err!r}")
        wrong = f"http://127.0.0.1:{port + 1}/mcp"
        code, out, err = run(["headers", "--client", agent_id, "--url", wrong])
        expect("headers refuses another URL", code == 3 and out == "{}\n" and
               err.startswith(f"bridge-mcp: the agent's URL {wrong} isn't the one"),
               f"{code} {out!r} {err!r}")
        code, out, _ = run(good, CLAUDE_CODE_MCP_SERVER_URL=wrong)
        expect("CLAUDE_CODE_MCP_SERVER_URL wins over --url", code == 3 and out == "{}\n", f"{code} {out!r}")
        code, out, _ = run(["headers", "--client", agent_id, "--url", wrong], CLAUDE_CODE_MCP_SERVER_URL=url)
        expect("CLAUDE_CODE_MCP_SERVER_URL accepted", code == 0 and "Bearer" in out, f"{code} {out!r}")
        code, out, err = run(["headers", "--client", agent_id])
        expect("headers without --url", code == 2 and out == "{}\n" and
               err == "bridge-mcp: error: missing --url. Run bridge-mcp --help.\n", f"{code} {err!r}")
        code, out, err = run(good, server=tmp / "impostor")
        expect("headers refuses an unverified listener", code == 3 and out == "{}\n" and
               "isn't the test server" in err, f"{code} {out!r} {err!r}")

        # check
        code, out, err = run(["check", "--client", agent_id])
        expect("check: all good", code == 0 and out == "" and
               f"EventKit Bridge MCP check for client {agent_id[:4]}…{agent_id[-4:]}" in err and
               '  ✓ token accepted: client "agent"' in err and "(mode 600)" in err and
               "  ✓ 6 tools available: list_collections" in err and "  ✓ the bridge is on" in err,
               f"{code} {err!r}")
        harness.control(cmd="bridge", on=False)
        code, _, err = run(["check", "--client", agent_id])
        expect("check: bridge off is a warning", code == 0 and
               "  ! the bridge is off: tool calls will be refused until it's turned on" in err,
               f"{code} {err!r}")
        harness.control(cmd="bridge", on=True)
        loose = write_private(tmp / "loose.mcp-token", agent_token, mode=0o644)
        code, _, err = run(["check", "--token-file", str(loose)])
        expect("check: unsafe token file → 4", code == 4 and
               f"  ✗ token file: {loose} can be read by other users (mode 644)." in err, f"{code} {err!r}")
        code, _, err = run(["check", "--token-file", str(stranger)])
        expect("check: rejected token → 1", code == 1 and "  ✗ token rejected" in err, f"{code} {err!r}")

        # Endpoint files that would send the token anywhere else are refused
        # before anything is sent.
        for name, endpoint in [
            ("lan", {"version": 1, "url": f"http://10.0.0.1:{port}/mcp", "port": port,
                     "pid": harness.pid, "startedAt": 0}),
            ("localhost", {"version": 1, "url": f"http://localhost:{port}/mcp", "port": port,
                           "pid": harness.pid, "startedAt": 0}),
            ("https", {"version": 1, "url": f"https://127.0.0.1:{port}/mcp", "port": port,
                       "pid": harness.pid, "startedAt": 0}),
            ("other path", {"version": 1, "url": f"http://127.0.0.1:{port}/steal", "port": port,
                            "pid": harness.pid, "startedAt": 0}),
        ]:
            directory = fake_support("endpoint-" + name.replace(" ", "-"), endpoint)
            before = harness.requests()
            session = relay(["--client", agent_id], directory=directory)
            reply = session.call(request(1, "tools/list"))
            finish(session)
            expect(f"endpoint {name}: refused", error_of(reply) == {"code": -32000, "message": BAD_ENDPOINT},
                   f"{reply!r}")
            expect(f"endpoint {name}: nothing sent", harness.requests() == before)
        code, _, err = run(["check", "--client", agent_id], directory=tmp / "endpoint-lan")
        expect("check: bad endpoint file → 3", code == 3 and "nothing was sent" in err, f"{code} {err!r}")

        # Listener verification (threat T9): no token unless the endpoint's pid
        # is the expected program and holds the listener.
        for name, options in [("wrong program", {"server": tmp / "impostor"}),
                              ("no expected program", {"server": None})]:
            before = harness.requests()
            session = relay(["--client", agent_id], **options)
            reply = session.call(request(1, "tools/list"))
            finish(session)
            expect(f"verification, {name}: -32000",
                   error_of(reply) == {"code": -32000, "message": SQUATTER}, f"{reply!r}")
            expect(f"verification, {name}: nothing sent", harness.requests() == before)
        free_port = port + 7 if port < 65_000 else port - 7
        directory = fake_support("not-listening", {
            "version": 1, "url": f"http://127.0.0.1:{free_port}/mcp", "port": free_port,
            "pid": harness.pid, "startedAt": 0})
        session = relay(["--client", agent_id], directory=directory)
        reply = session.call(request(1, "tools/list"))
        finish(session)
        expect("verification, pid not listening on the port", error_of(reply).get("message") == SQUATTER and
               any(f"isn't listening on 127.0.0.1:{free_port}" in line for line in session.stderr),
               f"{reply!r} {session.stderr!r}")
        session = relay(["--client", agent_id], server="/usr/bin/true")
        first = session.call(request(1, "tools/list"))
        second = session.call(request(2, "ping"))
        expect("refused, then still refused", error_of(first).get("code") == error_of(second).get("code")
               == -32000, f"{first!r} {second!r}")
        finish(session)

        # Not running: the server stops after a successful first request (so
        # the startup grace is over) and the endpoint file goes away.
        session = relay(["--client", agent_id])
        expect("served before stop", (session.call(request(1, "ping")) or {}).get("result") == {})
        harness.control(cmd="stop")
        expect("endpoint file removed", not (support / "mcp-endpoint.json").exists())
        reply = session.call(request(2, "tools/list"), timeout=3)
        expect("not running → -32000", error_of(reply) == {"code": -32000, "message": NOT_RUNNING} and
               reply["id"] == 2, f"{reply!r}")
        session.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        expect("not running: notifications stay silent", session.recv(0.5) is None)
        finish(session)
        code, out, err = run(["check", "--client", agent_id])
        expect("check: server stopped → 3", code == 3 and "  ✗ EventKit Bridge isn't running" in err,
               f"{code} {err!r}")

        # Startup grace: the first request waits for the server to appear.
        session = relay(["--client", agent_id])
        session.send(INITIALIZE)
        time.sleep(1)
        harness.control(cmd="start")
        started = time.time()
        reply = session.recv(6)
        expect("startup grace", (reply or {}).get("result", {}).get("protocolVersion") == "2025-11-25" and
               time.time() - started < 1.5, f"{reply!r}"[:200])
        finish(session)

        # A stale endpoint file after a crash (pid gone) is "not running".
        dead = subprocess.Popen(["/usr/bin/true"])
        dead.wait()
        directory = fake_support("stale", {"version": 1, "url": url, "port": port, "pid": dead.pid,
                                           "startedAt": 0})
        before = harness.requests()
        session = relay(["--client", agent_id], directory=directory)
        reply = session.call(request(1, "ping"), timeout=8)
        finish(session)
        expect("stale endpoint (pid gone) → not running after grace",
               error_of(reply).get("message") == NOT_RUNNING and harness.requests() == before, f"{reply!r}")

        # Usage and token file errors.
        missing = support / "client-credentials" / f"{uuid.uuid4()}.mcp-token"
        link = tmp / "link.mcp-token"
        link.symlink_to(support / "client-credentials" / f"{agent_id}.mcp-token")
        junk = write_private(tmp / "junk.mcp-token", "ekb_mcp_v1_NOPE")
        big = write_private(tmp / "big.mcp-token", "x" * 200)
        newline = write_private(tmp / "newline.mcp-token", agent_token + "\n")
        not_token = f"bridge-mcp: error: {{}} isn't an MCP token file for {PRODUCT}.\n"
        table = [
            ("no arguments", [], 2, "bridge-mcp: error: missing --client or --token-file. "
             "Run bridge-mcp --help.\n"),
            ("client name", ["--client", "Claude Code"], 2, "bridge-mcp: error: --client takes the "
             f"client's ID (a UUID), not its name. Copy the setup from the client's page in {PRODUCT}.\n"),
            ("unknown option", ["--client", agent_id, "--verbose"], 2,
             'bridge-mcp: error: unknown option "--verbose". Run bridge-mcp --help.\n'),
            ("unknown command", ["chek", "--client", agent_id], 2,
             'bridge-mcp: error: unknown command "chek". Run bridge-mcp --help.\n'),
            ("both credentials", ["--client", agent_id, "--token-file", str(junk)], 2,
             "bridge-mcp: error: use --client or --token-file, not both.\n"),
            ("--url without headers", ["--client", agent_id, "--url", url], 2,
             "bridge-mcp: error: --url is only for bridge-mcp headers.\n"),
            ("option without value", ["--client"], 2,
             'bridge-mcp: error: option "--client" needs a value. Run bridge-mcp --help.\n'),
            ("stray argument", ["check", "--client", agent_id, "extra"], 2,
             'bridge-mcp: error: unexpected argument "extra". Run bridge-mcp --help.\n'),
            ("token file mode 644", ["--token-file", str(loose)], 4,
             f"bridge-mcp: error: {loose} can be read by other users (mode 644). Fix: chmod 600 {loose}\n"),
            ("missing token file", ["--client", missing.stem], 4,
             f"bridge-mcp: error: token file not found: {missing}\n"),
            ("symlinked token file", ["--token-file", str(link)], 4,
             f"bridge-mcp: error: {link} is a symbolic link.\n"),
            ("malformed token", ["--token-file", str(junk)], 4, not_token.format(junk)),
            ("oversized token file", ["--token-file", str(big)], 4, not_token.format(big)),
            ("token with a newline", ["--token-file", str(newline)], 4, not_token.format(newline)),
        ]
        for name, args, code, stderr in table:
            actual, out, err = run(args)
            expect(name, actual == code and err == stderr and out == "",
                   f"exit {actual}, expected {code}; stderr {err!r}; stdout {out!r}")
        code, out, err = run(["--help"])
        expect("--help", code == 0 and out.startswith("Usage: bridge-mcp --client ID") and
               "headers --client ID --url URL" in out and not err, f"{code} {err!r}")
        code, out, err = run(["--version"])
        expect("--version", code == 0 and out.startswith("bridge-mcp ") and not err, f"{code} {out!r}")
        code, out, err = run(["headers", "--client", "nope", "--url", url])
        expect("headers usage error prints {}", code == 2 and out == "{}\n", f"{code} {out!r}")

        token_leaks = [line for line in stderr_seen if "ekb_mcp_v1_" in line]
        expect("stderr never contains a token", not token_leaks, f"{token_leaks[:2]!r}")
    except Exception as error:  # noqa: BLE001 - report, then clean up
        failures.append(f"aborted: {type(error).__name__}: {error}")
    finally:
        for session in relays:
            if session.process.poll() is None:
                session.process.kill()
        if harness:
            harness.close()
        if not failures:
            shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("Launcher tests failed:\n  " + "\n  ".join(failures), file=sys.stderr)
        print(f"  (temp files kept in {tmp})", file=sys.stderr)
        return 1
    print(f"Launcher: {checks} relay, headers, check and verification checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
