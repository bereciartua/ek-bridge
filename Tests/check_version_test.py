#!/usr/bin/env python3
"""Tests scripts/check_version.sh in throwaway git repositories."""

from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
                        "PATH": "/usr/bin:/bin", "HOME": str(repo)})


def write(repo, version, build, changelog=None):
    with open(ROOT / "Info.plist", "rb") as source:
        plist = plistlib.load(source)
    plist["CFBundleShortVersionString"] = version
    plist["CFBundleVersion"] = build
    with open(repo / "Info.plist", "wb") as output:
        plistlib.dump(plist, output)
    (repo / "CHANGELOG.md").write_text(changelog if changelog is not None
                                       else f"# Changelog\n\n## [{version}] - 2026-10-06\n")


def run(repo, *args):
    process = subprocess.run(["sh", str(repo / "scripts" / "check_version.sh"), *args],
                             capture_output=True, text=True)
    return process.returncode, (process.stdout + process.stderr).strip()


def main() -> int:
    failures, checks = [], 0
    tmp = Path(tempfile.mkdtemp(prefix="eventkit-version-test-"))
    try:
        repo = tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "scripts" / "check_version.sh", repo / "scripts")
        git(repo, "init", "-q")

        def check(name, args, code, text):
            nonlocal checks
            checks += 1
            actual, output = run(repo, *args)
            if actual != code or text not in output:
                failures.append(f"{name}: exit {actual}, expected {code}; output {output!r}")

        write(repo, "0.8.0", "8")
        check("first release, no tags yet", ["v0.8.0"], 0, "0.8.0 (8) passed")
        check("no tag given", [], 0, "passed")
        check("tag doesn't match", ["v0.8.1"], 1, "expected v0.8.0")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "0.8.0")
        git(repo, "tag", "v0.8.0")
        check("the tagged release itself", ["v0.8.0"], 0, "passed")

        write(repo, "0.9.0", "8")
        check("build number not raised", ["v0.9.0"], 1, "isn't higher than v0.8.0's 8")
        write(repo, "0.9.0", "9")
        check("build number raised", ["v0.9.0"], 0, "after v0.8.0")
        write(repo, "0.9.0", "9", changelog="# Changelog\n\n## [Unreleased]\n")
        check("no changelog section", ["v0.9.0"], 1, 'no "## [0.9.0]" section')
        write(repo, "0.9", "9")
        check("version isn't x.y.z", [], 1, "isn't x.y.z")
        write(repo, "0.9.0", "9a")
        check("build isn't a number", [], 1, "isn't a whole number")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Version check: {checks} tag, build number and changelog checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
