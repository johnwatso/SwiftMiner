/**
 * Tailwind config for the SwiftMiner landing page (docs/index.html).
 * This replaces the former in-browser `cdn.tailwindcss.com` runtime compiler.
 *
 * Rebuild the static stylesheet after editing index.html classes:
 *   cd docs && npx tailwindcss@3 -c tailwind.config.js \
 *     -i assets/css/tailwind.src.css -o assets/css/tailwind.css --minify
 */
module.exports = {
  darkMode: 'class',
  content: ['./index.html'],
  theme: {
    extend: {
      colors: {
        brand: {
          dark: '#090514',
          purple: '#9333ea',
          violet: '#7c3aed',
          cyan: '#00e5ff',
          magenta: '#ff007f',
          accent: '#00e5ff',
          border: 'rgba(255, 255, 255, 0.08)'
        }
      },
      fontFamily: {
        sans: ['Inter', '-apple-system', 'BlinkMacSystemFont', 'system-ui', 'sans-serif'],
        display: ['Outfit', '-apple-system', 'BlinkMacSystemFont', 'system-ui', 'sans-serif'],
      }
    }
  }
}
