#!/usr/bin/env node
// Build on the target OS using standard platform tools, a locked npm build,
// and an official runtime whose archive hash is committed with this script.
import fs from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import crypto from 'node:crypto'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const launcher = path.join(root, 'web', 'bridge', 'launcher')
const runtime = JSON.parse(await fs.readFile(path.join(launcher, 'node-runtime.json'), 'utf8'))
const pkg = JSON.parse(await fs.readFile(path.join(root, 'web', 'bridge', 'package.json'), 'utf8'))
const args = process.argv.slice(2)
const option = (name, fallback) => {
  const at = args.indexOf(name)
  if (at === -1) return fallback
  if (!args[at + 1] || args[at + 1].startsWith('--')) throw new Error(`${name} requires a value`)
  return args[at + 1]
}
if (args.includes('--help')) {
  console.log('Usage: node scripts/package_bridge.mjs [--version X.Y.Z] [--arch x64|arm64] [--output-dir dist]')
  process.exit(0)
}
const version = option('--version', pkg.version)
if (!/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/.test(version)) throw new Error('Version must be X.Y.Z, optionally with a prerelease suffix.')
const arch = option('--arch', process.arch)
const platform = process.platform
const pinned = runtime.archives[`${platform}-${arch}`]
if (!pinned) throw new Error(`No pinned Node runtime for ${platform}-${arch}.`)
const label = { darwin: 'macOS', win32: 'Windows', linux: 'Linux' }[platform]
const output = path.resolve(root, option('--output-dir', 'dist'))
const basename = `LumenDesk-Bridge-${version}-${label}-${arch}`
const working = await fs.mkdtemp(path.join(os.tmpdir(), 'lumendesk-bridge-package-'))
await fs.mkdir(output, { recursive: true })

