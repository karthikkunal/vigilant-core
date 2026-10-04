#!/usr/bin/env python3
"""Render a Markdown subset to HTML, with no third-party dependencies.

Written for exactly one job: publishing docs/privacy-policy.md to
<https://vigilant-core-9a0e4f.gitlab.io/privacy-policy.html>, which Google Play
and the App Store both fetch and read before accepting a build.

The alternative considered was a real Markdown library. It was rejected on
purpose: the Pages job runs on a stock runner, and adding a package fetch (or a
pinned transitive tree) to format one trusted document that lives in this
repository is a poor trade. This covers the constructs the policy actually uses
— headings, paragraphs, rules, blockquotes, bullet and numbered lists, pipe
tables, and the inline forms strong/em/code/link/autolink — and is exercised by
scripts/check-site.sh, which fails if the rendered output loses structure.

Deliberately not supported (and not used by the policy): fenced code blocks,
nested block constructs inside list items, reference links, setext headings,
raw HTML passthrough, and pipe escaping inside code spans. If the policy ever
needs one of them, add it here rather than reaching for a dependency.
"""

from __future__ import annotations

import re
import sys

# Sentinels for inline placeholders. NUL cannot appear in the input, and the
# policy contains neither of these tokens, so no collision is possible.
_CODE_TOKEN = "\x00code:%d\x00"
_PLACEHOLDER_RE = re.compile(r"\x00code:(\d+)\x00")

_LIST_ITEM_RE = re.compile(r"^(?P<indent> *)(?P<bullet>[-*+]|\d{1,9}[.)])(?: (?P<text>.*))?$")
_HEADING_RE = re.compile(r"^(?P<hashes>#{1,6}) (?P<text>.+?)(?: +#+)?$")
_RULE_RE = re.compile(r"^ {0,3}(?:-{3,}|\*{3,}|_{3,})[ \t]*$")
_TABLE_DELIM_RE = re.compile(r"^ {0,3}\|?[ \t]*:?-{1,}:?[ \t]*(?:\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$")
_FENCE_RE = re.compile(r"^ {0,3}(```|~~~)")


def escape(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render_inline(text: str) -> str:
    """Escape, then apply the inline forms from the inside out."""
    codes: list[str] = []

    def stash_code(match: re.Match[str]) -> str:
        codes.append(match.group(1))
        return _CODE_TOKEN % (len(codes) - 1)

    # 1. Code spans first, so their contents are never treated as emphasis.
    text = re.sub(r"`([^`]+)`", stash_code, text)

    # 2. Everything below operates on escaped text.
    text = escape(text)

    # 3. Autolinks, then explicit links.
    text = re.sub(
        r"&lt;((?:https?|mailto):[^&\s]+?)&gt;",
        lambda m: '<a href="%s">%s</a>' % (m.group(1), m.group(1)),
        text,
    )
    text = re.sub(
        r"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)",
        lambda m: '<a href="%s">%s</a>' % (m.group(2), m.group(1)),
        text,
    )

    # 4. Emphasis. Strong is matched before emphasis so ** is never split.
    text = re.sub(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?=\S)([^*]+?)(?<=\S)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"(?<![\w_])_(?=\S)([^_]+?)(?<=\S)_(?![\w_])", r"<em>\1</em>", text)

    # 5. Stashed code spans, re-escaped but not re-processed.
    text = _PLACEHOLDER_RE.sub(
        lambda m: "<code>%s</code>" % escape(codes[int(m.group(1))]), text
    )
    return text


def split_row(line: str) -> list[str]:
    """Split a pipe-table row into cells, honouring \\| escapes."""
    stripped = line.strip()
    if stripped.startswith("|"):
        stripped = stripped[1:]
    if stripped.endswith("|") and not stripped.endswith("\\|"):
        stripped = stripped[:-1]

    cells: list[str] = []
    current: list[str] = []
    index = 0
    while index < len(stripped):
        char = stripped[index]
        if char == "\\" and index + 1 < len(stripped) and stripped[index + 1] == "|":
            current.append("|")
            index += 2
            continue
        if char == "|":
            cells.append("".join(current).strip())
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    cells.append("".join(current).strip())
    return cells


def alignments_from(delimiter: str) -> list[str]:
    aligns: list[str] = []
    for cell in split_row(delimiter):
        left = cell.startswith(":")
        right = cell.endswith(":")
        if left and right:
            aligns.append("center")
        elif right:
            aligns.append("right")
        elif left:
            aligns.append("left")
        else:
            aligns.append("")
    return aligns


