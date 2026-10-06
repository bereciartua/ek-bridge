#!/usr/bin/env python3
"""Release notes from CHANGELOG.md.

Prints the "## [VERSION]" section of the changelog, without its heading, as
Markdown for the GitHub release or as HTML for the Sparkle appcast. Relative
links (docs/MCP.md, CHANGELOG.md#...) become links into the release's tag on
GitHub, because neither a release page nor Sparkle's window can resolve them.

Usage: release_notes.py VERSION [--format markdown|html] [--changelog FILE]
                        [--repo OWNER/NAME]

The HTML converter covers what the changelog uses: "###" headings, paragraphs,
"-" lists nested by indentation, **bold**, `code` and [links](url). Anything
else is escaped text.
"""

import argparse
import html
import re
import sys
from pathlib import Path

DEFAULT_REPO = "bereciartua/ek-bridge"
DEFAULT_CHANGELOG = Path(__file__).resolve().parent.parent / "CHANGELOG.md"

LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
INLINE = re.compile(r"(`[^`]+`)|(\*\*[^*]+\*\*)|(\[[^\]]+\]\([^)\s]+\))")


class NotesError(Exception):
    pass


def section(changelog: str, version: str) -> str:
    """The body of "## [version]" up to the next "## " heading, stripped."""
    lines = changelog.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith(f"## [{version}]"):
            start = index + 1
            break
    if start is None:
        raise NotesError(f'CHANGELOG.md has no "## [{version}]" section')
    end = len(lines)
    for index in range(start, len(lines)):
        if lines[index].startswith("## "):
            end = index
            break
    body = "\n".join(lines[start:end]).strip("\n")
    if not body.strip():
        raise NotesError(f'the "## [{version}]" section is empty')
    return body


def absolute_url(url: str, version: str, repo: str) -> str:
    """Repository-relative links point into the release's tag on GitHub."""
    if re.match(r"^[a-z][a-z0-9+.-]*:", url) or url.startswith("#") or url.startswith("//"):
        return url
    return f"https://github.com/{repo}/blob/v{version}/{url.lstrip('./')}"


def markdown(body: str, version: str, repo: str) -> str:
    return LINK.sub(lambda m: f"[{m.group(1)}]({absolute_url(m.group(2), version, repo)})", body)


def inline_html(text: str, version: str, repo: str) -> str:
    parts = []
    position = 0
    for match in INLINE.finditer(text):
        parts.append(html.escape(text[position:match.start()]))
        token = match.group(0)
        if token.startswith("`"):
            parts.append(f"<code>{html.escape(token[1:-1])}</code>")
        elif token.startswith("**"):
            parts.append(f"<strong>{inline_html(token[2:-2], version, repo)}</strong>")
        else:
            link = LINK.fullmatch(token)
            url = absolute_url(link.group(2), version, repo)
            parts.append(f'<a href="{html.escape(url, quote=True)}">'
                         f"{inline_html(link.group(1), version, repo)}</a>")
        position = match.end()
    parts.append(html.escape(text[position:]))
    return "".join(parts)


def to_html(body: str, version: str, repo: str) -> str:
    """A small block converter: headings, paragraphs and nested "-" lists."""
    out = []
    paragraph = []
    list_depths = []  # indentation of each open <ul>

    def flush_paragraph():
        if paragraph:
            out.append(f"<p>{inline_html(' '.join(paragraph), version, repo)}</p>")
            paragraph.clear()

    def close_lists(down_to=-1):
        while list_depths and list_depths[-1] > down_to:
            list_depths.pop()
            out.append("</li></ul>")

    for raw in body.splitlines():
        line = raw.rstrip()
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if not stripped:
            flush_paragraph()
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if heading and indent == 0:
            flush_paragraph()
            close_lists()
            level = min(len(heading.group(1)) + 1, 6)  # "###" in the file is <h4> here
            out.append(f"<h{level}>{inline_html(heading.group(2), version, repo)}</h{level}>")
            continue
        item = re.match(r"^[-*]\s+(.*)$", stripped)
        if item:
            flush_paragraph()
            if list_depths and indent > list_depths[-1]:
                out.append(f"<ul><li>{inline_html(item.group(1), version, repo)}")
                list_depths.append(indent)
            else:
                close_lists(indent)
                if list_depths and list_depths[-1] == indent:
                    out.append(f"</li><li>{inline_html(item.group(1), version, repo)}")
                else:
                    out.append(f"<ul><li>{inline_html(item.group(1), version, repo)}")
                    list_depths.append(indent)
            continue
        if list_depths and indent > list_depths[-1]:
            # A continuation line inside the current list item.
            out[-1] += " " + inline_html(stripped, version, repo)
            continue
        close_lists()
        paragraph.append(stripped)
    flush_paragraph()
    close_lists()
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("version")
    parser.add_argument("--format", choices=["markdown", "html"], default="markdown")
    parser.add_argument("--changelog", type=Path, default=DEFAULT_CHANGELOG)
    parser.add_argument("--repo", default=DEFAULT_REPO)
    args = parser.parse_args(argv)
    try:
        body = section(args.changelog.read_text(encoding="utf-8"), args.version)
    except (OSError, NotesError) as error:
        print(f"release_notes: {error}", file=sys.stderr)
        return 1
    if args.format == "html":
        sys.stdout.write(to_html(body, args.version, args.repo))
    else:
        sys.stdout.write(markdown(body, args.version, args.repo) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
