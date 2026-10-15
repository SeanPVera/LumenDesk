# Music Mode architecture

Music Mode remains the existing `music-pulse` effect. Configuration identity,
archive schema, device models, scope ownership and restoration all use the
existing app lifecycle. This describes the September 2026 production audit;
[MUSIC_MODE_EVIDENCE.md](MUSIC_MODE_EVIDENCE.md) distinguishes executed evidence
from hardware work still needed. [CONTROLS_AUDIT.md](CONTROLS_AUDIT.md) records
control behavior. Nothing here establishes perceptual synchronization.

## Native signal path

1. **`AudioCaptureService`**, in `AudioLevelMonitor.swift`, owns the shared source:
   ScreenCaptureKit system audio on macOS, AVAudioEngine microphone on iOS,
   user-selected file playback, or CoreMIDI clock. ScreenCaptureKit buffers are
   copied into owned planar Float32 storage without discarding stereo. Unsupported
   integer PCM is rejected, not reinterpreted as floats. File decoding uses
   AVAudioFile's processing format. Microphone/file timestamps use AVAudioTime;
   system capture uses sample presentation time. All are mapped to buffer-end
   monotonic host time, with receipt time only as a fallback.
2. **`MusicFeatureAnalyzer`** consumes every accepted buffer exactly once on the
   analysis queue. Channel powers are averaged after separate FFTs so opposite
   stereo phase cannot cancel audible music; RMS also averages channel energy.
   The first two channels provide stereo balance. Per-channel rings support arbitrary buffer sizes, a 2048-sample
   Hann window and a 512-sample hop. Rate changes and capture discontinuities reset
   FFT history, tracker and envelopes together, and onset flux is not measured
   again until the window has refilled (four hops): comparing a partly empty
   window with an emptier one read as a full-strength hit at every reset.
   Loudness and bands are still measured meanwhile. Duplicate/reversed end timestamps
   are rejected. Ingress admits short capture bursts on a user-initiated serial
   queue, bounded by 250 ms of audio and 32 buffers (one oversized buffer may
   enter an empty queue). Overflow buffers are counted and the next accepted
   buffer starts a new contiguous run. Counts reset for each source generation.
   This is bounded capture, not a claim that capture can never lose samples.
3. Fixed soft-knee RMS level preserves quiet/loud contrast; adaptive gain is
   retained for onset detection. Rectified log spectral flux is averaged within
   log bands. Kick, snare, percussion, bass, energy, raw RMS and onset are distinct
   features. **`BeatTracker` / `MetreTracker`** in `BeatTracker.swift` infer a grid
   from broadband and kick autocorrelations, with a tempo prior, rival-period
   confidence, peakiness gating, challenger persistence and a phase loop.
   Onsets are not asserted to be beats. Metre receives the completed nearest-beat
   energy window, not one arbitrary hop at a predicted beat callback.
4. **`AudioReactiveSessionController`** owns one 20 Hz render clock and multiple
   scope sessions. It samples the most recent analysis independently of capture;
   publication to UI is separately throttled. One source is shared across live
   scopes. Source generations guard analysis and publication. Source changes
   cannot replace another room's capture. Scope identity guards completion and
   frame callbacks. Demo grooves enter here as explicitly synthetic snapshots.
   The render timer runs in common run-loop modes so native control tracking
   does not pause lighting. Capture delegate failures surface as unavailable
   and stalled. Input health depends on the source: system audio can stop
   delivering buffers while nothing plays, so a gap there is waiting or
   silent; a microphone or a playing file never pauses, so a gap there is
   stalled; MIDI clock waits for a running transport. iOS audio-session
   interruptions, engine configuration changes and media-service resets are
   reported as failures, and the microphone restarts when it is free again.
   Restart reconnects the shared source while retaining scope sessions and
   restore snapshots.
5. **`MusicChoreographyEngine.makeFrame`** applies freshness, configuration, roles
   and topology to produce vendor-neutral HSB states, transition durations,
   timestamp and sequence. No vendor command or second audio pipeline lives here.