def render_table(header_row: str, delimiter: str, body_rows: list[str]) -> str:
    header = split_row(header_row)
    aligns = alignments_from(delimiter)
    if len(aligns) < len(header):
        aligns += [""] * (len(header) - len(aligns))

    out = ["<table>", "<thead>", "<tr>"]
    for cell, align in zip(header, aligns):
        style = ' style="text-align:%s"' % align if align else ""
        out.append("<th%s>%s</th>" % (style, render_inline(cell)))
    out += ["</tr>", "</thead>", "<tbody>"]

    for row in body_rows:
        cells = split_row(row)
        out.append("<tr>")
        for index in range(len(header)):
            cell = cells[index] if index < len(cells) else ""
            align = aligns[index] if index < len(aligns) else ""
            style = ' style="text-align:%s"' % align if align else ""
            out.append("<td%s>%s</td>" % (style, render_inline(cell)))
        out.append("</tr>")

    out += ["</tbody>", "</table>"]
    return "".join(out)


def render_list(items: list[tuple[int, str]], ordered: bool) -> str:
    tag = "ol" if ordered else "ul"
    out = ["<%s>" % tag]
    for _, text in items:
        out.append("<li>%s</li>" % render_inline(text))
    out.append("</%s>" % tag)
    return "".join(out)


def starts_block(line: str) -> bool:
    """True when a line cannot continue the paragraph above it."""
    stripped = line.strip()
    if not stripped:
        return True
    if _HEADING_RE.match(stripped) or _RULE_RE.match(stripped) or _FENCE_RE.match(stripped):
        return True
    if stripped.startswith(">"):
        return True
    match = _LIST_ITEM_RE.match(stripped)
    if match and not stripped.startswith(" " * 4):
        return True
    # A pipe-table delimiter row ends the paragraph above it.
    return bool(_TABLE_DELIM_RE.match(stripped))


def render_blocks(lines: list[str]) -> str:
    out: list[str] = []
    index = 0
    total = len(lines)

    while index < total:
        line = lines[index]
        stripped = line.strip()

        if not stripped:
            index += 1
            continue

        if _FENCE_RE.match(stripped):
            # Unsupported by design; surface it rather than silently mangling it.
            sys.stderr.write("build-site: fenced code block is not supported\n")
            index += 1
            continue

        if _RULE_RE.match(stripped):
            out.append("<hr>")
            index += 1
            continue

        heading = _HEADING_RE.match(stripped)
        if heading:
            level = len(heading.group("hashes"))
            out.append(
                "<h%d>%s</h%d>" % (level, render_inline(heading.group("text")), level)
            )
            index += 1
            continue

        if stripped.startswith(">"):
            inner: list[str] = []
            while index < total:
                current = lines[index]
                if current.strip().startswith(">"):
                    inner.append(re.sub(r"^\s{0,3}>\s?", "", current))
                    index += 1
                elif current.strip() and not starts_block(current):
                    # Lazy continuation of the quoted paragraph.
                    inner.append(current)
                    index += 1
                else:
                    break
            out.append("<blockquote>%s</blockquote>" % render_blocks(inner))
            continue

        if (
            stripped.startswith("|")
            and index + 1 < total
            and _TABLE_DELIM_RE.match(lines[index + 1].strip())
        ):
            header_row = lines[index]
            delimiter = lines[index + 1].strip()
            index += 2  # header + alignment row
            body_rows: list[str] = []
            while index < total and lines[index].strip().startswith("|"):
                body_rows.append(lines[index])
                index += 1
            out.append(render_table(header_row, delimiter, body_rows))
            continue

        list_match = _LIST_ITEM_RE.match(stripped)
        if list_match and not line.startswith(" " * 4):
            ordered = list_match.group("bullet")[-1] in ".)"
            items: list[tuple[int, str]] = []
            while index < total:
                current = lines[index]
                if not current.strip():
                    break
                match = (
                    _LIST_ITEM_RE.match(current.strip())
                    if not current.startswith(" " * 4)
                    else None
                )
                if not match:
                    # Lazy continuation lines belong to the item above.
                    if items and not starts_block(current):
                        indent, text = items[-1]
                        items[-1] = (indent, text + " " + current.strip())
                        index += 1
                        continue
                    break
                items.append((len(match.group("indent")), match.group("text") or ""))
                index += 1
            out.append(render_list(items, ordered))
            continue

        # Paragraph: consume until a blank line or the start of another block.
        paragraph = [stripped]
        index += 1
        while index < total and not starts_block(lines[index]):
            paragraph.append(lines[index].strip())
            index += 1
        out.append("<p>%s</p>" % render_inline(" ".join(paragraph)))

    return "\n".join(out)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.stderr.write("usage: markdown_to_html.py <input.md>\n")
        return 2

    with open(argv[1], encoding="utf-8") as handle:
        source = handle.read()

    source = source.replace("\r\n", "\n").replace("\r", "\n")
    html = render_blocks(source.split("\n"))

    sys.stdout.write(html)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
