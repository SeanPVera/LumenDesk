import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages serves project sites from a subpath (https://<user>.github.io/<repo>/),
// so the build needs a matching `base` or every asset URL 404s. The deploy workflow
// passes the path reported by actions/configure-pages, which is "/" for a custom
// domain or user site. Local `dev`/`preview` runs leave it unset and serve from "/".
const rawBase = process.env.BASE_PATH ?? '/'
const base = rawBase.endsWith('/') ? rawBase : `${rawBase}/`

export default defineConfig({
  base,
  plugins: [react()],
  server: { host: '0.0.0.0', port: 4173 },
})
