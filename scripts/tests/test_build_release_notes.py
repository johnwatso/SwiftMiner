from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "build_release_notes.py"
SPEC = importlib.util.spec_from_file_location("build_release_notes", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
BUILDER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILDER
SPEC.loader.exec_module(BUILDER)


CURATED = """<!doctype html>
<html lang="en"><head><title>SwiftMiner {version}</title></head>
<body>
  <main>
    <h1>SwiftMiner {version}</h1>
    <p class="meta">Version {version} &middot; Build {build}</p>
    <p class="intro">{intro}</p>
    <section>
      <h2>{heading}</h2>
      <ul><li>Something changed.</li></ul>
    </section>
  </main>
</body>
</html>
"""

# What ShipHook writes: the tip commit message, no intro and no sections.
SHIPHOOK = """<!doctype html>
<html lang="en"><head><title>SwiftMiner {version}</title></head>
<body>
  <main>
    <h1>Split MinerEngine into per-responsibility files</h1>
    <p class="meta">Version {version}</p>
    <p>Split MinerEngine into per-responsibility files</p>
  </main>
</body>
</html>
"""


class ReleaseNotesBuilderTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.notes_dir = Path(self._tmp.name) / "notes"
        self.curated_dir = Path(self._tmp.name) / "curated"
        self.site_dir = Path(self._tmp.name) / "site"
        self.notes_dir.mkdir()
        self.curated_dir.mkdir()
        self.addCleanup(self._tmp.cleanup)

    def write(self, version: str, *, build: str = "2026083014", intro: str = "A release.", heading: str = "&#128029; Fixes") -> None:
        (self.notes_dir / f"{version}.html").write_text(
            CURATED.format(version=version, build=build, intro=intro, heading=heading),
            encoding="utf-8",
        )

    def notes(self) -> list:
        return BUILDER.load_notes(self.notes_dir)

    def test_orders_versions_newest_first(self) -> None:
        for version in ["1.38", "1.38.1", "1.38.10", "1.38.2", "1.9"]:
            self.write(version)
        self.assertEqual(
            [note.version for note in self.notes()],
            ["1.38.10", "1.38.2", "1.38.1", "1.38", "1.9"],
        )

    def test_index_lists_every_page_with_its_summary_and_build(self) -> None:
        self.write("1.38.3", intro="A performance release.")
        index = BUILDER.render_index(self.notes())
        self.assertIn('<a href="./1.38.3.html">Version 1.38.3</a>', index)
        self.assertIn("A performance release.", index)
        self.assertIn("Build 2026083014", index)

    def test_index_keeps_the_glyph_from_either_heading_style(self) -> None:
        self.write("1.38.3", heading="&#128029; Fixes")
        self.write("1.31", heading='<span class="badge" aria-hidden="true">⚡</span> Performance')
        index = BUILDER.render_index(self.notes())
        self.assertIn('&#128029; <a href="./1.38.3.html">', index)
        self.assertIn('⚡ <a href="./1.31.html">', index)

    def test_publishing_copies_pages_into_the_site(self) -> None:
        self.write("1.38.3")
        self.assertEqual(BUILDER.publish_pages(self.notes_dir, self.site_dir), 1)
        self.assertTrue((self.site_dir / "1.38.3.html").exists())

    def test_a_page_shiphook_overwrote_is_reported(self) -> None:
        self.write("1.38.3")
        (self.notes_dir / "1.38.3.html").write_text(
            SHIPHOOK.format(version="1.38.3"), encoding="utf-8"
        )
        problems = BUILDER.validate(self.notes())
        self.assertTrue(any("looks like a generated page" in problem for problem in problems))
        self.assertTrue(any("no <section>" in problem for problem in problems))

    def test_a_complete_page_reports_no_problems(self) -> None:
        self.write("1.38.3")
        self.assertEqual(BUILDER.validate(self.notes()), [])

    def test_curated_page_replaces_shiphook_page_for_the_same_version(self) -> None:
        (self.notes_dir / "1.39.html").write_text(
            SHIPHOOK.format(version="1.39"), encoding="utf-8"
        )
        (self.curated_dir / "1.39.html").write_text(
            CURATED.format(
                version="1.39",
                build="2026090107",
                intro="A substantial release.",
                heading="&#127942; Esports",
            ),
            encoding="utf-8",
        )

        notes = BUILDER.load_notes(self.notes_dir, self.curated_dir)

        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0].summary, "A substantial release.")
        self.assertEqual(BUILDER.validate(notes), [])

    def test_curated_page_overwrites_generated_page_in_site_output(self) -> None:
        (self.notes_dir / "1.39.html").write_text(
            SHIPHOOK.format(version="1.39"), encoding="utf-8"
        )
        curated = CURATED.format(
            version="1.39",
            build="2026090107",
            intro="A substantial release.",
            heading="&#127942; Esports",
        )
        (self.curated_dir / "1.39.html").write_text(curated, encoding="utf-8")

        BUILDER.publish_pages(self.notes_dir, self.site_dir)
        BUILDER.publish_pages(self.curated_dir, self.site_dir)

        self.assertEqual((self.site_dir / "1.39.html").read_text(encoding="utf-8"), curated)

    def test_check_fails_when_the_sitemap_has_fallen_behind(self) -> None:
        self.write("1.38.3")
        sitemap = Path(self._tmp.name) / "sitemap.xml"
        sitemap.write_text(
            "<urlset><url><loc>https://swiftminer.app/release-notes/</loc></url></urlset>",
            encoding="utf-8",
        )
        self.assertEqual(BUILDER.check(self.notes(), sitemap), 1)

    def test_check_passes_once_the_sitemap_lists_the_page(self) -> None:
        self.write("1.38.3")
        sitemap = Path(self._tmp.name) / "sitemap.xml"
        sitemap.write_text(
            "<urlset><url><loc>https://swiftminer.app/release-notes/1.38.3.html</loc>"
            "<lastmod>2026-08-30</lastmod></url></urlset>",
            encoding="utf-8",
        )
        self.assertEqual(BUILDER.check(self.notes(), sitemap), 0)

    def test_sitemap_keeps_recorded_lastmod_and_adds_missing_pages(self) -> None:
        self.write("1.38.3")
        self.write("1.38.2")
        sitemap = Path(self._tmp.name) / "sitemap.xml"
        sitemap.write_text(
            "<urlset>\n"
            "  <url><loc>https://swiftminer.app/</loc><lastmod>2026-06-22</lastmod></url>\n"
            "  <url><loc>https://swiftminer.app/release-notes/1.38.2.html</loc>"
            "<lastmod>2026-06-22</lastmod><changefreq>monthly</changefreq><priority>0.3</priority></url>\n"
            "</urlset>\n",
            encoding="utf-8",
        )
        BUILDER.update_sitemap(sitemap, self.notes())
        written = sitemap.read_text(encoding="utf-8")
        self.assertIn("release-notes/1.38.2.html</loc><lastmod>2026-06-22", written)
        self.assertIn("release-notes/1.38.3.html", written)
        self.assertIn("https://swiftminer.app/</loc>", written)


if __name__ == "__main__":
    unittest.main()
