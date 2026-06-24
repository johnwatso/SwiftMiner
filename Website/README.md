# SwiftMiner Website

This folder contains the production website published at
[swiftminer.app](https://swiftminer.app).

## Structure

- `public/` is the exact static site deployed to GitHub Pages.
- `public/appcast.xml` and `public/beta/appcast.xml` are release-critical
  Sparkle feeds managed by ShipHook.
- `public/release-notes/` contains the stable release-note archive.
- `public/help/` contains the help and knowledge-base pages.
- `styles/` contains stylesheet source files that are not published directly.
- `tailwind.config.js` configures the generated Tailwind stylesheet.

## Editing

Most pages are plain HTML, CSS, and JavaScript. After changing Tailwind classes,
rebuild the generated stylesheet from the repository root:

```sh
npx tailwindcss@3 -c Website/tailwind.config.js \
  -i Website/styles/tailwind.src.css \
  -o Website/public/assets/css/tailwind.css --minify
```

Do not edit appcast version or build fields during ordinary website work.
ShipHook owns those fields. The only manual appcast edit is the documented
post-release EdDSA signature step.

## Deployment

`.github/workflows/deploy-website.yml` uploads `Website/public/` as the GitHub
Pages artifact whenever website files change on `main`. The contents of
`public/` become the domain root, so public URLs remain `/appcast.xml`,
`/help/`, `/download/`, and `/release-notes/`.
