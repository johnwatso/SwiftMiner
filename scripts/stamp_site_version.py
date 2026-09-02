#!/usr/bin/env python3
"""Stamp the released version into the website's static fallbacks.

The landing page upgrades its version text and download link at runtime from the
GitHub releases API, but that is an unauthenticated cross-origin fetch against a
60-request/hour/IP limit. Whenever it fails the page falls back to whatever is
baked into the HTML, so those literals have to be right. Nothing updated them,
and they had drifted from 1.32 to eight releases behind.

`docs/appcast.xml` is the source of truth: ShipHook writes it, it is what tells
every installed copy which build is current, and the deploy workflow already
consumes it. This reads the newest item from it and rewrites the literals in
place. Read-only with respect to the appcast — see the warning in AGENTS.md.

Run with --check to fail instead of writing (used as a CI guard).
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from xml.etree import ElementTree

REPO_ROOT = Path(__file__).resolve().parent.parent
APPCAST = REPO_ROOT / "docs" / "appcast.xml"
SITE = REPO_ROOT / "Website" / "public"

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"


class StampError(RuntimeError):
    pass


def latest_release() -> tuple[str, str]:
    """(short version, download URL) of the newest appcast item."""
    if not APPCAST.is_file():
        raise StampError(f"no appcast at {APPCAST}")

    root = ElementTree.parse(APPCAST).getroot()
    items = root.findall(".//item")
    if not items:
        raise StampError(f"{APPCAST} has no <item> entries")

    def build_number(item: ElementTree.Element) -> int:
        text = (item.findtext(f"{{{SPARKLE_NS}}}version") or "").strip()
        return int(text) if text.isdigit() else -1

    newest = max(items, key=build_number)
    version = (newest.findtext(f"{{{SPARKLE_NS}}}shortVersionString") or "").strip()
    enclosure = newest.find("enclosure")
    url = enclosure.get("url", "").strip() if enclosure is not None else ""

    if not version:
        raise StampError("newest appcast item has no sparkle:shortVersionString")
    if not url:
        raise StampError(f"appcast item {version} has no enclosure url")
    return version, url


def substitutions(version: str, url: str) -> list[tuple[Path, str, str]]:
    """(file, search regex, replacement) — each must match exactly once."""
    version_re = r"[0-9]+\.[0-9]+(?:\.[0-9]+)?"
    index = SITE / "index.html"
    download = SITE / "download" / "index.html"
    return [
        # Structured data. No script touches this one, so a stale value is served
        # to search engines verbatim.
        (index,
         rf'("softwareVersion":\s*")({version_re})(")',
         rf"\g<1>{version}\g<3>"),
        # Hero: "Latest release: v1.40.1"
        (index,
         rf"(<span data-latest-version>v?)({version_re})(</span>)",
         rf"\g<1>{version}\g<3>"),
        # Footer CTA: "Version 1.40.1"
        (index,
         rf"(<span data-latest-version-raw>v?)({version_re})(</span>)",
         rf"\g<1>{version}\g<3>"),
        # Manual download link, shown when the redirect does not fire.
        (download,
         r'(id="manual-download" href=")([^"]+)(")',
         rf"\g<1>{url}\g<3>"),
        # Same URL again as the redirect script's fallback.
        (download,
         r"(var fallback = ')([^']+)(')",
         rf"\g<1>{url}\g<3>"),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report drift and exit non-zero instead of writing")
    args = parser.parse_args()

    try:
        version, url = latest_release()
    except StampError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    print(f"appcast reports {version} ({url})")

    edits: dict[Path, str] = {}
    drift: list[str] = []
    for path, pattern, replacement in substitutions(version, url):
        if not path.is_file():
            print(f"error: missing {path}", file=sys.stderr)
            return 2
        text = edits.get(path, path.read_text(encoding="utf-8"))
        updated, count = re.subn(pattern, replacement, text, count=1)
        if count != 1:
            # A miss means the markup moved; fail loudly rather than deploy a
            # page whose version silently stopped being stamped.
            print(f"error: pattern did not match in {path.relative_to(REPO_ROOT)}: {pattern}",
                  file=sys.stderr)
            return 2
        if updated != text:
            drift.append(str(path.relative_to(REPO_ROOT)))
        edits[path] = updated

    if not drift:
        print("already current, nothing to stamp")
        return 0

    if args.check:
        print("stale version literals in: " + ", ".join(sorted(set(drift))), file=sys.stderr)
        print("run: python3 scripts/stamp_site_version.py", file=sys.stderr)
        return 1

    for path, text in edits.items():
        path.write_text(text, encoding="utf-8")
    print("stamped: " + ", ".join(sorted(set(drift))))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
