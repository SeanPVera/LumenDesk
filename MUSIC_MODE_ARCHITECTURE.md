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
   analysis queue. Channels are averaged for the FFT and the first two channels
   provide stereo balance. A ring supports arbitrary buffer sizes, a 2048-sample
   Hann window and a 512-sample hop. Rate changes and capture discontinuities reset
   FFT history, tracker and envelopes together. Duplicate/reversed end timestamps
   are rejected. The single-slot ingress guard bounds analysis work; discarded
   buffers are counted and the next accepted buffer starts a new contiguous run.
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
5. **`MusicChoreographyEngine.makeFrame`** applies freshness, configuration, roles
   and topology to produce vendor-neutral HSB states, transition durations,
   timestamp and sequence. No vendor command or second audio pipeline lives here.
6. **`MusicLightingRenderer`** rejects old sequences and frames older than 250 ms,
   keeps at most the newest pending frame per fixture and paces handoffs. Reset
   clears pending frames and sequence history for stopped fixtures.
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

The engine predicts **45 ms plus 0.8 × its 26 ms attack time** ahead. The 45 ms
component is still an **unmeasured assumption**, not device compensation established
by testing. FFT-window delay, capture latency, render quantization, command queues,
Wi-Fi and firmware interpolation are separate contributors. A sent UDP packet
cannot establish any of the last three or a visible light change.

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
- Short/long energy differences and sustained-energy hysteresis provide slow lifts.
  `phraseAware` is retained as a saved key but labeled **Sustained-energy lifts**.
  This is not reliable phrase, chorus or drop recognition.

## Capability and transport boundaries

| Path | Renderer handoff ceiling | Actual command path / limits |
|---|---:|---|
| LIFX LAN | one / 60 ms | Combined HSBK including brightness and transition; local UDP submission and failures counted |
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
band definitions, RMS mapping, flux averaging and time constants more closely;
independent FFT implementations are not claimed bit-exact. Web MIDI derives tempo
from clock intervals and honors Stop/Continue/Start.

`LatestMusicFrameSender` keeps one in-flight request and one latest pending frame,
paces at 10 Hz, expires old frames and drains before restore. The bridge separates
full-value RGB from brightness, opens Govee brightness once per session, and labels
HTTP success as acceptance for local dispatch. Legacy RGB-only callers retain their
previous meaning. Session ownership and manual-control revisions reject stale
frames/restoration after a newer user command. New/returned fixtures do not silently
join a running show's membership. Normal source changes/restarts are serialized.

Web Music Mode has one all-device scope, active roles and presets; it has no native
advanced sliders, saved Music Mode configuration, fixture-order editor or segment
encoder. These limitations must not be presented as parity. Closing a browser tab
cannot guarantee delivery of its asynchronous restoration request; explicit Stop
is the reliable application action, still subject to network/device failure.

## Comfort, persistence and diagnostics

No-flash mode is the UI name for the existing `photosensitivitySafeMode` saved key.
It is enabled by default and blocks explicit flashes. Reduced Motion also disables
flashes and caps movement; changes propagate to active native sessions. The hard
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
