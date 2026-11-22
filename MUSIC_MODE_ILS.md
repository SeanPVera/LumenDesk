# Music Mode — iLightShow analysis source

Music Mode can drive its beat grid from **precomputed iLightShow analysis**
instead of learning a map live. This is an opt-in *source* for the existing
`BeatMapCoordinator`, not a new pipeline: the choreography engine, renderer,
flash-safety limiter, scope/conflict rules and `music-pulse` identifier are
untouched.

## Flow

```
AudioCaptureService ──PCM──▶ ShazamTrackIdentifier ──ISRC──▶ AudioReactiveSessionController
         │                                                         │
         └── hops/snapshots ──▶ BeatMapCoordinator ◀── adoptServerMap(BeatMap, key)
                                       ▲                           │
                                       └──── IlsBeatMapProvider ◀──┘  (ISRC → IlsClient → BeatMap)
```

1. **Identify.** `ShazamTrackIdentifier` (ShazamKit) is fed the same PCM buffers
   the analyzer sees (`AudioCaptureService.onPCMBuffer`). It reports the matched
   recording's **ISRC** once per track; `reset()` on every track change starts a
   fresh identification. This mirrors how the iLightShow app itself keys its
   analysis (the bundle schema even carries a Shazam fingerprint).
2. **Fetch.** `IlsBeatMapProvider` turns an ISRC into a `BeatMap` via `IlsClient`
   (enrol once → `GET /ils/v3/isrc/{isrc}` → decode → `IlsAnalysis.beatMap`). It
   caches by ISRC, remembers per-ISRC misses, and trips a session breaker if
   enrolment fails — so an unreachable or not-yet-provisioned backend is asked
   once, never hammered.
3. **Adopt.** The `@MainActor` controller fetches off the main thread and calls
   `BeatMapCoordinator.adoptServerMap(_:key:)`. The coordinator adopts it only if
   the track has not changed since the fetch began, marks the track key
   authoritative, and stops the live learner for it. Everything downstream — the
   clock alignment, `map.apply(...)`, the status line — is the existing path.

## Fallback (the invariant)

The server map is **best-effort**. With the setting off, ShazamKit unavailable,
a track that cannot be identified, no analysis for the ISRC, or any fetch/enrol
failure, Music Mode keeps **learning the map live exactly as before**. The live
learner is never removed; it is only superseded for a track once an
authoritative server map arrives, and a later live refinement can never
overwrite one (`serverMapKeys` guard in `finishLearning`).

## Enabling

Off by default. Settings → Live/Privacy → **Use iLightShow analysis
(experimental)** (`AppPreferenceKey.musicServerAnalysis`), read at each Music
Mode start.

## Prerequisites / follow-ups

- **Backend.** Needs the iLightShow *Option A* macOS enrol endpoint (DPoP-only,
  no Play Integrity) to be live; until then the provider fails closed on the
  first attempt and Music Mode stays on live learning.
- **ShazamKit capability.** Catalog matching needs the ShazamKit App ID service /
  entitlement enabled for release builds; it compiles and the logic is tested
  without it, but live identification requires it.
- Nothing outside `Services/Music` and the `AudioReactiveSessionController`
  wiring changed; the renderer and safety code are as before.
