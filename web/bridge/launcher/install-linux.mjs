import fs from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn } from 'node:child_process'

const source = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const destination = path.join(os.homedir(), '.local', 'share', 'LumenDesk-Bridge')
const applications = path.join(os.homedir(), '.local', 'share', 'applications')
// Desktop Entry quoted arguments have an extra escaping layer before Exec
// tokenization. Escape all characters that are special inside double quotes.
const quote = value => `"${value.replace(/[\\`"$]/g, '\\\\$&')}"`

if (source !== destination) {
  await fs.mkdir(destination, { recursive: true, mode: 0o700 })
  await fs.cp(source, destination, { recursive: true })
}
await fs.mkdir(applications, { recursive: true })
for (const [name, script] of [['LumenDesk Bridge', 'Start LumenDesk.sh'], ['Stop LumenDesk Bridge', 'Stop LumenDesk.sh']]) {
  await fs.writeFile(path.join(applications, `${name}.desktop`), `[Desktop Entry]
Type=Application
Name=${name}
Comment=Local lighting control for LumenDesk
Exec=${quote(path.join(destination, script))}
Icon=${path.join(destination, 'icon.png')}
Terminal=false
Categories=Utility;
`, { mode: 0o755 })
}
console.log('LumenDesk Bridge is installed in your applications menu. Use Stop LumenDesk Bridge to quit.')
spawn(path.join(destination, 'Start LumenDesk.sh'), [], { stdio: 'ignore', detached: true }).unref()
