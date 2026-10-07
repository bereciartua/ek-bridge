#!/usr/bin/env python3
"""Tests the release tools offline: scripts/release_notes.py, scripts/appcast.py,
the argument checks of scripts/check_notarized.sh, and release.sh's refusals
before it builds anything, in a throwaway git repository with a stub
`security` command on PATH (so no keychain, identity or network is needed)."""

import os
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import appcast  # noqa: E402
import release_notes  # noqa: E402

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
CHANGELOG = """# Changelog

Intro text that is not part of any version.

## [Unreleased]

- Something unreleased.

## [0.8.0] - 2026-10-07

First paragraph with **bold**, `code`, a [relative link](docs/MCP.md#tools) and
a [full link](https://example.com/x?a=1&b=2), plus <angle> & ampersand.

### Added

- Top item one with `code`.
- Top item two:
  - nested item with [a link](CHANGELOG.md).
  - another nested item
    that continues on the next line.
- Top item three.

### Changed

Closing paragraph.

## [0.7.0] - 2026-10-06

Older notes.
"""

failures = []
checks = 0


def check(name, condition, detail=""):
    global checks
    checks += 1
    if not condition:
        failures.append(f"{name}{': ' + detail if detail else ''}")


def test_release_notes():
    body = release_notes.section(CHANGELOG, "0.8.0")
    check("section starts after the heading", body.startswith("First paragraph"))
    check("section stops before the next version", "Older notes" not in body and "Unreleased" not in body)
    check("section keeps its subsections", "### Added" in body and "Closing paragraph." in body)
    for version in ("0.9.0", "Unreleased]"):
        try:
            release_notes.section(CHANGELOG, version)
            check(f"missing section {version} raises", False)
        except release_notes.NotesError:
            pass
    try:
        release_notes.section("# Changelog\n\n## [1.0.0]\n\n## [0.9.0]\nx\n", "1.0.0")
        check("empty section raises", False)
    except release_notes.NotesError:
        pass

    repo = "owner/name"
    md = release_notes.markdown(body, "0.8.0", repo)
    check("markdown absolutizes relative links",
          "[relative link](https://github.com/owner/name/blob/v0.8.0/docs/MCP.md#tools)" in md, md)
    check("markdown keeps full links", "[full link](https://example.com/x?a=1&b=2)" in md)
    check("markdown keeps the rest", "**bold**" in md and "### Added" in md)

    html_text = release_notes.to_html(body, "0.8.0", repo)
    check("html paragraph with inline markup",
          "<p>First paragraph with <strong>bold</strong>, <code>code</code>, a "
          '<a href="https://github.com/owner/name/blob/v0.8.0/docs/MCP.md#tools">relative link</a>' in html_text,
          html_text)
    check("html escapes text", "&lt;angle&gt; &amp; ampersand" in html_text, html_text)
    check("html escapes attribute ampersands",
          '<a href="https://example.com/x?a=1&amp;b=2">full link</a>' in html_text, html_text)
    check("html headings are one level down", "<h4>Added</h4>" in html_text and "<h4>Changed</h4>" in html_text)
    check("html nested lists",
          "<ul><li>Top item one with <code>code</code>.\n</li><li>Top item two:\n"
          '<ul><li>nested item with <a href="https://github.com/owner/name/blob/v0.8.0/CHANGELOG.md">a link</a>.\n'
          "</li><li>another nested item that continues on the next line.\n"
          "</li></ul>\n</li><li>Top item three.\n</li></ul>" in html_text, html_text)
    check("html closes lists before a heading and paragraph",
          "</li></ul>\n<h4>Changed</h4>\n<p>Closing paragraph.</p>" in html_text, html_text)
    check("html has no raw markdown", "**" not in html_text and "](" not in html_text)
    check("html ends with a newline", html_text.endswith("\n"))

    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "CHANGELOG.md"
        path.write_text(CHANGELOG)
        base = [sys.executable, str(ROOT / "scripts" / "release_notes.py"), "--changelog", str(path)]
        out = subprocess.run(base + ["0.8.0"], capture_output=True, text=True)
        check("cli markdown", out.returncode == 0 and out.stdout.startswith("First paragraph")
              and "bereciartua/ek-bridge/blob/v0.8.0/docs/MCP.md" in out.stdout, out.stdout + out.stderr)
        out = subprocess.run(base + ["0.8.0", "--format", "html", "--repo", "o/n"], capture_output=True, text=True)
        check("cli html", out.returncode == 0 and out.stdout.startswith("<p>") and "github.com/o/n/" in out.stdout)
        out = subprocess.run(base + ["0.9.0"], capture_output=True, text=True)
        check("cli missing version", out.returncode == 1 and 'no "## [0.9.0]" section' in out.stderr, out.stderr)


