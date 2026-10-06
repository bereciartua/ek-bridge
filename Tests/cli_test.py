#!/usr/bin/env python3
"""Table-driven tests for bridge-client errors, help and the file exchange.

Usage: cli_test.py BRIDGE_CLIENT_TEST_BINARY

The binary must be built with -D EVENTKIT_CLIENT_TEST. Every case points it
at a fake bridge root and support directory under a fresh temporary
directory, so the tests never reach the real bridge, key files or registry.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

PRODUCT = "EventKit Bridge"
NOT_RUNNING = (f"error: {PRODUCT} isn't running, or the bridge is off. "
               "Turn it on from the menu bar.")
SESSION_CHANGED = "error: the bridge session changed. Run the command again."
PARAMS_INVALID = "error: params must be a JSON object under 30 KB."
RETRY_ADVICE = "  Read the item before retrying, and reuse the same idempotencyKey."


class Fixture:
    def __init__(self, binary: Path):
        self.binary = binary
        self.tmp = Path(tempfile.mkdtemp(prefix="eventkit-cli-test-"))
        self.support = self.make_dir(self.tmp / "support")
        self.credentials = self.make_dir(self.support / "client-credentials")
        self.no_bridge = self.tmp / "no-bridge"
        self.alpha = str(uuid.uuid4())
        self.beta = str(uuid.uuid4())
        self.revoked = str(uuid.uuid4())
        self.no_key = str(uuid.uuid4())
        self.write_registry(self.support, 3, [
            (self.alpha, "Alpha Tool", False),
            (self.beta, "Beta", False),
            (self.revoked, "Old Tool", True),
            (self.no_key, "Keyless", False),
        ])
        for client in (self.alpha, self.beta, self.revoked):
            self.write_key(self.credentials / f"{client}.json", client)
        self.key = self.credentials / f"{self.alpha}.json"

    @staticmethod
    def make_dir(path: Path, mode: int = 0o700) -> Path:
        path.mkdir(mode=mode)
        os.chmod(path, mode)
        return path

    @staticmethod
    def write_private(path: Path, text: str, mode: int = 0o600) -> Path:
        path.write_text(text)
        os.chmod(path, mode)
        return path

    def write_key(self, path: Path, client: str, mode: int = 0o600) -> Path:
        body = json.dumps({"clientID": client, "key": "ekb_v1_" + os.urandom(32).hex()})
        return self.write_private(path, body, mode)

    def write_registry(self, directory: Path, version: int, clients, mode: int = 0o600):
        records = [{
            "id": cid, "name": name, "revoked": revoked, "verifier": "00" * 32,
            "revision": 1, "grants": [],
        } for cid, name, revoked in clients]
        body = json.dumps({"version": version, "clients": records, "activity": []})
        return self.write_private(directory / "client-registry.json", body, mode)

    def fake_bridge(self, name: str, session_dir: bool = True):
        """A bridge root laid out like Sources/LocalBridge.swift."""
        root = self.make_dir(self.tmp / name)
        session = f"session-{str(uuid.uuid4()).upper()}"
        self.write_private(root / "current.json",
                           json.dumps({"version": 2, "session": session}))
        if session_dir:
            self.make_dir(root / session)
            self.make_dir(root / session / "requests")
            self.make_dir(root / session / "responses")
        return root, root / session

    def env(self, **overrides):
        env = {k: v for k, v in os.environ.items() if not k.startswith("EVENTKIT_")}
        env.update({
            "EVENTKIT_TEST_SUPPORT_DIR": str(self.support),
            "EVENTKIT_TEST_BRIDGE_ROOT": str(self.no_bridge),
            "EVENTKIT_TEST_TIMEOUT_SECONDS": "1",
        })
        env.update({k: str(v) for k, v in overrides.items()})
        return env

    def run(self, args, stdin=None, env=None, binary=None, argv0="client.py"):
        # client.py runs the client with argv[0] "client.py"; the default
        # matches it. Another binary (python3 for client.py) keeps its own.
        argv = [str(binary), *args] if binary else [argv0, *args]
        process = subprocess.run(
            argv, executable=str(binary or self.binary), input=(stdin or "").encode(),
            capture_output=True, env=env or self.env(), timeout=30)
        return process.returncode, process.stdout.decode(), process.stderr.decode()

    def cleanup(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def respond(session: Path, reply, timeout: float = 10):
    """Answer the first request file like the app would. `reply(request)`
    returns the response object, or None to remove the session instead."""
    requests, responses = session / "requests", session / "responses"
    seen = {}

    def worker():
        deadline = time.time() + timeout
        while time.time() < deadline:
            names = [n for n in os.listdir(requests)
                     if n.endswith(".json") and not n.startswith(".")]
            if names:
                name = names[0]
                request = json.loads((requests / name).read_text())
                seen["name"], seen["request"] = name, request
                (requests / name).unlink()
                response = reply(request)
                if response is None:
                    shutil.rmtree(session)
                    return
                temporary = responses / f".tmp-{uuid.uuid4()}"
                fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, "w") as output:
                    output.write(json.dumps(response))
                os.rename(temporary, responses / name)
                return
            time.sleep(0.02)

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    return thread, seen


def main() -> int:
    binary = Path(sys.argv[1]).resolve()
    client_py = Path(__file__).resolve().parent.parent / "client.py"
    f = Fixture(binary)
    failures = []
    checks = 0

    def check(name, result, code, first, second=None, stdout=None):
        nonlocal checks
        checks += 1
        actual_code, out, err = result
        lines = err.splitlines()
        problems = []
        if actual_code != code:
            problems.append(f"exit {actual_code}, expected {code}")
        if first is not None and (lines[0] if lines else "") != first:
            problems.append(f"stderr line 1 {lines[:1]!r}, expected {first!r}")
        if second is not None and (lines[1] if len(lines) > 1 else "") != second:
            problems.append(f"stderr line 2 {lines[1:2]!r}, expected {second!r}")
        if stdout is not None and not stdout(out):
            problems.append(f"unexpected stdout {out[:300]!r}")
        if "\x1b[" in err:
            problems.append("stderr is colored although it isn't a TTY")
        if problems:
            failures.append(f"{name}: " + "; ".join(problems) + f"\n    stderr: {err!r}")

    try:
        key = str(f.key)
        cred = ["--credentials-file", key]
        missing = str(f.credentials / f"{uuid.uuid4()}.json")
        loose = f.write_key(f.tmp / "loose.json", f.alpha, mode=0o644)
        link = f.tmp / "link.json"
        link.symlink_to(f.key)
        junk = f.write_private(f.tmp / "junk.json", '{"clientID":"x","key":"nope"}')
        params_list = f.write_private(f.tmp / "list.json", "[1, 2]")
        params_big = f.write_private(
            f.tmp / "big.json", json.dumps({"title": "x" * 31_000}))
        params_ok = f.write_private(
            f.tmp / "ok.json", json.dumps({"listID": "L", "limit": 1}))
        no_registry = f.make_dir(f.tmp / "support-empty")
        loose_registry = f.make_dir(f.tmp / "support-loose")
        f.write_registry(loose_registry, 3, [(f.alpha, "Alpha Tool", False)], mode=0o644)
        bad_registry = f.make_dir(f.tmp / "support-bad")
        f.write_private(bad_registry / "client-registry.json", '{"version": 9, "clients": []}')
        # A version 2 registry can hold two active clients with one name.
        twins = f.make_dir(f.tmp / "twins")
        twin_a, twin_b = str(uuid.uuid4()), str(uuid.uuid4())
        f.write_registry(twins, 2, [(twin_a, "Twin", False), (twin_b, "twin ", False)])
        v2_registry = f.make_dir(f.tmp / "support-v2")
        f.write_registry(v2_registry, 2, [(f.alpha, "Alpha Tool", False)])
        v4_registry = f.make_dir(f.tmp / "support-v4")
        f.write_registry(v4_registry, 4, [(f.alpha, "Alpha Tool", False)])
        empty_root = f.make_dir(f.tmp / "empty-root")
        stale_root, _ = f.fake_bridge("stale-root", session_dir=False)
        idle_root, _ = f.fake_bridge("idle-root")
        clients_list = 'Clients: "Alpha Tool", "Beta", "Keyless"'

        def has(*parts):
            return lambda out: all(part in out for part in parts)

        # (name, args, exit, stderr line 1, stderr line 2, kwargs, stdout check)
        table = [
            ("unknown option", ["read_events", "--param", "x", *cred], 2,
             'error: unknown option "--param". Run client.py --help.', None, {}, None),
            ("unknown command with suggestion", ["read_reminder", *cred], 2,
             'error: unknown command "read_reminder". Did you mean read_reminders?',
             "  Run client.py --help for all commands.", {}, None),
            ("unknown command without suggestion", ["frobnicate", *cred], 2,
             'error: unknown command "frobnicate".',
             "  Run client.py --help for all commands.", {}, None),
            ("missing command", [], 2, "error: missing command. Run client.py --help.",
             None, {}, None),
            ("missing credentials", ["scope_status"], 2,
             "error: missing --client or --credentials-file. Run client.py --help.",
             None, {}, None),
            ("option without value", ["scope_status", "--credentials-file"], 2,
             'error: option "--credentials-file" needs a value. Run client.py --help.',
             None, {}, None),
            ("both --client and --credentials-file",
             ["scope_status", "--client", "Beta", *cred], 2,
             "error: use --client or --credentials-file, not both.", None, {}, None),
            ("--help", ["--help"], 0, None, None, {},
             lambda out: out.startswith("Usage: client.py COMMAND") and
             "read_reminders" in out and "Needs Read access to the list." in out and
             "List calendars and lists. Needs an active client." in out and
             "client ID" in out and "--params-file -" in out),
            ("-h", ["-h"], 0, None, None, {}, has("Usage: client.py COMMAND")),
            ("read_events --help", ["read_events", "--help"], 0, None, None, {},
             has("Usage: client.py read_events", "Needs Read access to the calendar.",
                 "Required: calendarID, start, end, limit")),
            ("list_collections --help", ["list_collections", "--help"], 0, None, None, {},
             has("Usage: client.py list_collections", "Needs an active client.")),
            ("read_reminders -h", ["read_reminders", "-h"], 0, None, None, {},
             has("Required: listID, limit", "Optional: afterID")),
            ("help create_event", ["help", "create_event"], 0, None, None, {},
             has("Needs Create access to the calendar.", "Optional: allDay, timeZone, notes",
                 "60 s")),
            ("help get_event", ["help", "get_event"], 0, None, None, {},
             has("Read an event. Needs Read access to the calendar.", "Required: calendarID, itemID",
                 "Optional: occurrenceStart", "10 s")),
            ("help update_event", ["update_event", "--help"], 0, None, None, {},
             has("Required: calendarID, itemID, expectedVersion, idempotencyKey",
                 "Optional: title, start, end, allDay, timeZone, notes, location, structuredLocation, url, "
                 "alarms, availability, recurrence, occurrenceStart, span, targetCalendarID, "
                 "replaceUnsupportedAlarms", "under 30 KB")),
            ("help read_reminders filters", ["read_reminders", "--help"], 0, None, None, {},
             has("Optional: afterID, status, dueAfter, dueBefore")),
            ("help for unknown command", ["read_reminder", "--help"], 2,
             'error: unknown command "read_reminder". Did you mean read_reminders?',
             None, {}, None),
            ("missing key file", ["scope_status", "--credentials-file", missing], 4,
             f"error: key file not found: {missing}", None, {}, None),
            ("key file mode 644", ["scope_status", "--credentials-file", str(loose)], 4,
             f"error: {loose} can be read by other users (mode 644).",
             f"  Fix: chmod 600 {loose}", {}, None),
            ("symlink key file", ["scope_status", "--credentials-file", str(link)], 4,
             f"error: {link} is a symbolic link.", None, {}, None),
            ("malformed key file", ["scope_status", "--credentials-file", str(junk)], 4,
             f"error: {junk} isn't a key file for {PRODUCT}.", None, {}, None),
            ("params not an object", ["read_reminders", *cred, "--params-file",
                                      str(params_list)], 2, PARAMS_INVALID, None, {}, None),
            ("params too big", ["read_reminders", *cred, "--params-file", str(params_big)],
             2, PARAMS_INVALID, None, {}, None),
            ("params from stdin, too big", ["read_reminders", *cred, "--params-file", "-"],
             2, PARAMS_INVALID, None, {"stdin": json.dumps({"t": "x" * 31_000})}, None),
            ("params from stdin, not an object",
             ["read_reminders", *cred, "--params-file", "-"], 2, PARAMS_INVALID, None,
             {"stdin": '"text"'}, None),
            ("params from stdin, then bridge not running",
             ["read_reminders", *cred, "--params-file", "-"], 3, NOT_RUNNING, None,
             {"stdin": '{"listID": "L", "limit": 1}'}, None),
            ("bridge root missing", ["scope_status", *cred], 3, NOT_RUNNING, None, {}, None),
            ("current.json missing", ["scope_status", *cred], 3, NOT_RUNNING, None,
             {"env": {"EVENTKIT_TEST_BRIDGE_ROOT": empty_root}}, None),
            ("current.json points at a missing session", ["scope_status", *cred], 3,
             SESSION_CHANGED, None, {"env": {"EVENTKIT_TEST_BRIDGE_ROOT": stale_root}}, None),
            ("--client unknown name lists clients", ["scope_status", "--client", "Nobody"], 2,
             f'error: no active client named "Nobody". {clients_list}', None, {}, None),
            ("--client by name resolves", ["scope_status", "--client", "  alpha TOOL "], 3,
             NOT_RUNNING, None, {}, None),
            ("--client by UUID resolves", ["scope_status", "--client", f.beta.upper()], 3,
             NOT_RUNNING, None, {}, None),
            ("--client maps UUID to its key file", ["scope_status", "--client", f.no_key], 4,
             f"error: key file not found: {f.credentials / (f.no_key + '.json')}",
             None, {}, None),
            ("--client by name maps to its key file", ["scope_status", "--client", "keyless"],
             4, f"error: key file not found: {f.credentials / (f.no_key + '.json')}",
             None, {}, None),
            ("--client revoked name rejected", ["scope_status", "--client", "Old Tool"], 2,
             f'error: no active client named "Old Tool". {clients_list}', None, {}, None),
            ("--client without registry", ["scope_status", "--client", "Beta"], 2,
             'error: no active client named "Beta". No active clients.', None,
             {"env": {"EVENTKIT_TEST_SUPPORT_DIR": no_registry}}, None),
            ("--client with shared registry", ["scope_status", "--client", "Beta"], 4,
             f"error: {loose_registry / 'client-registry.json'} can be read by other users "
             "(mode 644).", None,
             {"env": {"EVENTKIT_TEST_SUPPORT_DIR": loose_registry}}, None),
            ("--client with unreadable registry", ["scope_status", "--client", "Beta"], 4,
             f"error: can't read the client list in {bad_registry / 'client-registry.json'}.",
             None, {"env": {"EVENTKIT_TEST_SUPPORT_DIR": bad_registry}}, None),
            ("--client with version 2 registry", ["scope_status", "--client", "alpha tool"], 4,
             f"error: key file not found: {v2_registry / 'client-credentials' / (f.alpha + '.json')}",
             None, {"env": {"EVENTKIT_TEST_SUPPORT_DIR": v2_registry}}, None),
            ("--client with version 4 registry", ["scope_status", "--client", "alpha tool"], 4,
             f"error: key file not found: {v4_registry / 'client-credentials' / (f.alpha + '.json')}",
             None, {"env": {"EVENTKIT_TEST_SUPPORT_DIR": v4_registry}}, None),
            ("--client name shared by two active clients", ["scope_status", "--client", "twin"], 2,
             f"error: more than one active client is named \"twin\". Use --client with one of these IDs: "
             f"{twin_a}, {twin_b}", None, {"env": {"EVENTKIT_TEST_SUPPORT_DIR": twins}}, None),
            ("read timeout", ["read_reminders", *cred, "--params-file", str(params_ok)], 5,
             "error: no response after 10 s. Is the Mac awake and the bridge on?", None,
             {"env": {"EVENTKIT_TEST_BRIDGE_ROOT": idle_root}}, None),
            ("write timeout", ["create_reminder", *cred, "--params-file", "-"], 5,
             "error: no response after 60 s. The write may still have happened.",
             RETRY_ADVICE, {"stdin": '{"listID": "L"}',
                            "env": {"EVENTKIT_TEST_BRIDGE_ROOT": idle_root}}, None),
        ]
        for name, args, code, first, second, options, stdout in table:
            env = f.env(**options.get("env", {}))
            result = f.run(args, stdin=options.get("stdin"), env=env)
            if code == 0 and result[2]:
                failures.append(f"{name}: stderr should be empty, got {result[2]!r}")
            check(name, result, code, first, second, stdout)

        # Fake bridge round trips.
        def exchange(name, args, reply, stdin=None):
            root, session = f.fake_bridge(name)
            thread, seen = respond(session, reply)
            result = f.run(args, stdin=stdin,
                           env=f.env(EVENTKIT_TEST_BRIDGE_ROOT=root,
                                     EVENTKIT_TEST_TIMEOUT_SECONDS=10))
            thread.join(5)
            return result, seen

        result, seen = exchange(
            "forbidden-root", ["read_reminders", *cred, "--params-file", "-"],
            lambda r: {"version": 2, "id": r["id"], "ok": False, "error": "forbidden"},
            stdin='{"listID": "L", "limit": 1}')
        check("ok:false prints JSON and a hint", result, 1,
              "hint: Grant it in the client's Access, only if the tool should be able to do this.",
              stdout=lambda out: out.endswith("\n") and
              json.loads(out).get("error") == "forbidden" and json.loads(out)["ok"] is False)
        request = seen.get("request", {})
        checks += 1
        if not (request.get("command") == "read_reminders" and
                request.get("clientID") == f.alpha and
                request.get("parameters") == {"listID": "L", "limit": 1} and
                len(request.get("signature", "")) == 128 and request.get("version") == 2):
            failures.append(f"request file shape: {request!r}")

        result, _ = exchange(
            "ok-root", ["scope_status", "--client", "Alpha Tool"],
            lambda r: {"version": 2, "id": r["id"], "ok": True, "result": {"grants": []}})
        check("ok:true exits 0", result, 0, None,
              stdout=lambda out: out == '{"id":"%s","ok":true,"result":{"grants":[]},"version":2}\n'
              % json.loads(out)["id"])
        if result[2]:
            failures.append(f"ok:true: stderr should be empty, got {result[2]!r}")

        result, _ = exchange("unknown-code-root", ["scope_status", *cred],
                             lambda r: {"version": 2, "id": r["id"], "ok": False,
                                        "error": "brand_new_code"})
        check("ok:false with an unknown code", result, 1,
              "hint: The bridge returned brand_new_code.")

        result, _ = exchange("vanish-root", ["scope_status", *cred], lambda r: None)
        check("session removed while waiting", result, 3, SESSION_CHANGED)

        # Run directly, or as ~/.local/bin/bridge-client, it names itself.
        check("bridge-client names itself", f.run(["--help"], argv0="/x/bridge-client"), 0, None,
              stdout=has("Usage: bridge-client COMMAND"))
        check("bridge-client usage error", f.run([], argv0="bridge-client"), 2,
              "error: missing command. Run bridge-client --help.")

        # client.py launcher.
        launcher_env = f.env(EVENTKIT_CLIENT_BINARY=f.tmp / "not-built")
        result = f.run([str(client_py), "--help"], env=launcher_env, binary=sys.executable)
        check("client.py with a missing EVENTKIT_CLIENT_BINARY", result, 4,
              f"error: EVENTKIT_CLIENT_BINARY isn't a file: {f.tmp / 'not-built'}")
        result = f.run([str(client_py), "scope_status", "--help"],
                       env=f.env(EVENTKIT_CLIENT_BINARY=binary), binary=sys.executable)
        check("client.py passes arguments through", result, 0, None,
              stdout=has("Usage: client.py scope_status", "Takes no parameters."))
        # Without the variable: build/bridge-client next to client.py, then the
        # installed app in /Applications, then in ~/Applications.
        checkout = f.make_dir(f.tmp / "checkout")
        shutil.copy(client_py, checkout / "client.py")
        home = f.make_dir(f.tmp / "home")
        plain_env = f.env(HOME=home)
        plain_env.pop("EVENTKIT_CLIENT_BINARY", None)
        installed = Path("/Applications/EventKitBridge.app/Contents/MacOS/bridge-client").is_file()
        result = f.run([str(checkout / "client.py"), "--help"], env=plain_env, binary=sys.executable)
        if not installed:
            check("client.py finds no client", result, 4,
                  "error: bridge-client wasn't found. Run: sh build.sh, "
                  "or install EventKitBridge.app in /Applications.")
        user_app = home / "Applications" / "EventKitBridge.app" / "Contents" / "MacOS"
        user_app.mkdir(parents=True)
        (user_app / "bridge-client").symlink_to(binary)
        result = f.run([str(checkout / "client.py"), "--help"], env=plain_env, binary=sys.executable)
        check("client.py finds an installed app", result, 0, None,
              stdout=has("Usage: client.py COMMAND"))
        f.make_dir(checkout / "build")
        (checkout / "build" / "bridge-client").symlink_to(binary)
        (user_app / "bridge-client").unlink()
        result = f.run([str(checkout / "client.py"), "--help"], env=plain_env, binary=sys.executable)
        check("client.py prefers build/bridge-client", result, 0, None,
              stdout=has("Usage: client.py COMMAND"))
    finally:
        f.cleanup()

    if failures:
        print("CLI tests failed:\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    print(f"CLI: {checks} error, help and exchange checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
