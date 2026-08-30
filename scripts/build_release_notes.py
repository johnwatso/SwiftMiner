#!/usr/bin/env python3
"""Publish the release notes ShipHook writes under docs/ into the website.

ShipHook can only write release notes to `docs/release-notes/`, so that directory is
the source of truth: every page is authored (or regenerated) there, and the published
site is built from it. This script does that build:

  1. copies every `docs/release-notes/*.html` page into `Website/public/release-notes/`
  2. writes the release-notes index from those pages, newest version first
  3. refreshes the release-notes URLs in `Website/public/sitemap.xml`

Both generated lists used to be maintained by hand and had drifted — the index was
missing 11 pages and the sitemap 34 — which is the whole reason they are generated now.

Run it after editing or adding a page, and commit the result. The website deploy
workflow runs it too, so a ShipHook release reaches the site without a manual step.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import sys
from datetime import date
from pathlib import Path

SITE_ORIGIN = "https://swiftminer.app"

INDEX_HEAD = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SwiftMiner Release Notes</title>
  <meta name="description" content="Release notes and changelog for SwiftMiner, the native macOS Twitch Drops automation app.">
  <link rel="canonical" href="https://swiftminer.app/release-notes/">
    <link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
  <link rel="icon" type="image/png" sizes="32x32" href="/favicon-32x32.png">
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      padding: 32px 20px 48px;
      font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background: #f4f6f8;
      color: #0f1720;
    }
    main {
      max-width: 760px;
      margin: 0 auto;
      padding: 28px;
      border-radius: 22px;
      background: rgba(255, 255, 255, 0.86);
      box-shadow: 0 20px 60px rgba(15, 23, 32, 0.10);
    }
    h1 { margin: 0 0 6px; font-size: 30px; line-height: 1.15; }
    .meta { margin: 0 0 24px; color: #52606d; font-size: 14px; }
    h2 { margin: 28px 0 6px; font-size: 20px; }
    .summary { margin: 0 0 4px; color: #384454; }
    .build { margin: 0 0 20px; color: #52606d; font-size: 13px; }
    a { color: #0a67a3; text-decoration: none; }
    a:hover { text-decoration: underline; }
    @media (prefers-color-scheme: dark) {
      body { background: #0b1015; color: #edf2f7; }
      main {
        background: rgba(15, 23, 32, 0.88);
        box-shadow: 0 24px 70px rgba(0, 0, 0, 0.45);
      }
      .meta { color: #9fb0c2; }
      .summary { color: #c8d3df; }
      .build { color: #9fb0c2; }
      a { color: #73c3ff; }
    }
  </style>
</head>
<body>
  <main>
    <h1>SwiftMiner Release Notes</h1>
    <p class="meta">Every release, newest first. Generated from the release-notes pages by scripts/build_release_notes.py.</p>
"""

INDEX_TAIL = """  </main>
</body>
</html>
"""


class ReleaseNote:
    def __init__(self, path: Path):
        self.path = path
        self.filename = path.name
        self.version = path.stem
        markup = path.read_text(encoding="utf-8")
        self.summary = self._summary(markup)
        self.build = self._build(markup)
        self.emoji = self._emoji(markup)
        self.title = self._title(markup)
        self.section_count = len(re.findall(r"<section[\s>]", markup))

    @staticmethod
    def _text(markup: str) -> str:
        without_tags = re.sub(r"<[^>]+>", " ", markup)
        return re.sub(r"\s+", " ", without_tags).strip()

    def _title(self, markup: str) -> str:
        heading = re.search(r"<h1[^>]*>(.*?)</h1>", markup, re.DOTALL)
        return self._text(heading.group(1)) if heading else ""

    def _summary(self, markup: str) -> str:
        intro = re.search(r'<p class="intro">(.*?)</p>', markup, re.DOTALL)
        if intro:
            return self._text(intro.group(1))
        # ShipHook's own pages carry no intro: fall back to the first body paragraph
        # that is not the version line.
        for match in re.finditer(r"<p(?![^>]*class=\"meta\")[^>]*>(.*?)</p>", markup, re.DOTALL):
            text = self._text(match.group(1))
            if text and not text.startswith("Version "):
                return text
        return ""

    def _build(self, markup: str) -> str:
        meta = re.search(r'<p class="meta">(.*?)</p>', markup, re.DOTALL)
        if not meta:
            return ""
        found = re.search(r"Build\s+([0-9]+)", self._text(meta.group(1)))
        return found.group(1) if found else ""

    def _emoji(self, markup: str) -> str:
        """The leading glyph of the page's first section heading, so the index keeps the
        character each release was given rather than inventing one.

        Headings come in two shapes across the archive: the glyph written directly
        (`<h2>&#128029; Fixes`) and the older badge span (`<h2><span class="badge">⚡</span>`).
        Both are read, otherwise most of the back catalogue loses its character."""
        heading = re.search(r"<h2[^>]*>(.*?)</h2>", markup, re.DOTALL)
        if not heading:
            return ""
        inner = heading.group(1)
        entity = re.match(r"\s*(&#\d+;)", inner)
        if entity:
            return entity.group(1)
        text = self._text(inner)
        glyphs = re.match(r"([^\w\s]+)", text)
        return glyphs.group(1) if glyphs else ""

    @property
    def sort_key(self) -> tuple[int, ...]:
        parts = []
        for component in self.version.split("."):
            digits = re.sub(r"[^0-9]", "", component)
            parts.append(int(digits) if digits else 0)
        while len(parts) < 4:
            parts.append(0)
        return tuple(parts)


