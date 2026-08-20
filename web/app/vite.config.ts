import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Same base-path handling as the prototype: GitHub Pages serves project sites
// from a subpath, so the deploy workflow passes BASE_PATH from
// actions/configure-pages. Unset locally means serve from "/".
const rawBase = process.env.BASE_PATH ?? '/'
const base = rawBase.endsWith('/') ? rawBase : `${rawBase}/`

export default defineConfig({
  base,
  plugins: [react()],
  server: { host: '0.0.0.0', port: 5173 },
})
