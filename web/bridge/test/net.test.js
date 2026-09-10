// Discovery targets. These mirror LumenDeskTests/NetworkUtilityTests.swift so
// the bridge and the native app aim at the same addresses.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  MAX_PROBE_HOSTS,
  describeReport,
  directedBroadcasts,
  isContiguousMask,
  isUnoccupied,
  listInterfaces,
  prefixLength,
  probeHosts,
  toDotted,
  toUint32,
} from '../src/net.js'

const iface = (name, address, netmask) => ({
  name,
  address: toUint32(address),
  netmask: toUint32(netmask),
  prefix: prefixLength(toUint32(netmask)),
  network: (toUint32(address) & toUint32(netmask)) >>> 0,
  broadcast: ((toUint32(address) & toUint32(netmask)) | (~toUint32(netmask) >>> 0)) >>> 0,
  description: `${name} ${address}/${prefixLength(toUint32(netmask))}`,
})

test('IPv4 conversion round-trips and rejects malformed input', () => {
  assert.equal(toUint32('192.168.40.7'), 0xc0a82807)
  assert.equal(toDotted(0xc0a82807), '192.168.40.7')
  assert.equal(toUint32('0.0.0.0'), 0)
  assert.equal(toDotted(0xffffffff), '255.255.255.255')
  assert.equal(toUint32('192.168.1'), null)
  assert.equal(toUint32('192.168.1.256'), null)
  assert.equal(toUint32('192.168.-1.2'), null)
})

test('netmasks must be contiguous', () => {
  assert.equal(isContiguousMask(0xffffff00), true)
  assert.equal(isContiguousMask(0xffffff80), true)
  assert.equal(isContiguousMask(0x80000000), true)
  assert.equal(isContiguousMask(0), false)
  assert.equal(isContiguousMask(0xffffff0f), false)
  assert.equal(prefixLength(0xffffff00), 24)
  assert.equal(prefixLength(0xffff0000), 16)
})

test('each interface contributes its own directed broadcast', () => {
  assert.deepEqual(
    directedBroadcasts([
      iface('en0', '192.168.1.42', '255.255.255.0'),
      iface('en1', '10.4.0.9', '255.255.0.0'),
    ]),
    ['192.168.1.255', '10.4.255.255'],
  )
})

test('interfaces sharing a subnet fold to one broadcast', () => {
  assert.deepEqual(
    directedBroadcasts([
      iface('en0', '192.168.1.42', '255.255.255.0'),
      iface('en1', '192.168.1.43', '255.255.255.0'),
    ]),
    ['192.168.1.255'],
  )
})

test('a /24 sweep skips the network, broadcast, and our own address', () => {
  const hosts = probeHosts([iface('en0', '192.168.10.42', '255.255.255.0')])
  assert.equal(hosts.length, 253)
  assert.equal(hosts[0], '192.168.10.1')
  assert.equal(hosts.at(-1), '192.168.10.254')
  assert.ok(!hosts.includes('192.168.10.0'))
  assert.ok(!hosts.includes('192.168.10.42'))
  assert.ok(!hosts.includes('192.168.10.255'))
})

test('a netmask narrower than /24 is honoured', () => {
  // The other half of the /24 is off-link: probes to it leave by the default
  // route, which is exactly the mistake this sweep exists to avoid.
  const hosts = probeHosts([iface('en0', '10.0.0.130', '255.255.255.128')])
  assert.equal(hosts.length, 125)
  assert.equal(hosts[0], '10.0.0.129')
  assert.equal(hosts.at(-1), '10.0.0.254')
  assert.ok(!hosts.includes('10.0.0.1'))
  assert.ok(!hosts.includes('10.0.0.128'))
})

test('a network wider than /24 is capped', () => {
  const hosts = probeHosts([iface('en0', '172.16.9.20', '255.255.0.0')])
  assert.equal(hosts.length, 253)
  assert.equal(hosts[0], '172.16.9.1')
  assert.equal(hosts.at(-1), '172.16.9.254')
})

