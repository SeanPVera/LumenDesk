// Interface-aware discovery targets, shared by the LIFX and Govee clients.
//
// A single datagram to 255.255.255.255 is not enough to find anything. That
// address is not routed: the kernel picks one interface from the default
// route, so on a machine holding a VPN route, bridging a Thunderbolt link, or
// running Docker, the scan leaves by an interface with no lights on it. The
// same is true of multicast with no IP_MULTICAST_IF. Discovery therefore aims
// at each interface's own subnet-directed broadcast and, for routers that
// filter broadcast outright, at every host on those subnets in turn. Replies
// are ordinary unicast datagrams that no router or OS gates.
//
// This mirrors LocalSubnet and UDPSocket.probeSubnets in the Swift app.
import os from 'node:os'

/** Hard ceiling on one sweep, so a many-interface host cannot emit thousands
 *  of datagrams per scan. */
export const MAX_PROBE_HOSTS = 1024

/** Interfaces that never carry a smart bulb: Apple's peer-to-peer radios,
 *  internal links, and point-to-point tunnels with no broadcast domain. */
const EXCLUDED_PREFIXES = ['awdl', 'llw', 'anpi', 'ap1', 'utun', 'ipsec', 'ppp', 'gif', 'stf']

export function toUint32(dotted) {
  const parts = String(dotted).split('.')
  if (parts.length !== 4) return null
  let value = 0
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part)) return null
    const octet = Number(part)
    if (octet > 255) return null
    value = (value * 256) + octet
  }
  return value >>> 0
}

export function toDotted(value) {
  const n = value >>> 0
  return `${(n >>> 24) & 255}.${(n >>> 16) & 255}.${(n >>> 8) & 255}.${n & 255}`
}

/** A netmask is usable only if its set bits run contiguously from the top. */
export function isContiguousMask(mask) {
  const n = mask >>> 0
  if (n === 0) return false
  const inverted = (~n) >>> 0
  return (((inverted + 1) >>> 0) & inverted) === 0
}

export function prefixLength(mask) {
  let count = 0
  let n = mask >>> 0
  while (n) {
    count += n & 1
    n >>>= 1
  }
  return count
}

/** Active, non-loopback IPv4 interfaces with a broadcast domain worth scanning. */
export function listInterfaces(source = os.networkInterfaces()) {
  const found = []
  for (const [name, entries] of Object.entries(source ?? {})) {
    if (EXCLUDED_PREFIXES.some(prefix => name.startsWith(prefix))) continue
    for (const entry of entries ?? []) {
      const family = entry.family === 4 ? 'IPv4' : entry.family
      if (family !== 'IPv4' || entry.internal) continue
      const address = toUint32(entry.address)
      const netmask = toUint32(entry.netmask)
      if (address === null || netmask === null) continue
      if (!isContiguousMask(netmask)) continue
      const prefix = prefixLength(netmask)
      // /31 and /32 have no host range to sweep and no broadcast address.
      if (prefix > 30) continue
      const network = (address & netmask) >>> 0
      found.push({
        name,
        address,
        netmask,
        prefix,
        network,
        broadcast: (network | (~netmask >>> 0)) >>> 0,
        description: `${name} ${entry.address}/${prefix}`,
      })
    }
  }
  return found.sort((a, b) => a.name.localeCompare(b.name) || a.address - b.address)
}

/** One subnet-directed broadcast per interface. These have a connected route,
 *  so the kernel picks the matching interface instead of the default one. */
export function directedBroadcasts(interfaces) {
  const seen = new Set()
  const targets = []
  for (const item of interfaces) {
    if (item.broadcast === item.address || seen.has(item.broadcast)) continue
    seen.add(item.broadcast)
    targets.push(toDotted(item.broadcast))
  }
  return targets
}

/** Every other host reachable on each interface. Networks wider than a /24 are
 *  capped to the /24 around our own address: a /16 sweep would be 65,000
 *  datagrams aimed at our own router. */
