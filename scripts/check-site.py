#!/usr/bin/env python3
"""Verify a built site: every local reference resolves, and the basics hold.

Run at the end of scripts/build-site.sh. The Pages artifact is published exactly
as generated, so a typo in an image path ships as a broken image on the
homepage of a released app and nothing else in the project would notice. This
turns that class of mistake into a failed build.

What it checks, per HTML file in the output:
  * every local src/href resolves to a file inside the output directory
  * images carry alt text
  * the page has exactly one <h1>, and a <title>
  * internal anchors point at an id that exists on the target page
  * files referenced by <link>/<script> exist

Deliberately not checked: external URLs (network access in CI is slow, flaky and
out of scope) and CSS/JS correctness. Style rules live in site/assets/site.css,
which is a hand-written file a reviewer reads. Subtrees passed with --skip are
compiled output rather than authored pages, so the h1/alt rules are skipped
along with the reference checks.

Usage: check-site.py <output-dir> [site-url] [--skip <subdir>]...
"""

from __future__ import annotations

import os
import sys
from html.parser import HTMLParser
from urllib.parse import unquote, urlparse

# The site is published at the root of its Pages host, so an absolute reference
# like /assets/site.css maps straight onto the output directory. A reference
# that resolves outside it is a bug, not something to guess at.
# Schemes that are not ours to resolve. These are bare scheme names because
# that is what urlparse().scheme returns (no trailing colon).
SKIPPED_SCHEMES = ("http", "https", "mailto", "data", "tel", "javascript")


