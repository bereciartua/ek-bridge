#!/usr/bin/env python3
"""One request to a user-enabled local EventKit Bridge session; prints no token."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys
import time
from typing import Optional
import uuid


class BridgeClientError(Exception):
    pass


def owned_file(path: Path, limit: int) -> bytes:
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    fd = os.open(path, flags)
    try:
        details = os.fstat(fd)
        if (not stat.S_ISREG(details.st_mode) or details.st_uid != os.getuid()
                or details.st_mode & 0o077 or details.st_size > limit):
            raise BridgeClientError("unsafe or oversized bridge file")
        content = os.read(fd, limit + 1)
        if len(content) > limit:
            raise BridgeClientError("oversized bridge file")
        return content
    finally:
        os.close(fd)


def owned_directory(path: Path) -> None:
    details = path.lstat()
    if (not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid()
            or details.st_mode & 0o077):
        raise BridgeClientError("unsafe bridge directory")


def atomic_request(path: Path, content: bytes) -> None:
    temporary = path.parent / (".tmp-" + str(uuid.uuid4()))
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    fd = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(fd, "wb", closefd=False) as output:
            output.write(content)
            output.flush()
            os.fsync(fd)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    finally:
        os.close(fd)


def send(command: str, parameters: Optional[dict] = None) -> dict:
    root = Path("/tmp") / ("eventkit-bridge-" + str(os.getuid()))
    owned_directory(root)
    descriptor = json.loads(owned_file(root / "current.json", 2048))
    if set(descriptor) != {"version", "session", "token", "expiresAt"}:
        raise BridgeClientError("invalid bridge session")
    session_name = descriptor["session"]
    if (descriptor["version"] != 1 or not isinstance(session_name, str)
            or not session_name.startswith("session-")
            or str(uuid.UUID(session_name[8:])) != session_name[8:].lower()
            or not isinstance(descriptor["token"], str)
            or len(descriptor["token"]) != 64
            or time.time() >= descriptor["expiresAt"]):
        raise BridgeClientError("invalid or expired bridge session")
    session = root / session_name
    requests = session / "requests"
    responses = session / "responses"
    for directory in (session, requests, responses):
        owned_directory(directory)

    request_id = str(uuid.uuid4())
    message = {
        "version": 1,
        "id": request_id,
        "command": command,
        "parameters": parameters or {},
        "token": descriptor["token"],
        "issuedAt": time.time(),
    }
    request = json.dumps(message, separators=(",", ":")).encode("utf-8")
    if len(request) > 8192:
        raise BridgeClientError("request too large")
    response_path = responses / (request_id + ".json")
    atomic_request(requests / (request_id + ".json"), request)
    deadline = min(time.monotonic() + 10, time.monotonic() + max(0, descriptor["expiresAt"] - time.time()))
    while time.monotonic() < deadline:
        try:
            response = json.loads(owned_file(response_path, 65536))
            response_path.unlink()
            if response.get("version") != 1 or response.get("id") != request_id:
                raise BridgeClientError("invalid bridge response")
            return response
        except FileNotFoundError:
            time.sleep(0.1)
    raise BridgeClientError("bridge did not reply before timeout")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=(
        "authorization_status", "calendar_count", "reminder_list_count", "scope_status",
        "read_events", "read_reminders", "create_event", "update_event",
        "delete_event", "create_reminder", "update_reminder",
        "complete_reminder", "delete_reminder"))
    parser.add_argument("--params-file", type=Path,
                        help="JSON object in a private mode-0600 file")
    args = parser.parse_args()
    try:
        parameters = json.loads(owned_file(args.params_file, 8192)) if args.params_file else {}
        if not isinstance(parameters, dict):
            raise BridgeClientError("parameters must be an object")
        response = send(args.command, parameters)
    except (BridgeClientError, OSError, ValueError, KeyError, TypeError):
        print("Bridge request failed or session is unavailable.", file=sys.stderr)
        return 1
    print(json.dumps(response, sort_keys=True))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