6. **`MusicLightingRenderer`** rejects old sequences and frames older than 250 ms,
   keeps at most the newest pending frame per fixture and paces handoffs on a
   per-fixture slot schedule. Slots advance by the transport interval from the
   previous slot and may be taken up to 15 ms early, so render-clock jitter
   neither drops frames nor halves a ceiling that falls between 50 ms ticks;
   a late slot moves the schedule rather than banking a catch-up burst. Reset
   clears pending frames, slots and sequence history for stopped fixtures.
7. **`LightManager.renderMusicFrame`** validates active effect ownership and known
   reachability, applies real device capability masks, and hands commands to the
   existing LIFX/Govee transports. `musicCapabilityStates` is also used by the
   preview, so the firmware zone mask is visible before transport.

## Timing and confidence

`analysisTimestamp` denotes the last analyzed sample; `analysisCompletedAt`
records processing completion. Snapshot age is render time minus sample time.
Capture-to-analysis therefore includes input buffering, dispatch and analysis;
with a receipt-time fallback it cannot reveal upstream capture latency.

PCM snapshots have 250 ms freshness grace, then their energy and confidence fade
for one second. Silence policy handles the resulting quiet state. MIDI updates
freshness on clock messages (native grace also accommodates slow clock intervals).
Stopping invalidates generations rather than relying on this fade.

The snapshot carries tempo, interval, reference time, grid position, public event
count, confidence, metre and felt interval. Grid position is separate from the
fallback onset count so acquiring a grid does not corrupt half-time phase.
`BeatTracker.beatsPerBar` stays four in both implementations; metre is an overlay,
not a global mutation. Overrides preserve 3/4, 5/4, 6/8, 7/8 and half/double feel.
Automatic metre and time feel remain heuristics. Syncopated material can still
select a dotted relative; see the reproducible ambiguity probe in the evidence.

The engine predicts **45 ms plus the user's light timing offset plus 0.8 × the
current gear's attack time** ahead. The 45 ms component is still an **unmeasured
assumption**, not device compensation established by testing; the offset
(`outputLatencyOffset`, ±300 ms, kept across presets by
`preservingRoomCalibration`) and tap calibration exist so a room can correct it. FFT-window delay, capture latency, render quantization, command queues,
Wi-Fi and firmware interpolation are separate contributors. A sent UDP packet
cannot establish any of the last three or a visible light change.

## Beat maps and playback clocks

`BeatMap.swift` and `web/app/src/music/beat-map.ts` are lockstep ports: same
constants, same algorithms, same synthetic test vectors (`BeatMapTests.swift`,
`beat-map.test.mjs`). A map holds beat times, the first downbeat (bars are four
beats; metre overrides still apply on top), 0…1 energy per bar, a 100 Hz onset
envelope and a periodicity confidence. Maps below 0.08 confidence never play.

Building (`BeatMapBuilder`): the existing analyzer runs over the whole file
faster than real time and reports every hop's beat-tracker onset mix, kick and
energy. Those are resampled to 100 Hz; novelty is the onset envelope minus its
half-second mean, rectified. Global tempo comes from the novelty's
autocorrelation under a log-normal prior at 120 BPM, each lag also scoring half
its double. Beats come from dynamic programming (Ellis 2007, tightness 100),
silent ends are trimmed, the downbeat is the beat phase with the strongest low
band, and bar energy is 60 % absolute loudness, 40 % rank within the song. This
is an offline second pass: unlike the live tracker it sees the whole song, so
early beats are not guesses.

Playing (`BeatMap.apply`): given a track position on the renderer's clock, the
map replaces the snapshot's grid fields (`beatReferenceTime`, `beatInterval`,
`gridBeatPosition`, `beatInBar`, lock and confidence) and adds `barEnergy`;
loudness, bands and transients stay live. The engine cannot tell a map from a
confident tracker, so the choreography path is unchanged. A map is applied
before `applyMusicalPolicy`, so preset metre and feel overrides still win.

Clocks (`BeatMapCoordinator`, main thread, owned by
`AudioReactiveSessionController`, one per shared source):

- **File:** position comes from `AVAudioPlayerNode.playerTime` mapped to host
  time, modulo the file length because playback loops by rescheduling. The web
  uses the `AudioContext` output timestamp from a fixed start time. Maps are
  cached by file identity (name, size, modification date, length, rate).