class PageParser(HTMLParser):
    """Collect the references and structure worth asserting on."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.refs: list[tuple[str, str, str]] = []  # (attr, value, tag)
        self.ids: set[str] = set()
        self.anchors: set[str] = set()
        self.titles = 0
        self.h1 = 0
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {key: (value or "") for key, value in attrs}

        if "id" in attributes:
            self.ids.add(attributes["id"])
        if tag == "a" and attributes.get("href", "").startswith("#"):
            self.anchors.add(attributes["href"][1:])
        if tag == "title":
            self.titles += 1
            self._in_title = True
        if tag == "h1":
            self.h1 += 1

        for attr in ("src", "href", "srcset"):
            value = attributes.get(attr)
            if value:
                self.refs.append((attr, value, tag))

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        # An empty <title></title> is as broken as a missing one.
        if self._in_title and data.strip():
            self.titles = 2  # marker: non-empty


def local_target(reference: str, page_dir: str) -> str | None:
    """Resolve a reference to an output-relative path, or None if not local."""
    if not reference or reference.startswith("#"):
        return None
    if reference.startswith("//"):
        return None

    parsed = urlparse(reference)
    if parsed.scheme in SKIPPED_SCHEMES:
        return None

    path = unquote(parsed.path)
    if not path:
        return None

    if path.startswith("/"):
        # Root-relative: relative to the published site root.
        return os.path.normpath(path.lstrip("/"))

    return os.path.normpath(os.path.join(page_dir, path))


def main(argv: list[str]) -> int:
    # Parse in one pass. Filtering the flags out and collecting the positionals
    # separately looks equivalent but is not: the value after --skip does not
    # start with "--", so it would be mistaken for a positional argument.
    positional: list[str] = []
    skips: list[str] = []
    args = argv[1:]
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--skip" and index + 1 < len(args):
            skips.append(args[index + 1].strip("/") + "/")
            index += 2
        elif arg.startswith("--"):
            sys.stderr.write("check-site: unknown option %s\n" % arg)
            return 2
        else:
            positional.append(arg)
            index += 1

    if not 1 <= len(positional) <= 2:
        sys.stderr.write(
            "usage: check-site.py <output-dir> [site-url] [--skip <subdir>]...\n"
        )
        return 2

    out_dir = os.path.abspath(positional[0])
    site_url = positional[1] if len(positional) > 1 else ""

    if not os.path.isdir(out_dir):
        sys.stderr.write("check-site: %s is not a directory\n" % out_dir)
        return 1

    problems: list[str] = []
    pages = 0
    checked_refs = 0
    skipped = 0

    for root, _dirs, files in os.walk(out_dir):
        for name in sorted(files):
            if not name.endswith(".html"):
                continue

            path = os.path.join(root, name)
            relative = os.path.relpath(path, out_dir)
            page_dir = os.path.dirname(relative)

            if any(relative.startswith(prefix) for prefix in skips):
                skipped += 1
                continue

            with open(path, encoding="utf-8") as handle:
                parser = PageParser()
                parser.feed(handle.read())
                parser.close()

            pages += 1

            if parser.titles == 0:
                problems.append("%s: no <title>" % relative)
            elif parser.titles == 1:
                problems.append("%s: empty <title>" % relative)

            if parser.h1 != 1:
                problems.append(
                    "%s: expected exactly one <h1>, found %d" % (relative, parser.h1)
                )

            for attr, value, tag in parser.refs:
                if tag == "img" and attr == "src" and not _has_alt(path, value):
                    problems.append(
                        '%s: <img src="%s"> has no alt attribute' % (relative, value)
                    )

                # Same-page anchors: local_target() ignores these, so check the
                # id against the page that is already parsed.
                if value.startswith("#") and len(value) > 1:
                    if value[1:] not in parser.ids:
                        problems.append(
                            '%s: link "%s" points at an id that is not on the page'
                            % (relative, value)
                        )
                    continue

                if attr == "srcset":
                    for candidate in value.split(","):
                        url = candidate.strip().split(" ")[0]
                        if url:
                            _resolve(url, page_dir, out_dir, relative, problems)
                            checked_refs += 1
                    continue

                target = local_target(value, page_dir)
                if target is None:
                    continue
                checked_refs += 1

                resolved = os.path.normpath(os.path.join(out_dir, target))
                if resolved != out_dir and not resolved.startswith(out_dir + os.sep):
                    problems.append(
                        '%s: reference "%s" escapes the output directory'
                        % (relative, value)
                    )
                    continue

                if os.path.isdir(resolved):
                    # A directory reference is served as its index.html.
                    resolved = os.path.join(resolved, "index.html")

                if not os.path.exists(resolved):
                    problems.append(
                        '%s: reference "%s" -> %s does not exist'
                        % (relative, value, target)
                    )
                    continue

                # Cross-page anchors must exist on the page they target.
                fragment = urlparse(value).fragment
                if fragment and resolved.endswith(".html"):
                    with open(resolved, encoding="utf-8") as handle:
                        target_parser = PageParser()
                        target_parser.feed(handle.read())
                    if fragment not in target_parser.ids:
                        problems.append(
                            '%s: link "%s" points at #%s, which is not on the target page'
                            % (relative, value, fragment)
                        )

    if site_url:
        index = os.path.join(out_dir, "index.html")
        if not os.path.isfile(index):
            problems.append("index.html is missing")
        else:
            with open(index, encoding="utf-8") as handle:
                head = handle.read()
            if site_url not in head:
                problems.append(
                    "index.html does not mention the site URL %s (canonical/OG?)"
                    % site_url
                )

    if problems:
        sys.stderr.write("check-site: %d problem(s)\n" % len(problems))
        for problem in problems:
            sys.stderr.write("  - %s\n" % problem)
        return 1

    print(
        "check-site: %d page(s), %d local reference(s) resolved%s"
        % (pages, checked_refs, ", %d skipped" % skipped if skipped else "")
    )
    return 0


def _resolve(url: str, page_dir: str, out_dir: str, relative: str, problems: list[str]) -> None:
    target = local_target(url, page_dir)
    if target is None:
        return
    if not os.path.exists(os.path.normpath(os.path.join(out_dir, target))):
        problems.append('%s: srcset entry "%s" does not exist' % (relative, url))


def _has_alt(path: str, src: str) -> bool:
    """Cheap check that the matching <img> tag carries an alt attribute."""
    with open(path, encoding="utf-8") as handle:
        content = handle.read()
    for tag in _iter_tags(content, "img"):
        if src in tag:
            return "alt=" in tag
    return False


def _iter_tags(content: str, name: str):
    """Yield each opening tag with the given name, including multi-line ones."""
    lowered = content.lower()
    needle = "<" + name
    index = 0
    while True:
        start = lowered.find(needle, index)
        if start == -1:
            return
        end = content.find(">", start)
        if end == -1:
            return
        yield content[start : end + 1]
        index = end + 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
