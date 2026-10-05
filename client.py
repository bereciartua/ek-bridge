#!/usr/bin/env python3
"""Invoke the local signing client built by build.sh.

Usage: client.py COMMAND --client NAME|ID [--params-file PRIVATE_JSON|-]
       client.py COMMAND --credentials-file PRIVATE_JSON [--params-file PRIVATE_JSON|-]
       client.py --help | client.py COMMAND --help

`--params-file -` reads the parameters from stdin. The signing secret is read
by the Swift client and never passed in argv.
"""

import os
from pathlib import Path
import sys


def main() -> int:
    binary = Path(os.environ.get(
        "EVENTKIT_CLIENT_BINARY",
        str(Path(__file__).resolve().parent / "build" / "bridge-client")))
    if not binary.is_file():
        print("error: bridge-client isn't built. Run: sh build.sh", file=sys.stderr)
        return 4
    os.execv(str(binary), [str(binary), *sys.argv[1:]])
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