def validate(notes: list[ReleaseNote]) -> list[str]:
    """Structural problems that mean a page is not a finished release note.

    ShipHook writes its own `docs/release-notes/<version>.html` at every release,
    generated from the tip commit message, and it lands on top of whatever curated page
    was there. That page has no intro and no sections, so these checks turn a silent
    overwrite into a red build."""
    problems: list[str] = []
    for note in notes:
        if note.title != f"SwiftMiner {note.version}":
            problems.append(
                f"{note.filename}: title is {note.title!r}, expected 'SwiftMiner {note.version}' "
                "— looks like a generated page, not a release note"
            )
        if not note.summary:
            problems.append(f"{note.filename}: no intro paragraph to summarise the release")
        if note.section_count == 0:
            problems.append(f"{note.filename}: no <section> — nothing describes what changed")
    return problems


def load_notes(notes_dir: Path) -> list[ReleaseNote]:
    notes = [
        ReleaseNote(path)
        for path in sorted(notes_dir.glob("*.html"))
        if path.name != "index.html"
    ]
    if not notes:
        raise SystemExit(f"No release-note pages found in {notes_dir}")
    return sorted(notes, key=lambda note: note.sort_key, reverse=True)


def render_index(notes: list[ReleaseNote]) -> str:
    lines = [INDEX_HEAD]
    for note in notes:
        prefix = f"{note.emoji} " if note.emoji else ""
        lines.append(
            f'    <h2>{prefix}<a href="./{note.filename}">Version {html.escape(note.version)}</a></h2>\n'
        )
        if note.summary:
            lines.append(f'    <p class="summary">{html.escape(note.summary)}</p>\n')
        if note.build:
            lines.append(f'    <p class="build">Build {html.escape(note.build)}</p>\n')
    lines.append(INDEX_TAIL)
    return "".join(lines)


def publish_pages(notes_dir: Path, site_dir: Path) -> int:
    site_dir.mkdir(parents=True, exist_ok=True)
    copied = 0
    for path in sorted(notes_dir.glob("*.html")):
        if path.name == "index.html":
            continue
        shutil.copyfile(path, site_dir / path.name)
        copied += 1
    return copied


def update_sitemap(sitemap: Path, notes: list[ReleaseNote]) -> int:
    """Replace the release-notes URLs with one entry per page, keeping the `lastmod`
    already recorded for a page so regenerating does not churn every date."""
    if not sitemap.exists():
        return 0

    markup = sitemap.read_text(encoding="utf-8")
    existing_lastmod = dict(
        re.findall(
            rf"<loc>{re.escape(SITE_ORIGIN)}/release-notes/([^<]*\.html)</loc><lastmod>([^<]+)</lastmod>",
            markup,
        )
    )
    today = date.today().isoformat()

    entries = [
        f"  <url><loc>{SITE_ORIGIN}/release-notes/{note.filename}</loc>"
        f"<lastmod>{existing_lastmod.get(note.filename, today)}</lastmod>"
        f"<changefreq>monthly</changefreq><priority>0.3</priority></url>"
        for note in notes
    ]

    page_line = re.compile(
        rf"^\s*<url><loc>{re.escape(SITE_ORIGIN)}/release-notes/[^<]*\.html</loc>.*$\n?",
        re.MULTILINE,
    )
    first_match = page_line.search(markup)
    markup = page_line.sub("", markup)

    block = "\n".join(entries) + "\n"
    if first_match:
        # Keep the generated block where the hand-written one was.
        insert_at = first_match.start()
        markup = markup[:insert_at] + block + markup[insert_at:]
    else:
        markup = markup.replace("</urlset>", block + "</urlset>")

    sitemap.write_text(markup, encoding="utf-8")
    return len(entries)


def check(notes: list[ReleaseNote], sitemap: Path) -> int:
    """Report anything a release would otherwise ship broken: a page that is not a
    finished release note, or a sitemap that has fallen behind the pages."""
    problems = validate(notes)

    if sitemap.exists():
        listed = set(
            re.findall(
                rf"<loc>{re.escape(SITE_ORIGIN)}/release-notes/([^<]*\.html)</loc>", sitemap.read_text(encoding="utf-8")
            )
        )
        missing = sorted({note.filename for note in notes} - listed)
        if missing:
            problems.append(
                f"{sitemap.name} is missing {len(missing)} page(s): {', '.join(missing)} "
                "— run scripts/build_release_notes.py and commit the result"
            )

    for problem in problems:
        print(f"::error::{problem}")
    if problems:
        print(f"{len(problems)} release-note problem(s) found")
        return 1

    print(f"Checked {len(notes)} release-note pages: all complete and listed")
    return 0


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes-dir", type=Path, default=root / "docs" / "release-notes")
    parser.add_argument("--site-dir", type=Path, default=root / "Website" / "public" / "release-notes")
    parser.add_argument("--sitemap", type=Path, default=root / "Website" / "public" / "sitemap.xml")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate the pages and the sitemap without writing anything. Used by CI so a "
        "page ShipHook overwrote, or a sitemap left unregenerated, fails the build.",
    )
    args = parser.parse_args()

    notes = load_notes(args.notes_dir)
    if args.check:
        return check(notes, args.sitemap)

    problems = validate(notes)
    for problem in problems:
        print(f"warning: {problem}")

    copied = publish_pages(args.notes_dir, args.site_dir)
    (args.site_dir / "index.html").write_text(render_index(notes), encoding="utf-8")
    sitemap_entries = update_sitemap(args.sitemap, notes)

    print(f"Published {copied} release-note pages from {args.notes_dir}")
    print(f"Indexed {len(notes)} versions, newest {notes[0].version}")
    print(f"Listed {sitemap_entries} release-note URLs in {args.sitemap.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
