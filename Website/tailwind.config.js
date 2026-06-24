/**
 * Tailwind config for the SwiftMiner website in Website/public.
 * This replaces the former in-browser `cdn.tailwindcss.com` runtime compiler.
 *
 * Rebuild the static stylesheet from the repository root:
 *   npx tailwindcss@3 -c Website/tailwind.config.js \
 *     -i Website/styles/tailwind.src.css \
 *     -o Website/public/assets/css/tailwind.css --minify
 */
module.exports = {
  darkMode: 'class',
  content: ['./Website/public/index.html', './Website/public/help/**/*.html'],
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
        sans: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Text', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'],
        display: ['-apple-system', 'BlinkMacSystemFont', 'SF Pro Display', 'Segoe UI', 'Roboto', 'Helvetica Neue', 'Arial', 'sans-serif'],
      }
    }
  }
}
