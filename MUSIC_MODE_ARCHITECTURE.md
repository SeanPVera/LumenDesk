# Music Mode architecture

This document is the engineering description. If you want to know how to *use*
Music Mode, read [Music Mode](README.md#music-mode) in the README, which covers
the same feature in plain language: the three steps to a running show, which
preset to pick, what each light's job means, and what the meters are telling
you. The in-app "Explain the controls" switch prints the same explanations
under each control.

Music Mode extends LumenDesk's existing `music-pulse` effect and effect lifecycle. It does not introduce a second device model, network stack, or persistence store.

## Data flow

1. `AudioCaptureService` owns the single platform audio source. ScreenCaptureKit captures system audio on macOS; AVAudioEngine captures microphone input on iOS. A user-selected audio file (both platforms) taps `AVAudioPlayerNode` into the same analyzer. MIDI beat clock (24 PPQ) publishes a locked grid without an audio tap. Subscribers share the session, and every buffer is handed to the analyzer off the main thread; a single-slot guard sheds buffers only when analysis is genuinely behind. Snapshot *publication* to the main thread is throttled separately (~25 Hz, plus every beat).
2. `MusicFeatureAnalyzer` converts generated or live PCM buffers into normalized level, band, onset, beat, pulse, energy, mood, and confidence features. Analysis is a gapless short-time Fourier transform: buffers of any size accumulate into a ring and are analyzed on a fixed 512-sample hop with a Hann window, so no audio is skipped and onset times are accurate to about one hop (~11 ms at 48 kHz). Onsets are half-wave-rectified flux of *log* magnitudes across log-spaced bands, which makes onset strength independent of playback volume and keeps a kick visible against a wall of cymbals. Every time constant is expressed in seconds against the hop duration.
3. `BeatTracker` turns that onset function into tempo and beat phase. Periodicity comes from an autocorrelation of several seconds of onset history, comb-summed with each candidate's second and third multiple so a half- or double-time peak cannot outvote the true beat period, weighted by a log-normal prior around 120 BPM. Phase comes from the offset that best explains where recent onsets landed, then a phase-locked loop predicts the next beat and nudges itself toward observed onsets. **Onsets are not beats:** while a tempo is locked, `beatCount` advances on the predicted grid, so a beat still arrives through a sustained note and a sixteenth-note hi-hat pattern no longer manufactures eight beats a second. The autocorrelation is 3-tap smoothed before the comb sum, because a beat period rarely lands on a whole number of hops and a peak split across two lags would otherwise lose to a rival that happens to land on one. The kick band is autocorrelated **separately** and votes alongside the broadband function (0.55/0.45): mixed into one signal before the transform, dense hi-hats correlate as strongly at a subdivision or a dotted relative as the kick does at the beat, and the search follows the hats. Confidence gates the lock with hysteresis; material with no detectable pulse stays unlocked and keeps the smoothed energy-driven behavior.

   Confidence measures how far the winning period is ahead of its nearest *rival* period, not how far it is above the average of every lag — the latter stays near 1 while two candidates are neck and neck, which let the estimate flip between a beat and its dotted relative dozens of times a run at full confidence, re-anchoring the phase on every switch. Locking additionally requires the onset function to be **peaky**: drums give a tall crest against a low floor, a held chord's analysis ripple does not, and variance alone could not tell them apart. A disagreeing period must win several consecutive estimates before the grid moves, and a simple musical relative (half, double, dotted) must argue twice as long. `MUSIC_MODE_EVIDENCE.md` records the measurements behind all of this.
4. `AudioReactiveSessionController` owns one render clock and any number of non-overlapping scope sessions. It samples the latest analysis rather than rendering from every audio callback. Demo sessions substitute a deterministic groove (four-on-the-floor, half-time, waltz, 6/8, 5/4, 7/8, breaks) that reports the same beat grid a locked live session would. Preset metre/feel overrides are stamped onto the snapshot here so Club stays 4/4 and Waltz stays 3/4 without changing `BeatTracker.beatsPerBar`.
5. `MusicChoreographyEngine` combines a feature snapshot, `MusicModeConfiguration`, and `FixtureTopology` into a vendor-neutral `MusicLightingFrame`. Fixtures carry a role (`wash` / `hit` / `accent` / `motion` / `off`); the engine layers them instead of assigning `index % 3`. Bar accents follow the detected or overridden metre. Its output contains fixture and optional segment IDs, HSB values, transition duration, priority, timestamp, and sequence number.
6. `MusicLightingRenderer` keeps only the latest pending frame per fixture and enforces independent ceilings for LIFX LAN, ordinary Govee LAN, and Govee real-time segment streams.
7. `LightManager` joins the pipeline to LumenDesk's existing effect scope, conflict, undo, Demo Mode, and restoration rules. It translates renderer commands through the existing LIFX and Govee clients. It does not make choreography decisions.

## Capture lifecycle

Concurrent system-audio starts join one pending permission/capture operation. Each scope checks session identity before accepting completion; stopping the final live scope cancels capture immediately. Buffers and file-loop callbacks carry their source generation so queued work cannot publish into a later source. Synthetic snapshots remain separate from live analysis.

The controller permits several rooms to share the same source, and rejects a different source before LightManager changes any lights. File access belongs to the capture service: it acquires and releases the security-scoped URL, taps the player at the file's own format, and detaches the player on failure or stop. Rejoining the same file or MIDI source preserves playback position.

MIDI walks every packet in a callback using CoreMIDI's variable-length packet layout and host timestamps. Stop clears the published grid and suppresses clock ticks until Continue or Start; Continue keeps song position and Start resets it.

## Musical time

The snapshot carries the grid itself — `beatInterval`, `beatReferenceTime` (host clock), `beatInBar`, `beatConfidence`, plus `metre`, `timeFeel`, and `feltInterval` — rather than only "a beat happened". The choreography engine extrapolates its own phase for each render frame from the *felt* interval, so half-time swells on every other beat and a waltz downbeat takes the room. Timing is limited by the render clock rather than by analysis latency, and it evaluates about 45 ms ahead to pay for transport and firmware delay so a swell lands *on* the beat instead of behind it.

`MetreTracker` (folded into `BeatTracker.swift`) scores kick energy across 3/4/5/6/7 and even-versus-odd weight for half/double feel. It never mutates `BeatTracker.beatsPerBar`, which stays 4 so the four-four downbeat heuristic and its tests stay intact. A preset may override the detection (`metreOverride`, `timeFeel`).

Felt-beat phase includes the reference beat's running count before dividing by the felt interval, so refreshing the reference on an intervening detected beat does not restart a half-time pulse. Bar position and bar duration follow the detected grid and metre independently of time feel.

While a grid is available the engine choreographs in musical time:

- Brightness is a **bed plus a swell**. The bed is where a fixture rests; it follows loudness over about half a second, so it carries dynamics. The swell is an accent occupying part of the headroom between the bed and the ceiling, shaped by position inside the felt beat and weighted by position in the bar. Because a fixture falls back to the bed rather than to the floor, a beat reads as an accent on a lit room instead of the room going dark and coming back — which is the difference between a groove and a strobe at the same rate. The swell's depth is not clamped at the headroom: past that it holds at the ceiling for part of the beat, which is what a punchy preset should look like, and brightness itself is still clamped so nothing clips into a discontinuity.
- Swell depth shrinks at fast tempos, so the rate of *visible musical events* stays musical however fast analysis and frame delivery run. The bar accent is deep enough that only the strong beats produce a large swing.
- Release is a fraction of the felt beat with a **floor**, and quiet passages relax further. The constant this replaced clamped to 60 ms for anything at or above 120 BPM, which made every beat a full-depth sawtooth at the render clock.
- Sweeps traverse the room over **bars**, and their brightness depth scales with how many targets the room has: two or three bulbs cannot show travel, so a sweep there is only one more oscillator stacked on the beat. Segmented fixtures keep the full spatial treatment. The engine integrates a rate rather than deriving an absolute phase, so gaining or losing tempo lock changes the speed of the motion without ever jumping its position.
- Palette progression is measured in **whole bars**: an entry is held for an integer number of bars and cross-faded across one beat at the bar line, so a colour change lands on a downbeat by construction. The accumulator this replaced quantized to its own boundaries, which drifted against the bar.
- Hue contributions from `mood` and `chroma` are smoothed, and the chroma argmax must lead clearly and hold that lead before the hue follows it. Fed raw they put a visible wobble on every fixture. An accent fixture sits on the complementary colour for the whole show rather than flipping 180° whenever a snare crosses a threshold.

`MusicalClock.strength` cross-fades all of that against the energy-driven behavior, so a track that drifts in and out of a clear beat does not snap between two different shows. It is derived from `beatConfidence` over a 0.25–0.70 window; now that confidence reflects genuine ambiguity rather than peak prominence, that cross-fade does real work — an unsure grid renders the smooth show instead of a confident wrong one. Off the grid, drive is a smoothed onset envelope with a bounded fall rather than a per-transient retrigger.

## Topology

`FixtureTopology` is persisted by scope using stable fixture IDs. Explicit order wins; missing fixtures are appended using a deterministic normalized-label and ID sort. Per-fixture `roles` are persisted on the same topology. A segmented Govee fixture expands into contiguous normalized positions, allowing motion to travel across fixtures and then through the segments within the RGBIC device. Circular topology avoids duplicating the end position. Role `.off` is dropped from targets the same way exclusion is, and those fixtures are not powered or snapshotted at start. Inclusion and transitions into or out of `.off` are frozen while a show runs; changes among active roles remain available.

## Transport policy

- LIFX uses one combined HSBK LAN packet, including brightness and transition duration.
- Ordinary Govee devices use the existing solid-color LAN command with brightness folded into RGB during live frames.
- Recognized Govee RGBIC devices use the volatile Razer/DreamView-style stream for every live segment frame. Music Mode never emits persistent `ptReal` writes per frame.
- When a session stops, the stream is ended and the pre-session snapshot is restored when configured. A saved segment layout may be re-applied once through the normal restoration path; that is intentionally distinct from live-frame output.
- Fixtures that cannot light every zone at once (the H60B0 uplighter runs two of its three) keep the zones the user chose in the Segment Studio for the whole session. The mask is taken from the saved layout once per frame rather than recomputed from frame content, so the lamp never alternates between zone pairs — which would read as flashing. Choreography is unaware of the limit; the constraint is applied where frames are handed to the transport.

## Safety boundaries

Photosensitivity-safe mode is on by default and blocks every flash request. If the user explicitly disables it after a warning, `FlashSafetyLimiter` remains the final gate. It applies both the configured maximum and a non-configurable hard ceiling of three flashes per second. Raw audio callbacks and choreography roles cannot bypass this gate. Reduced Motion also disables flashes and limits movement speed and amount.

High-energy behavior is labeled a sustained-energy event only after energy remains above a hysteresis threshold. The implementation does not claim reliable musical-section or drop detection.

## Persistence and compatibility

Schema version 2 adds `MusicModeConfiguration` and per-scope fixture topologies to LumenDesk's structured state and configuration archive. Decoding supplies Soundcheck-safe defaults for schema 0/1 state and older exports. The catalog identifier remains `music-pulse`, so existing saved effect state and restoration behavior continue to route into Music Mode.

## Verification strategy

Tests generate PCM buffers and deterministic feature snapshots. They cover silence, tones, bass, impulses, cooldown, normalization, topology, segment expansion, lighting bounds, movement, flash enforcement, frame coalescing, provider pacing, multi-scope sessions, restoration, Demo Mode, persistence, and migration.

Beat tracking is tested from recorded onset envelopes and exact timestamps (`BeatTrackerTests`), so lock, phase accuracy, tempo changes, downbeat placement, and refusal to lock onto unstructured input are all deterministic. End to end, `MusicModeTests` feeds a synthesized four-on-the-floor pattern *with sixteenth-note hats* and asserts the analyzer reports the 120 BPM pulse rather than the eight-per-second transient rate.

Two fixture details matter when adding cases here: generate continuous tones with a running sample offset, because analysis windows straddle buffer boundaries and a restarted phase is a broadband click at every seam; and index a beat by its *nearest* boundary rather than by `floor`, so a frame a hair early is not attributed to the previous beat.

Beyond the deterministic cases, `MusicModeTests` also pins the behaviour that made the show read as flashing: per-beat brightness ratio bounded from both sides, large-swing rate below the flicker threshold, restraint in quiet passages, no invented pulse at low beat confidence, hue held through chroma and mood noise, and colour held across bars. The two tempo regressions drive `MusicFeatureAnalyzer` with synthesised audio rather than a hand-written onset function, because **fed an idealised ODF the old search handled dense subdivisions perfectly** — the failure only appears in the flux of realistic material, which is why the bare-ODF cases in `BeatTrackerTests` never caught it.

Physical-device validation remains necessary for firmware-specific RGBIC stream behavior and real LAN pacing under a mixed-device load. It is also the only way to check `outputLatencyCompensation`: 45 ms is an assumption in the code, not a measurement, and the per-transport delays almost certainly differ. `MUSIC_MODE_EVIDENCE.md` lists the checks that still need a human and a room.