def test_appcast():
    sig, length = appcast.parse_signature_line('sparkle:edSignature="AbC+/9==" length="1234"\n')
    check("signature line parsed", (sig, length) == ("AbC+/9==", 1234))
    for bad in ("", "length=12", 'sparkle:edSignature="x y" length="1"'):
        try:
            appcast.parse_signature_line(bad)
            check(f"bad signature line {bad!r} raises", False)
        except appcast.AppcastError:
            pass
    check("release page from an asset URL",
          appcast.release_page("https://github.com/o/n/releases/download/v0.8.0/EKBridge-0.8.0.zip")
          == "https://github.com/o/n/releases/tag/v0.8.0")
    check("release page falls back to the URL", appcast.release_page("https://x/y.zip") == "https://x/y.zip")

    kwargs = dict(version="0.8.0", build="8", minimum_system_version="14.0",
                  url="https://github.com/o/n/releases/download/v0.8.0/EKBridge-0.8.0.zip",
                  signature="AbC+/9==", length=1234, notes_html="<p>Notes & \"more\"</p>\n",
                  title="EK Bridge 0.8.0", link="https://github.com/o/n/releases/tag/v0.8.0",
                  date="Wed, 07 Oct 2026 10:00:00 GMT")
    text = appcast.appcast(**kwargs)
    root = ET.fromstring(text)
    item = root.find("channel/item")
    check("appcast is RSS 2.0", root.tag == "rss" and root.get("version") == "2.0")
    check("item fields", item.findtext("title") == "EK Bridge 0.8.0"
          and item.findtext("link") == kwargs["link"] and item.findtext("pubDate") == kwargs["date"]
          and item.findtext(f"{SPARKLE_NS}version") == "8"
          and item.findtext(f"{SPARKLE_NS}shortVersionString") == "0.8.0"
          and item.findtext(f"{SPARKLE_NS}minimumSystemVersion") == "14.0", text)
    check("notes are the HTML inside CDATA", item.findtext("description") == '<p>Notes & "more"</p>'
          and "<![CDATA[<p>Notes" in text, text)
    enclosure = item.find("enclosure")
    check("enclosure", enclosure.get("url") == kwargs["url"] and enclosure.get("length") == "1234"
          and enclosure.get(f"{SPARKLE_NS}edSignature") == "AbC+/9=="
          and enclosure.get("type") == "application/octet-stream", text)
    check("not critical by default", item.find(f"{SPARKLE_NS}criticalUpdate") is None)
    critical = ET.fromstring(appcast.appcast(**dict(kwargs, critical=True)))
    check("critical update marked", critical.find(f"channel/item/{SPARKLE_NS}criticalUpdate") is not None)
    local = appcast.appcast(**dict(kwargs, url="http://127.0.0.1:47690/EKBridge-0.0.2.zip", allow_local_http=True))
    check("local http allowed only when asked", 'url="http://127.0.0.1:47690/EKBridge-0.0.2.zip"' in local)
    for name, change in (("http url", dict(url="http://x/y.zip")), ("bad build", dict(build="8a")),
                         ("local http not asked for", dict(url="http://127.0.0.1:47690/y.zip")),
                         ("other http host even when asked", dict(url="http://example.com/y.zip", allow_local_http=True)),
                         ("zero length", dict(length=0)), ("cdata end in notes", dict(notes_html="a]]>b"))):
        try:
            appcast.appcast(**dict(kwargs, **change))
            check(f"{name} raises", False)
        except appcast.AppcastError:
            pass

    with tempfile.TemporaryDirectory() as tmp:
        notes = Path(tmp) / "notes.html"
        notes.write_text("<p>cli</p>")
        output = Path(tmp) / "appcast.xml"
        cmd = [sys.executable, str(ROOT / "scripts" / "appcast.py"), "--version", "0.8.0", "--build", "8",
               "--minimum-system-version", "14.0", "--url", kwargs["url"],
               "--signature-line", 'sparkle:edSignature="QQ==" length="7"', "--notes-html", str(notes),
               "--date", kwargs["date"], "--output", str(output)]
        out = subprocess.run(cmd, capture_output=True, text=True)
        parsed = ET.parse(output).getroot().find("channel/item") if output.exists() else None
        check("cli writes the appcast", out.returncode == 0 and parsed is not None
              and parsed.findtext("title") == "EK Bridge 0.8.0"
              and parsed.findtext("link") == "https://github.com/o/n/releases/tag/v0.8.0"
              and parsed.find("enclosure").get("length") == "7", out.stdout + out.stderr)
        out = subprocess.run(cmd[:-2] + ["--signature-line", "nothing"], capture_output=True, text=True)
        check("cli rejects a bad signature line", out.returncode == 1 and "unexpected sign_update output" in out.stderr)