- **Spotify and Music (macOS):** `NowPlayingMonitor` polls running apps once a
  second over Apple Events (`NSAppleScript`, one-second timeout, never launching
  an app) for track ID, duration, state and position, timestamped halfway
  through the request. `PlaybackClock` dead-reckons between reports, drifts a
  tenth of the way toward reports within 250 ms and re-anchors on anything
  larger (seek, skip, stall). A track without a map is learned by
  `BeatMapLearner` from host-timed hops drained each render tick; only one
  unbroken pass counts, and it must start in the first ten seconds and cover
  85 % of the track. The map is built just before the track ends or when it
  changes, stored under `app bundle ID:track ID`, and used from the next listen.
- **Alignment:** every two seconds the last six seconds of live onsets are
  cross-correlated with the map within ±400 ms of the clock's position,
  penalising distance from zero so a neighbouring beat cannot win on a tie. A
  match needs correlation ≥ 0.3 and a 0.04 margin over the best lag at least
  60 ms away; the clock then moves 60 % of offsets between 15 and 350 ms.

`BeatMapStore` writes one JSON file per key under Application
Support/LumenDesk/BeatMaps, named by FNV-1a 64 of the key so titles never become
paths, pruned to the 400 most recent. Maps from another format version are
ignored and rebuilt. No audio is stored.

Sandbox and privacy: `com.apple.security.automation.apple-events` plus a
temporary Apple Events exception for `com.spotify.client` and `com.apple.Music`,
and `NSAppleEventsUsageDescription`. Following is off by default
(`followsPlaybackApps`); declined Automation (`-1743`) is reported and the show
stays live.

Tap calibration (`TapCalibrator`, both platforms): each tap's distance to the
nearest beat of the grid the last frame rendered against is the lights'
lateness plus the person's lag. After eight taps whose median absolute
deviation is under 60 ms, the median moves the offset, rounded to 10 ms.

## Musical behavior

- The underlying light level follows sustained loudness, with a modest bass
  contribution. Rhythmic accents occupy remaining headroom above that bed rather
  than repeatedly taking the room to black. Quiet input reduces accent depth;
  a bounded depth curve retains headroom on strong beats. Hit roles sustain the
  accent longer over a darker bed; Wash carries atmosphere; Accent responds to
  percussion; Motion receives the topology treatment.
- Confidence blends grid accents toward the off-grid energy/onset envelope.
  Dense hi-hats are not independent room-wide brightness multipliers. Bass and
  percussion sensitivities affect their contributions, not the detector's BPM.
  Zero beat sensitivity or effect intensity removes rhythmic accent drive.
- Master brightness scales both minimum and maximum. The final value is clamped
  after smoothing and flashes, so zero means black and live ceiling reductions
  take effect immediately. Fade Out can intentionally fall below the minimum.
- Color uses authored palette entries and interpolation. Transient chroma and mood
  no longer shift the whole palette; Accent uses another authored entry instead
  of inventing a complementary hue. Progress holds for whole bars and fades over
  a beat. Reacquisition retains the current color and advances at a future boundary
  rather than jumping to the absolute song count. Zero color-change holds position.
- Movement integrates musical bar rate when a usable grid exists. Zero speed
  stops movement. Linear endpoints do not wrap onto the same sine phase; two bulbs
  get a shallow, distinguishable tilt, not the depth of a segmented strip.
- Six energy gears (`EnergyTierTracker`, lockstep with the web) with ±0.65-gear
  hysteresis scale accent depth (0.62…1.15 of the original) and rise time (140 ms
  calm, 26 ms loud). A beat map supplies the playing bar's energy; live input
  sets a gear when a bar finishes (one bar late), and without a grid a
  two-second average stands in. Gears 0–2 on beats under 0.5 s pulse every other
  beat while time feel is Auto and the grid reads straight. Gears 4–5 step the
  palette each beat (each other beat above 180 BPM, at most three changes a
  second) unless Reduced Motion is on. Gear 5 may request a downbeat flash
  through `FlashSafetyLimiter` like any other request.
- Short/long energy differences and sustained-energy hysteresis provide slow lifts.
  `phraseAware` is retained as a saved key but labeled **Sustained-energy lifts**.
  This is not reliable phrase, chorus or drop recognition.

## Capability and transport boundaries