test('the sweep covers every interface and stays bounded', () => {
  const hosts = probeHosts([
    iface('en0', '192.168.1.42', '255.255.255.0'),
    iface('en1', '10.0.7.5', '255.255.255.0'),
  ])
  assert.ok(hosts.includes('192.168.1.1'))
  assert.ok(hosts.includes('10.0.7.200'))
  assert.ok(!hosts.includes('192.168.1.42'))
  assert.equal(new Set(hosts).size, hosts.length)

  const many = Array.from({ length: 8 }, (_, i) => iface(`en${i}`, `10.${i}.0.5`, '255.255.255.0'))
  assert.equal(probeHosts(many).length, MAX_PROBE_HOSTS)
})

test('interface enumeration drops loopback, tunnels, and peer-to-peer radios', () => {
  const interfaces = listInterfaces({
    lo0: [{ address: '127.0.0.1', netmask: '255.0.0.0', family: 'IPv4', internal: true }],
    en0: [
      { address: '192.168.1.42', netmask: '255.255.255.0', family: 'IPv4', internal: false },
      { address: 'fe80::1', netmask: 'ffff::', family: 'IPv6', internal: false },
    ],
    awdl0: [{ address: '169.254.1.2', netmask: '255.255.0.0', family: 'IPv4', internal: false }],
    utun4: [{ address: '10.8.0.6', netmask: '255.255.255.255', family: 'IPv4', internal: false }],
    en5: [{ address: '10.0.0.9', netmask: '255.255.255.252', family: 'IPv4', internal: false }],
  })
  assert.deepEqual(interfaces.map(i => i.name), ['en0', 'en5'])
  assert.equal(interfaces[0].description, 'en0 192.168.1.42/24')
  assert.equal(toDotted(interfaces[0].broadcast), '192.168.1.255')
})

test('numeric IPv4 family values are accepted', () => {
  const interfaces = listInterfaces({
    en0: [{ address: '192.168.1.42', netmask: '255.255.255.0', family: 4, internal: false }],
  })
  assert.equal(interfaces.length, 1)
})

test('an empty address is not counted as a refusal', () => {
  // EHOSTUNREACH on a directly-connected subnet means nothing is at that
  // address, which on a home /24 is most of it. Reporting that as a failure
  // made a healthy scan read as though a firewall were eating the traffic.
  assert.equal(isUnoccupied({ code: 'EHOSTUNREACH' }), true)
  assert.equal(isUnoccupied({ code: 'EHOSTDOWN' }), true)
  assert.equal(isUnoccupied({ code: 'ENETUNREACH' }), false, 'no route to the network is a real fault')
  assert.equal(isUnoccupied({ code: 'EACCES' }), false)
  assert.equal(isUnoccupied(undefined), false)
})

test('a report separates empty addresses, refusals, and silence', () => {
  assert.equal(
    describeReport({ interfaces: ['en0 192.168.1.42/24'], sent: 254, unoccupied: 0, failed: 0, lastError: null }),
    '254 probes on en0 192.168.1.42/24',
  )

  // The shape the user actually hit: nine live hosts on a /24, the rest empty.
  const sparse = describeReport({
    interfaces: ['en0 192.168.1.57/24'],
    sent: 9,
    unoccupied: 499,
    failed: 0,
    lastError: null,
  })
  assert.ok(sparse.includes('9 probes'))
  assert.ok(sparse.includes('499 addresses empty'))
  assert.ok(!sparse.includes('refused'), 'an empty subnet must not read as a refusal')

  const refused = describeReport({
    interfaces: ['en0 192.168.1.42/24'],
    sent: 0,
    unoccupied: 0,
    failed: 254,
    lastError: 'EACCES',
  })
  assert.ok(refused.includes('254 refused'))
  assert.ok(refused.includes('EACCES'))

  assert.equal(describeReport({ interfaces: [], sent: 0, unoccupied: 0, failed: 0 }), 'no IPv4 network interface')
})
