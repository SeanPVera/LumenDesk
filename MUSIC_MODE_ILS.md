# Music Mode — iLightShow analysis source

Music Mode can drive its beat grid from **precomputed iLightShow analysis**
instead of learning a map live. This is an opt-in *source* for the existing
`BeatMapCoordinator`, not a new pipeline: the choreography engine, renderer,
flash-safety limiter, scope/conflict rules and `music-pulse` identifier are
untouched.

## Flow

```
NowPlayingMonitor ──title/artist──▶ BeatMapCoordinator ──onTrackChanged──▶ AudioReactiveSessionController
                                           ▲                                        │
                                           │                     MusicBrainzISRCResolver (title/artist → ISRC)
                                           │                                        │
                                           └──── adoptServerMap(BeatMap, key) ◀── IlsBeatMapProvider (ISRC → BeatMap)
```

1. **Resolve.** On each track change the coordinator fires `onTrackChanged`; the
   controller reads `currentServerMapCandidate()` (the new track's title/artist +
   key) and `MusicBrainzISRCResolver` looks the recording up on the public
   MusicBrainz web service to get its **ISRC**. No Apple Developer membership or
   device entitlement is required — just HTTP. Results are cached per
   title/artist and requests are spaced to respect MusicBrainz's rate guidance.
2. **Fetch.** `IlsBeatMapProvider` turns an ISRC into a `BeatMap` via `IlsClient`
   (enrol once → `GET /ils/v3/isrc/{isrc}` → decode → `IlsAnalysis.beatMap`). It
   caches by ISRC, remembers per-ISRC misses, and trips a session breaker if
   enrolment fails — so an unreachable or not-yet-provisioned backend is asked
   once, never hammered.
3. **Adopt.** The `@MainActor` controller resolves + fetches off the main thread
   and calls `BeatMapCoordinator.adoptServerMap(_:key:)`. The coordinator adopts
   it only if the track has not changed since the lookup began, marks the track
   key authoritative, and stops the live learner for it. Everything downstream —
   the clock alignment, `map.apply(...)`, the status line — is the existing path.

## Fallback (the invariant)

The server map is **best-effort**. With the setting off, a track that MusicBrainz
can't match, no analysis for the ISRC, or any lookup/fetch/enrol failure, Music
Mode keeps **learning the map live exactly as before**. The live learner is never
removed; it is only superseded for a track once an authoritative server map
arrives, and a later live refinement can never overwrite one (`serverMapKeys`
guard in `finishLearning`).

## Enabling

Off by default. Settings → Live/Privacy → **Use iLightShow analysis
(experimental)** (`AppPreferenceKey.musicServerAnalysis`), read at each Music
Mode start.

## Privacy

While the setting is on, the playing track's **title and artist** are sent to
`musicbrainz.org` to resolve the ISRC (a generic `LumenDesk/<version>`
User-Agent, no personal contact details). Nothing is sent when the setting is
off. The footnote on the toggle says so.

## Access: authorized out-of-band provisioning

The macOS enrol endpoint is attestation-gated and not deployed, so with the
operator's authorization LumenDesk is provisioned out of band, the clean way —
no attestation bypass, no app instrumentation, no key extraction:

1. LumenDesk generates its DPoP key (Keychain, never exported) and writes a
   **provisioning request** to `Application Support/LumenDesk/
   ils-provisioning-request.json` — the key's JWK + RFC 7638 thumbprint and the
   client identity. No secret leaves the device.
2. The operator issues a token **bound to that key's thumbprint** and returns
   `{ installationId, accessToken, dpopNonce, expiresAt }`.
3. Drop that at `Application Support/LumenDesk/ils-dev-credential.json`.
   `prepareForFetch()` imports it to the Keychain and deletes the plaintext
   file. Because LumenDesk holds the key, its DPoP proofs are valid for the
   token — standard RFC 9449, nothing circumvented.

`prepareForFetch()` prefers a restored or dev credential and only falls back to
the (gated) enrol flow, so once a credential is in place no backend route change
is needed.

## Prerequisite / follow-up

- **Backend.** Needs the iLightShow *Option A* macOS enrol endpoint (DPoP-only,
  no Play Integrity) to be live; until then the provider fails closed on the
  first attempt and Music Mode stays on live learning.
- ISRC resolution is metadata-based, so match quality depends on clean
  Now Playing title/artist; ambiguous or mistagged tracks simply fall back.