| Path | Renderer handoff ceiling (average) | Actual command path / limits |
|---|---:|---|
| LIFX LAN | one / 60 ms (single gaps ≥ 30 ms; ≈ 16 Hz on the 20 Hz clock) | Combined HSBK including brightness and transition; local UDP submission and failures counted |
| Ordinary Govee LAN | one / 100 ms | Global brightness opened once, per-frame brightness folded into RGB; volatile color queue coalesces and expires |
| Supported Govee segment stream | one / 50 ms | Volatile Razer stream; the existing Govee sender still spaces **all datagrams by 100 ms per device**, so this is not measured 20 fps device delivery |
| Browser bridge | at most 10 HTTP frames/s, one in flight | Solid color per fixture; explicit independent brightness and LIFX transition; bridge's existing per-device queue coalesces |

Govee firmware-specific active-zone constraints remain intact. Inactive zones are
black in preview and output; only allowed zones are marked on when encoding.
Live music never uses repeated persistent `ptReal` writes. Stop cancels queued
volatile colors/segment frames before ending streaming and restoring through the
normal path. Reapplying a saved segment layout once on restoration is different
from a live animation write. LIFX segmented Music Mode is not added by this patch.

## Browser parity and differences

The existing `web/app/src/music` implementation remains the browser production
path. The AudioWorklet batches continuous stereo PCM into 1024 samples, permits
at most two unacknowledged messages, reports gaps and consumes each accepted batch
once. Render ticks never re-analyze the last buffer. The analyzer now matches native
band definitions, RMS mapping, flux averaging and time constants more closely,
analyzes stereo channels separately and averages their power, and skips onset
flux while its window refills after a reset; independent FFT implementations are
not claimed bit-exact. Web MIDI derives tempo
from clock intervals and honors Stop/Continue/Start.

`LatestMusicFrameSender` keeps one in-flight request and one latest pending frame,
paces at 10 Hz, expires old frames and drains before restore. The bridge separates
full-value RGB from brightness, opens Govee brightness once per session, and labels
HTTP success as acceptance for local dispatch. Legacy RGB-only callers retain their
previous meaning. Session ownership and manual-control revisions reject stale
frames/restoration after a newer user command. New/returned fixtures do not silently
join a running show's membership. Normal source changes/restarts are serialized.

The web builds beat maps for played files (cached for the page's lifetime) and
has the light timing offset and tap calibration. It cannot follow Spotify or
Music: a browser has no way to ask another app for its playback position.

Web Music Mode has one all-device scope, active roles and presets; it has no native
advanced sliders, saved Music Mode configuration, fixture-order editor or segment
encoder. These limitations must not be presented as parity. Closing a browser tab
cannot guarantee delivery of its asynchronous restoration request; explicit Stop
is the reliable application action, still subject to network/device failure.

## Comfort, persistence and diagnostics

No-flash mode is the UI name for the existing `photosensitivitySafeMode` saved key.
It is enabled by default and blocks explicit flashes. Reduced Motion also disables
flashes and caps movement. LightManager reads and observes the system setting
itself, so every entry point (Music screen, favorites, scene cards, Demo Mode
exit) starts under it and changes reach active native sessions whichever
screen is open. Fader drags update sessions live and are saved on release. The hard
three-request/s cap is **not a medical safety guarantee**. Ordinary brightness/color
modulation also needs visual assessment. Neither presets nor this patch enable
stronger default flashing.

Configuration schema, palette catalog, effect ID, signing settings and restoration
ownership remain compatible. Named presets intentionally replace their parameters;
palette selection changes colors only. Inclusion/Off membership is frozen while
running. Native configuration and topology persist; web Music Mode preferences are
session-only. No raw audio is retained by diagnostics.

The existing generated-frame preview now shares capability masking with output.
Collapsed diagnostics report source, input activity, sample age, processing duration,
features, onset/event counts, grid confidence, effective parameters, generated states,
coalescing/rejection, handoffs, local UDP submission/failure and queue age. Counters
are aggregates, not unbounded histories. The native PCM regression can optionally
write a CSV via `MUSIC_TRACE_PATH`; it contains generated synthetic features/states
and renderer handoffs, not a recording or physical-device acknowledgement.
