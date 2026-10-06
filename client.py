#!/usr/bin/env python3
"""Invoke the local signing client, bridge-client.

Usage: client.py COMMAND --client NAME|ID [--params-file PRIVATE_JSON|-]
       client.py COMMAND --credentials-file PRIVATE_JSON [--params-file PRIVATE_JSON|-]
       client.py --help | client.py COMMAND --help

`--params-file -` reads the parameters from stdin. The signing secret is read
by the Swift client and never passed in argv.

The client is EVENTKIT_CLIENT_BINARY when set; otherwise the one build.sh made
next to this file, then the copy inside the installed app.
"""

import os
from pathlib import Path
import sys

APP_NAME = "EventKitBridge.app"
BUNDLED = Path("Contents") / "MacOS" / "bridge-client"


def candidates():
    yield Path(__file__).resolve().parent / "build" / "bridge-client"
    yield Path("/Applications") / APP_NAME / BUNDLED
    yield Path.home() / "Applications" / APP_NAME / BUNDLED


def main() -> int:
    override = os.environ.get("EVENTKIT_CLIENT_BINARY")
    if override:
        binary = Path(override)
        if not binary.is_file():
            print(f"error: EVENTKIT_CLIENT_BINARY isn't a file: {binary}", file=sys.stderr)
            return 4
    else:
        binary = next((path for path in candidates() if path.is_file()), None)
        if binary is None:
            print("error: bridge-client wasn't found. Run: sh build.sh, "
                  f"or install {APP_NAME} in /Applications.", file=sys.stderr)
            return 4
    # argv[0] "client.py" makes the client's help and errors name this script.
    os.execv(str(binary), ["client.py", *sys.argv[1:]])
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
