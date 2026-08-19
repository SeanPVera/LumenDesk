import fs from 'node:fs'
import fsp from 'node:fs/promises'
import path from 'node:path'

// Serving the web client from the bridge itself puts the page and the API on
// the same origin. That removes CORS and the browser's local-network
// permission from the picture entirely — the page is no longer a remote site
// reaching into the local network, it *is* the local service.

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
}

/** True when the directory looks like a built client (has an index.html). */
export function isBuiltApp(dir) {
  try {
    return fs.statSync(path.join(dir, 'index.html')).isFile()
  } catch {
    return false
  }
}

/**
 * Resolve a URL path to a file inside root, or null if it escapes.
 * Traversal is rejected by comparing the resolved path against the root
 * rather than by pattern-matching the request.
 */
function resolveWithin(root, urlPath) {
  let decoded
  try {
    decoded = decodeURIComponent(urlPath)
  } catch {
    return null
  }
  if (decoded.includes('\0')) return null

  const resolved = path.resolve(root, `.${path.posix.normalize(decoded)}`)
  const prefix = root.endsWith(path.sep) ? root : root + path.sep
  if (resolved !== root && !resolved.startsWith(prefix)) return null
  return resolved
}

async function readFileIfPresent(file) {
  try {
    const stat = await fsp.stat(file)
    if (!stat.isFile()) return null
    return { body: await fsp.readFile(file), stat }
  } catch {
    return null
  }
}

/**
 * Serve `urlPath` from `root`. Unknown paths fall back to index.html so the
 * client keeps working if it ever grows routes. Returns false when nothing
 * was served, letting the caller produce its own 404.
 */
export async function serveStatic(root, urlPath, res) {
  const target = resolveWithin(root, urlPath)
  if (!target) {
    res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' })
    res.end('forbidden')
    return true
  }

  const candidates = [target]
  if (urlPath.endsWith('/')) candidates.push(path.join(target, 'index.html'))
  candidates.push(path.join(root, 'index.html')) // single-page fallback

  for (const candidate of candidates) {
    const found = await readFileIfPresent(candidate)
    if (!found) continue
    const type = CONTENT_TYPES[path.extname(candidate).toLowerCase()] ?? 'application/octet-stream'
    res.writeHead(200, {
      'Content-Type': type,
      'Content-Length': found.body.length,
      // Hashed asset names make long caching safe, but the bridge is local and
      // may be upgraded under the user's feet, so stay conservative.
      'Cache-Control': 'no-cache',
    })
    res.end(found.body)
    return true
  }

  return false
}
