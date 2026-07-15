# Music Mode architecture

Music Mode extends LumenDesk's existing `music-pulse` effect and effect lifecycle. It does not introduce a second device model, network stack, or persistence store.

## Data flow

1. `AudioCaptureService` owns the single platform audio source. ScreenCaptureKit captures system audio on macOS; AVAudioEngine captures microphone input on iOS. Subscribers share the session, and accepted buffers enter a single-slot 20 Hz analysis pipeline off the main thread. One reusable Accelerate FFT supplies every frequency band.
2. `MusicFeatureAnalyzer` converts generated or live PCM buffers into normalized level, band, onset, beat, pulse, energy, mood, and confidence features. Adaptive peaks, onset baselines, cooldown, smoothing, and decay live here.
3. `AudioReactiveSessionController` owns one render clock and any number of non-overlapping scope sessions. It samples the latest analysis rather than rendering from every audio callback. Demo sessions can substitute a deterministic synthetic feature pattern.
4. `MusicChoreographyEngine` combines a feature snapshot, `MusicModeConfiguration`, and `FixtureTopology` into a vendor-neutral `MusicLightingFrame`. Its output contains fixture and optional segment IDs, HSB values, transition duration, priority, timestamp, and sequence number.
5. `MusicLightingRenderer` keeps only the latest pending frame per fixture and enforces independent ceilings for LIFX LAN, ordinary Govee LAN, and Govee real-time segment streams.
6. `LightManager` joins the pipeline to LumenDesk's existing effect scope, conflict, undo, Demo Mode, and restoration rules. It translates renderer commands through the existing LIFX and Govee clients. It does not make choreography decisions.

## Topology

`FixtureTopology` is persisted by scope using stable fixture IDs. Explicit order wins; missing fixtures are appended using a deterministic normalized-label and ID sort. A segmented Govee fixture expands into contiguous normalized positions, allowing motion to travel across fixtures and then through the segments within the RGBIC device. Circular topology avoids duplicating the end position.

## Transport policy

- LIFX uses one combined HSBK LAN packet, including brightness and transition duration.
- Ordinary Govee devices use the existing solid-color LAN command with brightness folded into RGB during live frames.
- Recognized Govee RGBIC devices use the volatile Razer/DreamView-style stream for every live segment frame. Music Mode never emits persistent `ptReal` writes per frame.
- When a session stops, the stream is ended and the pre-session snapshot is restored when configured. A saved segment layout may be re-applied once through the normal restoration path; that is intentionally distinct from live-frame output.

## Safety boundaries

Photosensitivity-safe mode is on by default and blocks every flash request. If the user explicitly disables it after a warning, `FlashSafetyLimiter` remains the final gate. It applies both the configured maximum and a non-configurable hard ceiling of three flashes per second. Raw audio callbacks and choreography roles cannot bypass this gate. Reduced Motion also disables flashes and limits movement speed and amount.

High-energy behavior is labeled a sustained-energy event only after energy remains above a hysteresis threshold. The implementation does not claim reliable musical-section or drop detection.

## Persistence and compatibility

Schema version 2 adds `MusicModeConfiguration` and per-scope fixture topologies to LumenDesk's structured state and configuration archive. Decoding supplies Soundcheck-safe defaults for schema 0/1 state and older exports. The catalog identifier remains `music-pulse`, so existing saved effect state and restoration behavior continue to route into Music Mode.

## Verification strategy

Tests generate PCM buffers and deterministic feature snapshots. They cover silence, tones, bass, impulses, cooldown, normalization, topology, segment expansion, lighting bounds, movement, flash enforcement, frame coalescing, provider pacing, multi-scope sessions, restoration, Demo Mode, persistence, and migration. Physical-device validation remains necessary for firmware-specific RGBIC stream behavior and real LAN pacing under a mixed-device load.