def test_check_notarized():
    script = ROOT / "scripts" / "check_notarized.sh"
    out = subprocess.run(["sh", str(script), "/nowhere/x.pkg"], capture_output=True, text=True)
    check("check_notarized rejects other kinds", out.returncode == 1 and "neither" in out.stderr, out.stderr)
    out = subprocess.run(["sh", str(script), "/nowhere/x.app"], capture_output=True, text=True)
    check("check_notarized needs the path", out.returncode == 1 and "doesn't exist" in out.stderr, out.stderr)
    out = subprocess.run(["sh", str(script)], capture_output=True, text=True)
    check("check_notarized usage", out.returncode != 0 and "usage" in out.stderr)


def git(repo, *args):
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
                        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
                        "PATH": "/usr/bin:/bin", "HOME": str(repo)})


def test_release_refusals():
    """release.sh refuses before building: tree, tag, identity, credentials, tools."""
    tmp = Path(tempfile.mkdtemp(prefix="eventkit-release-test-"))
    try:
        repo = tmp / "repo"
        (repo / "scripts").mkdir(parents=True)
        shutil.copy(ROOT / "release.sh", repo)
        for name in ("check_version.sh", "check_notarized.sh", "check_bundle.sh", "release_notes.py", "appcast.py"):
            shutil.copy(ROOT / "scripts" / name, repo / "scripts")
        with open(ROOT / "Info.plist", "rb") as source:
            plist = plistlib.load(source)
        plist["CFBundleShortVersionString"], plist["CFBundleVersion"] = "0.8.0", "8"
        plist["SUPublicEDKey"] = ""

        def write_plist():
            with open(repo / "Info.plist", "wb") as output:
                plistlib.dump(plist, output)
        write_plist()
        (repo / "CHANGELOG.md").write_text("# Changelog\n\n## [0.8.0] - 2026-10-07\n\nNotes.\n")
        (repo / "test.sh").write_text("#!/bin/sh\necho stub tests ran\nexit 3\n")
        git(repo, "init", "-q")

        # A stub `security` so no keychain is read; its identities come from a file.
        stubs = tmp / "stubs"
        stubs.mkdir()
        identities = tmp / "identities.txt"
        stub = stubs / "security"
        stub.write_text("#!/bin/sh\ncat \"$IDENTITIES\"\n")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        env = {"PATH": f"{stubs}:/usr/bin:/bin:/usr/sbin", "HOME": str(tmp), "IDENTITIES": str(identities)}

        def run(*args, **extra):
            process = subprocess.run(["sh", str(repo / "release.sh"), *args], capture_output=True, text=True,
                                     env={**env, **extra}, cwd=str(tmp))
            return process.returncode, process.stdout + process.stderr

        def expect(name, args, code, text, **extra):
            actual, output = run(*args, **extra)
            check(name, actual == code and text in output, f"exit {actual}, expected {code}; output {output!r}")

        dev_id = '  1) ABCDEF "Developer ID Application: Test Person (TEAMID1234)"\n     1 valid identities found\n'
        identities.write_text(dev_id)

        expect("help", ["--help"], 0, "Usage: sh release.sh")
        expect("unknown option", ["--bogus"], 2, "unknown option --bogus")
        expect("dirty tree", ["--untagged", "--skip-tests"], 1, "uncommitted changes")
        git(repo, "add", "-A")
        git(repo, "commit", "-qm", "0.8.0")
        expect("untagged head", ["--skip-tests"], 1, "HEAD isn't tagged v0.8.0")
        git(repo, "tag", "v0.8.1")
        expect("wrong tag", ["--skip-tests"], 1, "HEAD isn't tagged v0.8.0")
        git(repo, "tag", "-d", "v0.8.1")

        identities.write_text("     0 valid identities found\n")
        expect("no Developer ID", ["--untagged", "--skip-tests"], 1, 'no "Developer ID Application" identity')
        identities.write_text(dev_id + '  2) 123456 "Developer ID Application: Other (TEAMID5678)"\n')
        expect("two Developer IDs", ["--untagged", "--skip-tests"], 1, "more than one Developer ID Application identity")
        identities.write_text(dev_id)
        expect("unknown identity", ["--untagged", "--skip-tests"], 1, "isn't a valid code-signing identity",
               EVENTKIT_SIGN_IDENTITY="Nobody")
        identities.write_text('  1) ABCDEF "Apple Development: Test Person (TEAMID1234)"\n     1 valid identities found\n')
        expect("notarizing needs Developer ID", ["--untagged", "--skip-tests"], 1,
               "notarization needs a Developer ID Application identity",
               EVENTKIT_SIGN_IDENTITY="Apple Development: Test Person (TEAMID1234)")
        identities.write_text(dev_id)
        expect("no notary credentials", ["--untagged", "--skip-tests"], 1, "set EVENTKIT_NOTARY_PROFILE, or")
        expect("notary key must exist", ["--untagged", "--skip-tests"], 1, "isn't a file",
               EVENTKIT_NOTARY_KEY=str(tmp / "missing.p8"), EVENTKIT_NOTARY_KEY_ID="KEYID")
        expect("sparkle key must exist", ["--untagged", "--skip-tests"], 1, "EVENTKIT_SPARKLE_KEY_FILE",
               EVENTKIT_NOTARY_PROFILE="p", EVENTKIT_SPARKLE_KEY_FILE=str(tmp / "missing.key"))
        (tmp / "sparkle.key").write_text("x")
        sparkle = {"EVENTKIT_NOTARY_PROFILE": "p", "EVENTKIT_SPARKLE_KEY_FILE": str(tmp / "sparkle.key")}
        expect("sparkle key needs SUPublicEDKey", ["--untagged", "--skip-tests"], 1,
               "Info.plist has no SUPublicEDKey", **sparkle)
        plist["SUPublicEDKey"] = "c2FtcGxlIHB1YmxpYyBrZXkgZm9yIHRlc3RzIG9ubHkh"
        write_plist()
        git(repo, "commit", "-qam", "public key")
        expect("sparkle needs sign_update", ["--untagged", "--skip-tests"], 1, "sign_update wasn't found", **sparkle)
        git(repo, "tag", "v0.8.0")
        expect("a release needs the sparkle key", ["--skip-tests"], 1, "set EVENTKIT_SPARKLE_KEY_FILE",
               EVENTKIT_NOTARY_PROFILE="p")
        sign_update = stubs / "sign_update"
        sign_update.write_text("#!/bin/sh\nexit 9\n")
        sign_update.chmod(sign_update.stat().st_mode | stat.S_IXUSR)
        sparkle["EVENTKIT_SPARKLE_BIN"] = str(stubs)
        expect("rehearsals may skip the sparkle key", ["--untagged"], 3, "stub tests ran", EVENTKIT_NOTARY_PROFILE="p")
        expect("the keychain's sparkle key counts", ["--skip-tests"], 1, "gh (the GitHub CLI) is needed",
               EVENTKIT_NOTARY_PROFILE="p", EVENTKIT_SPARKLE_KEYCHAIN="1", EVENTKIT_SPARKLE_BIN=str(stubs))
        expect("release needs gh", ["--skip-tests"], 1, "gh (the GitHub CLI) is needed", **sparkle)
        # With every check passed, the next step is the tests; a failure there stops the release.
        expect("checks pass up to the tests, whose failure stops it", ["--no-release"], 3, "stub tests ran", **sparkle)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    test_release_notes()
    test_appcast()
    test_check_notarized()
    test_release_refusals()
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Release tools: {checks} release notes, appcast, notarization check and release.sh refusal checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