function run(command, commandArgs, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, { cwd: root, stdio: 'inherit', ...options })
    child.on('error', reject)
    child.on('exit', code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)))
  })
}
const powershell = script => run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script])
const psQuote = value => `'${value.replaceAll("'", "''")}'`
const sha256 = async file => crypto.createHash('sha256').update(await fs.readFile(file)).digest('hex')
const copy = async (from, to) => {
  await fs.mkdir(path.dirname(to), { recursive: true })
  await fs.cp(from, to, { recursive: true })
}
const desktopQuote = value => `"${value.replace(/[\\`"$]/g, '\\\\$&')}"`

try {
  // BASE_PATH is always local for this distribution, even when the packager
  // happens to run inside a Pages job with a repository subpath in its env.
  // Windows spawn needs npm's command shim to run through cmd.exe.
  if (platform === 'win32') {
    await run(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'npm ci'], { cwd: path.join(root, 'web', 'app') })
    await run(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', 'npm run build'], { cwd: path.join(root, 'web', 'app'), env: { ...process.env, BASE_PATH: '/' } })
  } else {
    await run('npm', ['ci'], { cwd: path.join(root, 'web', 'app') })
    await run('npm', ['run', 'build'], { cwd: path.join(root, 'web', 'app'), env: { ...process.env, BASE_PATH: '/' } })
  }

  const archive = path.join(working, pinned.file)
  // curl uses CI's configured proxy/certificate policy. Verification uses the
  // committed digest, not an untrusted digest fetched alongside the archive.
  await run(platform === 'win32' ? 'curl.exe' : 'curl', [
    '--fail', '--location', '--silent', '--show-error', '--retry', '3', '--max-time', '180',
    '--output', archive, `https://nodejs.org/dist/v${runtime.version}/${pinned.file}`,
  ])
  if (await sha256(archive) !== pinned.sha256) throw new Error('Node runtime archive SHA256 did not match the pinned digest.')
  const extracted = path.join(working, 'runtime-source')
  await fs.mkdir(extracted)
  if (platform === 'win32') {
    await powershell(`$ErrorActionPreference = 'Stop'; Expand-Archive -LiteralPath ${psQuote(archive)} -DestinationPath ${psQuote(extracted)}`)
  } else await run('tar', ['-xzf', archive, '-C', extracted])
  const runtimeRoot = path.join(extracted, (await fs.readdir(extracted))[0])
  const stage = path.join(working, basename)
  const app = path.join(stage, 'LumenDesk Bridge.app')
  const payload = platform === 'darwin' ? path.join(app, 'Contents', 'Resources') : stage
  await fs.mkdir(path.join(payload, 'runtime'), { recursive: true })
  await copy(path.join(runtimeRoot, platform === 'win32' ? 'node.exe' : 'bin/node'), path.join(payload, 'runtime', platform === 'win32' ? 'node.exe' : 'node'))
  if (platform !== 'win32') await fs.chmod(path.join(payload, 'runtime', 'node'), 0o755)
  await copy(path.join(runtimeRoot, 'LICENSE'), path.join(payload, 'licenses', 'Node.txt'))
  await copy(path.join(root, 'LICENSE'), path.join(payload, 'licenses', 'LumenDesk.txt'))
  for (const dependency of ['react', 'react-dom', 'scheduler']) {
    await copy(path.join(root, 'web', 'app', 'node_modules', dependency, 'LICENSE'), path.join(payload, 'licenses', `${dependency}.txt`))
  }
  await copy(path.join(root, 'web', 'app', 'node_modules', 'vite', 'LICENSE.md'), path.join(payload, 'licenses', 'Vite.txt'))
  await copy(path.join(root, 'web', 'app', 'dist'), path.join(payload, 'web', 'app', 'dist'))
  await copy(path.join(root, 'web', 'bridge', 'src'), path.join(payload, 'web', 'bridge', 'src'))
  await fs.writeFile(path.join(payload, 'web', 'bridge', 'package.json'), JSON.stringify({ ...pkg, version }, null, 2) + '\n')
  // The API health version must match the distribution even for prereleases.
  const index = path.join(payload, 'web', 'bridge', 'src', 'index.js')
  await fs.writeFile(index, (await fs.readFile(index, 'utf8')).replace(/const VERSION = '[^']+'/, `const VERSION = '${version}'`))
  await copy(path.join(launcher, 'launch.mjs'), path.join(payload, 'launcher', 'launch.mjs'))
  const iconDirectory = path.join(root, 'LumenDesk', 'Assets.xcassets', 'AppIcon.appiconset')
  await copy(path.join(iconDirectory, 'AppIcon-macOS-256.png'), path.join(payload, 'icon.png'))

  const instructions = `LumenDesk Bridge ${version}\n\n` + (
    platform === 'darwin'
      ? 'Drag LumenDesk Bridge.app into Applications, then open it. The LD menu-bar icon offers Open LumenDesk and Quit LumenDesk Bridge.\n\nThis preview is ad-hoc signed and is not notarized. If macOS blocks the downloaded app, use System Settings > Privacy & Security > Open Anyway after the first launch attempt. Requires macOS 13.5 or later.\n'
      : platform === 'win32'
        ? 'Extract the entire zip into a folder, then double-click LumenDesk Bridge.exe. The tray icon offers Open LumenDesk and Quit LumenDesk Bridge. Keep the runtime, web and launcher folders next to the executable. Requires Windows 10 or later, x64.\n\nThis preview is unsigned. Windows may show a SmartScreen or firewall prompt on first launch. For LAN discovery, allow network access on your private home network.\n'
        : 'Extract this archive, then run Install LumenDesk.sh using your file manager\'s Run as Program action. The installer copies the app into your home folder and adds LumenDesk Bridge and Stop LumenDesk Bridge to your applications menu. No administrator access is needed. You can also run Start LumenDesk.sh directly from the extracted folder. Requires Linux x64 with glibc 2.28 or newer and a desktop with xdg-open.\n'
  ) + '\nYour browser opens http://127.0.0.1:8765. No Node installation, repository clone or terminal setup is needed. Everything runs locally, without an account or cloud service.\n\nClosing the browser keeps schedules available while the bridge is running. Use Quit (or Stop on Linux) to stop the bridge; schedules cannot run while the bridge is quit or the computer is asleep. This installer does not create a startup service or launch at login. Open the app again after restarting your computer.\n\nRooms and schedules remain in ~/.lumendesk/bridge-state.json; Nanoleaf credentials remain in ~/.lumendesk/nanoleaf-pairings.json. Installing an update preserves them. Logs are in ~/.lumendesk/bridge-launcher.log. Quit before replacing or removing the application.\n\nGovee: enable LAN Control in Govee Home. LIFX: connect the bulbs to the same home network. Nanoleaf: pair the controller from Devices. Allow local network access if your operating system asks.\n\nThird-party notices are in the licenses folder. BUILD-MANIFEST.json records the pinned runtime and SHA256 for every shipped file.\n'
  await fs.writeFile(path.join(stage, 'READ ME.txt'), instructions)

  if (platform === 'darwin') {
    await fs.mkdir(path.join(app, 'Contents', 'MacOS'), { recursive: true })
    await run('clang', ['-fobjc-arc', '-framework', 'AppKit', '-arch', arch === 'x64' ? 'x86_64' : 'arm64', '-mmacosx-version-min=13.5', '-o', path.join(app, 'Contents', 'MacOS', 'LumenDesk Bridge'), path.join(launcher, 'macos.m')])
    const iconset = path.join(working, 'Bridge.iconset')
    await fs.mkdir(iconset)
    for (const size of [16, 32, 128, 256, 512]) {
      await copy(path.join(iconDirectory, `AppIcon-macOS-${size}.png`), path.join(iconset, `icon_${size}x${size}.png`))
      await copy(path.join(iconDirectory, `AppIcon-macOS-${size * 2}.png`), path.join(iconset, `icon_${size}x${size}@2x.png`))
    }
    await run('iconutil', ['-c', 'icns', iconset, '-o', path.join(payload, 'Bridge.icns')])
    await fs.writeFile(path.join(app, 'Contents', 'Info.plist'), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>LumenDesk Bridge</string>
<key>CFBundleDisplayName</key><string>LumenDesk Bridge</string>
<key>CFBundleIdentifier</key><string>com.lumendesk.bridge</string>
<key>CFBundleExecutable</key><string>LumenDesk Bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Bridge</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${version.split('-')[0]}</string>
<key>LSMinimumSystemVersion</key><string>13.5</string>
<key>LSUIElement</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>LumenDesk discovers and controls lights on your home network.</string>
</dict></plist>\n`)
    await copy(path.join(stage, 'READ ME.txt'), path.join(payload, 'READ ME.txt'))
    await fs.symlink('/Applications', path.join(stage, 'Applications'))
  } else if (platform === 'win32') {
    const png = await fs.readFile(path.join(iconDirectory, 'AppIcon-macOS-256.png'))
    const header = Buffer.alloc(22)
    header.writeUInt16LE(1, 2)
    header.writeUInt16LE(1, 4)
    header.writeUInt16LE(1, 10)
    header.writeUInt16LE(32, 12)
    header.writeUInt32LE(png.length, 14)
    header.writeUInt32LE(22, 18)
    const ico = path.join(working, 'Bridge.ico')
    await fs.writeFile(ico, Buffer.concat([header, png]))
    const compiler = path.join(process.env.WINDIR || 'C:\\Windows', 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe')
    await run(compiler, ['/nologo', '/target:winexe', '/platform:x64', `/win32icon:${ico}`, `/out:${path.join(stage, 'LumenDesk Bridge.exe')}`, '/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll', '/reference:System.Web.Extensions.dll', path.join(launcher, 'windows.cs')])
  } else {
    for (const [from, to] of [['linux-start.sh', 'Start LumenDesk.sh'], ['linux-stop.sh', 'Stop LumenDesk.sh'], ['linux-install.sh', 'Install LumenDesk.sh']]) {
      await copy(path.join(launcher, from), path.join(stage, to))
      await fs.chmod(path.join(stage, to), 0o755)
    }
    await copy(path.join(launcher, 'install-linux.mjs'), path.join(payload, 'launcher', 'install-linux.mjs'))
    await fs.writeFile(path.join(stage, 'Install LumenDesk.desktop'), `[Desktop Entry]
Type=Application
Name=Install LumenDesk Bridge
Comment=Install this local lighting app in your home folder
Exec=sh -c ${desktopQuote('exec "$(dirname "$1")/Install LumenDesk.sh"')} lumendesk %k
Icon=preferences-system
Terminal=false
Categories=Utility;
`, { mode: 0o755 })
  }

  // Record every shipped file. Keep the macOS manifest outside the signed
  // bundle: putting a hash of the executable inside its own signature seal
  // would create a circular dependency.
  const files = {}
  let shippedBytes = 0
  async function visit(dir) {
    for (const entry of await fs.readdir(dir, { withFileTypes: true })) {
      const file = path.join(dir, entry.name)
      if (entry.isDirectory()) await visit(file)
      else if (entry.isFile()) {
        files[path.relative(stage, file).split(path.sep).join('/')] = await sha256(file)
        shippedBytes += (await fs.stat(file)).size
      }
    }
  }
  if (platform === 'darwin') {
    await run('codesign', ['--force', '--sign', '-', path.join(payload, 'runtime', 'node')])
    await run('codesign', ['--force', '--sign', '-', app])
    await run('codesign', ['--verify', '--deep', '--strict', app])
  }
  await visit(stage)
  const manifest = {
    name: 'LumenDesk Bridge', version, platform, arch,
    node: { version: runtime.version, archive: pinned.file, sha256: pinned.sha256, source: runtime.source },
    files,
  }
  await fs.writeFile(path.join(stage, 'BUILD-MANIFEST.json'), JSON.stringify(manifest, null, 2) + '\n')
  let bundle
  if (platform === 'darwin') {
    bundle = path.join(output, `${basename}.dmg`)
    await fs.rm(bundle, { force: true })
    // hdiutil's automatic estimate can count a sparse/compressed runtime by
    // its allocated blocks, then run out of image space copying logical bytes.
    // Size from actual file lengths and leave room for filesystem metadata.
    const imageMiB = Math.ceil(shippedBytes * 1.3 / (1024 * 1024)) + 64
    await run('hdiutil', ['create', '-volname', 'LumenDesk Bridge', '-srcfolder', stage, '-size', `${imageMiB}m`, '-ov', '-format', 'UDZO', bundle])
  } else if (platform === 'win32') {
    bundle = path.join(output, `${basename}.zip`)
    await fs.rm(bundle, { force: true })
    await powershell(`$ErrorActionPreference = 'Stop'; Compress-Archive -LiteralPath ${psQuote(stage)} -DestinationPath ${psQuote(bundle)}`)
  } else {
    bundle = path.join(output, `${basename}.tar.gz`)
    await run('tar', ['-czf', bundle, '-C', working, basename])
  }
  await fs.writeFile(`${bundle}.sha256`, `${await sha256(bundle)}  ${path.basename(bundle)}\n`)
  console.log(`Packaged ${bundle}`)
} finally {
  await fs.rm(working, { recursive: true, force: true })
}