export function probeHosts(interfaces, max = MAX_PROBE_HOSTS) {
  const local = new Set(interfaces.map(item => item.address))
  const seen = new Set()
  const hosts = []
  for (const item of [...interfaces].sort((a, b) => a.address - b.address)) {
    const mask = Math.max(item.netmask >>> 0, 0xffffff00) >>> 0
    const network = (item.address & mask) >>> 0
    const broadcast = (network | (~mask >>> 0)) >>> 0
    if (broadcast <= network + 1) continue
    for (let candidate = network + 1; candidate < broadcast; candidate += 1) {
      if (local.has(candidate) || seen.has(candidate)) continue
      seen.add(candidate)
      hosts.push(toDotted(candidate))
      if (hosts.length >= max) return hosts
    }
  }
  return hosts
}

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

/** Errno codes meaning "nothing is at that address" rather than "the send was
 *  refused". On a directly-connected subnet these come from ARP giving up,
 *  which is the normal answer for an address with no device on it — exactly
 *  what a sweep exists to discover, and most of a home /24. ENETUNREACH is
 *  deliberately absent: no route to the network is a real fault. */
const UNOCCUPIED_CODES = new Set(['EHOSTUNREACH', 'EHOSTDOWN'])

export const isUnoccupied = err => UNOCCUPIED_CODES.has(err?.code)

export function sendTo(socket, packet, port, address) {
  return new Promise(resolve => {
    try {
      socket.send(packet, port, address, err => resolve(err ?? null))
    } catch (err) {
      resolve(err)
    }
  })
}

/**
 * Sends one datagram per host, in small bursts spaced apart.
 *
 * Firing 253 datagrams at never-before-seen neighbours in a tight loop
 * overruns the interface output queue: the kernel holds one packet per address
 * while it ARPs, and the rest come back ENOBUFS. Pacing keeps the sweep inside
 * that budget, and the tally says what actually left the machine.
 */
export async function sweep(socket, packet, hosts, port, { burst = 24, gap = 12 } = {}) {
  let sent = 0
  let unoccupied = 0
  let failed = 0
  let lastError = null
  for (let index = 0; index < hosts.length; index += burst) {
    const chunk = hosts.slice(index, index + burst)
    const results = await Promise.all(chunk.map(host => sendTo(socket, packet, port, host)))
    for (const err of results) {
      if (!err) {
        sent += 1
      } else if (isUnoccupied(err)) {
        unoccupied += 1
      } else {
        failed += 1
        lastError = err.message ?? String(err)
      }
    }
    if (index + burst < hosts.length) await sleep(gap)
  }
  return { sent, unoccupied, failed, lastError }
}

/**
 * One full discovery pass: directed broadcasts, any extra targets (the limited
 * broadcast, a multicast group), then two paced unicast sweeps.
 *
 * The sweep runs twice because the OS parks a single datagram per unresolved
 * neighbour while it ARPs and drops it if resolution is slow. A cold ARP cache
 * eats most of a first pass; the second runs against warm entries and is the
 * one that reliably lands.
 */
export async function probeSubnets(socket, packet, port, {
  interfaces = listInterfaces(),
  extraTargets = [],
  warmupDelay = 700,
} = {}) {
  const report = {
    interfaces: interfaces.map(item => item.description),
    sent: 0,
    unoccupied: 0,
    failed: 0,
    lastError: null,
  }
  const targets = [...extraTargets, ...directedBroadcasts(interfaces)]
  for (const target of targets) {
    const err = await sendTo(socket, packet, port, target)
    if (!err) {
      report.sent += 1
    } else if (isUnoccupied(err)) {
      report.unoccupied += 1
    } else {
      report.failed += 1
      report.lastError = err.message ?? String(err)
    }
  }
  const hosts = probeHosts(interfaces)
  for (const pass of [0, 1]) {
    if (pass === 1) await sleep(warmupDelay)
    const tally = await sweep(socket, packet, hosts, port)
    report.sent += tally.sent
    report.unoccupied += tally.unoccupied
    report.failed += tally.failed
    if (tally.lastError) report.lastError = tally.lastError
  }
  return report
}

/** Human-readable form of a probe report, for the bridge log and the API. */
export function describeReport(report) {
  if (!report.interfaces.length) return 'no IPv4 network interface'
  let text = `${report.sent} probe${report.sent === 1 ? '' : 's'} on ${report.interfaces.join(', ')}`
  if (report.unoccupied) text += ` · ${report.unoccupied} address${report.unoccupied === 1 ? '' : 'es'} empty`
  if (report.failed) {
    text += ` · ${report.failed} refused`
    if (report.lastError) text += ` (${report.lastError})`
  }
  return text
}
