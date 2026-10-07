#!/usr/bin/env python3
"""Writes the Sparkle 2 appcast for one release.

The feed lists only the newest version: the app reads it from the latest
GitHub release, so that is all Sparkle needs. The zip's EdDSA signature and
length come from Sparkle's sign_update, whose one-line output is passed in
whole with --signature-line (sparkle:edSignature="..." length="...").

Usage: appcast.py --version 0.8.0 --build 8 --minimum-system-version 14.0
                  --url https://.../EKBridge-0.8.0.zip
                  --signature-line 'sparkle:edSignature="..." length="..."'
                  --notes-html notes.html [--title "EK Bridge 0.8.0"]
                  [--link https://.../releases/tag/v0.8.0] [--date RFC822]
                  [--critical] [--output appcast.xml] [--allow-local-http]

--allow-local-http accepts an http://127.0.0.1 download URL, for
scripts/update_test.sh's local feed only; releases always use https.
"""

import argparse
import email.utils
import re
import sys
from xml.sax.saxutils import escape, quoteattr

SIGNATURE_LINE = re.compile(r'sparkle:edSignature="([A-Za-z0-9+/=]+)"\s+length="(\d+)"')


class AppcastError(Exception):
    pass


def parse_signature_line(line: str):
    match = SIGNATURE_LINE.search(line)
    if not match:
        raise AppcastError(f"unexpected sign_update output: {line.strip()!r}")
    return match.group(1), int(match.group(2))


def release_page(url: str) -> str:
    """A GitHub release asset URL's release page, else the URL itself."""
    match = re.fullmatch(r"(.*)/releases/download/([^/]+)/[^/]+", url)
    return f"{match.group(1)}/releases/tag/{match.group(2)}" if match else url


def cdata(text: str) -> str:
    if "]]>" in text:
        raise AppcastError("the release notes contain ']]>'")
    return f"<![CDATA[{text}]]>"


def appcast(*, version, build, minimum_system_version, url, signature, length,
            notes_html, title, link, date, critical=False, allow_local_http=False) -> str:
    for name, value in (("version", version), ("build", build),
                        ("minimum system version", minimum_system_version)):
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", value):
            raise AppcastError(f"the {name} {value!r} isn't dotted digits")
    local = allow_local_http and re.fullmatch(r"http://127\.0\.0\.1:[0-9]+/[^?#]+", url)
    if not url.startswith("https://") and not local:
        raise AppcastError(f"the download URL must use https: {url}")
    if length <= 0:
        raise AppcastError("the download length must be positive")
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
        "  <channel>",
        f"    <title>{escape(title)}</title>",
        "    <item>",
        f"      <title>{escape(title)}</title>",
        f"      <link>{escape(link)}</link>",
        f"      <pubDate>{escape(date)}</pubDate>",
        f"      <sparkle:version>{escape(build)}</sparkle:version>",
        f"      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{escape(minimum_system_version)}</sparkle:minimumSystemVersion>",
    ]
    if critical:
        lines.append("      <sparkle:criticalUpdate/>")
    lines += [
        f"      <description>{cdata(notes_html.strip())}</description>",
        f"      <enclosure url={quoteattr(url)} length=\"{length}\" type=\"application/octet-stream\""
        f" sparkle:edSignature={quoteattr(signature)}/>",
        "    </item>",
        "  </channel>",
        "</rss>",
    ]
    return "\n".join(lines) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True, help="CFBundleShortVersionString")
    parser.add_argument("--build", required=True, help="CFBundleVersion")
    parser.add_argument("--minimum-system-version", required=True, help="LSMinimumSystemVersion")
    parser.add_argument("--url", required=True, help="the zip's download URL")
    parser.add_argument("--signature-line", required=True, help="sign_update's output line")
    parser.add_argument("--notes-html", required=True, help="file with the release notes as HTML")
    parser.add_argument("--title")
    parser.add_argument("--link", help="the release page", default=None)
    parser.add_argument("--date", help="RFC 822 date; default: now", default=None)
    parser.add_argument("--critical", action="store_true", help="mark it a security update")
    parser.add_argument("--output", help="file to write; default: stdout", default=None)
    parser.add_argument("--allow-local-http", action="store_true",
                        help="accept an http://127.0.0.1 URL (the local update test only)")
    args = parser.parse_args(argv)
    try:
        signature, length = parse_signature_line(args.signature_line)
        with open(args.notes_html, encoding="utf-8") as source:
            notes_html = source.read()
        text = appcast(
            version=args.version, build=args.build,
            minimum_system_version=args.minimum_system_version, url=args.url,
            signature=signature, length=length, notes_html=notes_html,
            title=args.title or f"EK Bridge {args.version}",
            link=args.link or release_page(args.url),
            date=args.date or email.utils.formatdate(usegmt=True),
            critical=args.critical, allow_local_http=args.allow_local_http)
    except (OSError, AppcastError) as error:
        print(f"appcast: {error}", file=sys.stderr)
        return 1
    if args.output:
        with open(args.output, "w", encoding="utf-8") as output:
            output.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
