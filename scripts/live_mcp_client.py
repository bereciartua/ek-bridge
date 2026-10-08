#!/usr/bin/env python3
"""One MCP tool call through the live-test copy's own bridge-mcp launcher.

Usage: live_mcp_client.py LAUNCHER CLIENT_ID TOOL [ARGUMENTS_JSON] [--timeout SECONDS]

Starts LAUNCHER --client CLIENT_ID (stdio), initializes, calls TOOL and prints
one JSON line: {"isError": ..., "text": ..., "structured": ..., "seconds": ...}
or {"error": ...} for a JSON-RPC error. Exits 1 when no reply arrives in time.
The stdio session is the one in Tests/launcher_test.py (Relay). Standard
library only; scripts/live_test.sh runs it.
"""

import json
import queue
import subprocess
import sys
import threading
import time


def lines_to_queue(stream, sink):
    for line in iter(stream.readline, b""):
        sink.put(line.decode())
    sink.put(None)


class Relay:
    """One bridge-mcp stdio session."""

    def __init__(self, launcher, client_id):
        self.process = subprocess.Popen([launcher, "--client", client_id], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.out, self.err = queue.Queue(), queue.Queue()
        for stream, sink in ((self.process.stdout, self.out), (self.process.stderr, self.err)):
            threading.Thread(target=lines_to_queue, args=(stream, sink), daemon=True).start()

    def send(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def recv(self, timeout):
        try:
            line = self.out.get(timeout=timeout)
        except queue.Empty:
            return None
        return None if line is None else json.loads(line)

    def stderr(self):
        lines = []
        while True:
            try:
                line = self.err.get(timeout=0.3)
            except queue.Empty:
                return lines
            if line is None:
                return lines
            lines.append(line.rstrip("\n"))

    def close(self):
        try:
            self.process.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.process.wait(10)
        except subprocess.TimeoutExpired:
            self.process.kill()


def main():
    args = sys.argv[1:]
    timeout = 70.0
    if "--timeout" in args:
        index = args.index("--timeout")
        timeout = float(args[index + 1])
        del args[index:index + 2]
    if len(args) not in (3, 4):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    launcher, client_id, tool = args[:3]
    arguments = json.loads(args[3]) if len(args) == 4 else {}
    relay = Relay(launcher, client_id)
    try:
        relay.send({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                    "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                               "clientInfo": {"name": "live-test", "version": "1"}}})
        reply = relay.recv(15)
        if not reply or "result" not in reply:
            print(json.dumps({"error": "initialize failed", "reply": reply, "stderr": relay.stderr()}))
            return 1
        relay.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        started = time.monotonic()
        relay.send({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": {"name": tool, "arguments": arguments}})
        reply = relay.recv(timeout)
        seconds = round(time.monotonic() - started, 1)
        if reply is None:
            print(json.dumps({"error": "no reply", "seconds": seconds, "stderr": relay.stderr()}))
            return 1
        if "error" in reply:
            print(json.dumps({"error": reply["error"], "seconds": seconds}))
            return 0
        result = reply.get("result", {})
        text = "\n".join(part.get("text", "") for part in result.get("content", []) if part.get("type") == "text")
        print(json.dumps({"isError": result.get("isError", False), "text": text,
                          "structured": result.get("structuredContent"), "seconds": seconds},
                         ensure_ascii=False))
        return 0
    finally:
        relay.close()


if __name__ == "__main__":
    sys.exit(main())
