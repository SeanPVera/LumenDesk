# Music Mode production evidence — 2026-09-24

Reviewable patch: [PR #105](https://github.com/SeanPVera/LumenDesk/pull/105), branch
`fix/music-mode-production-audit`. Nothing was merged, released or installed.

**Installed-app/source match is unknown.** This environment cannot inspect the
user's installed macOS app or lights. Do not attribute an observed old build's
behavior to this source. Record the installed app's version, build, executable
hash and provenance before the listening comparison; version 1.0/build 1 alone
cannot distinguish these commits.

## Baseline and evidence provenance

| Item | Established |
|---|---|
| Baseline | Clean `main@3ceeec29d88a9193be5c3402779a376a27b07e59`; tree `0192e4b3cfb06a900ab89d5acc258fe5dbfb829e` |
| Recent changes | `3ceeec2` theme catalog (#102); `90aad38` Music Mode merge (#103), including `b2dc66c`; `c665f31` prior controls audit (#101) |
| Instructions | CLAUDE.md, README, architecture, evidence and Music Mode control rows read; no applicable AGENTS.md found |
| Local environment | Linux, Node v24.19.0; no Swift/Xcode or installed macOS app |
| Native configuration | LumenDesk scheme, Debug; macOS 13 / iOS 16 deployment targets; Swift 5 language mode; `com.lumendesk.LumenDesk`, version 1.0/build 1, team SW2N54YNK3 unchanged |
| Baseline local tests | `npm --prefix web/bridge test`: **58/58 passed**; web `npm ci` and `npm run build`: passed |
| Baseline native evidence | Existing main Build run [35686114065](https://github.com/SeanPVera/LumenDesk/actions/runs/35686114065) succeeded. This is a retrieved CI result, not local execution |
| New native execution | Actual macOS Swift/XCTest and generic iOS build through repository CI on macos-15; code-signing disabled only for CI, as before |
| Physical evidence | None: no listening, visible lighting, device latency, packet-loss or installed-app measurements |

The previous version of this document described an **uncommitted Node translation
of Swift**, including claims of exact ports and simulated before/after percentages.
Those figures and `music-mode-timeline.svg` are historical simulation material,
not native production execution and not acceptance evidence for this patch. The
shipped TypeScript tests below execute the real browser implementation, and are
labeled separately from Swift. No third DSP implementation was introduced.

## Material findings, ranked by likely contribution

Ranking is a causal assessment of source and deterministic tests, not an observed
ranking in the user's room. Browser-only findings do not explain a native app by
themselves.

| Rank / location | Trigger and mechanism | Visible consequence / status |
|---|---|---|
| 1. Browser `session.ts` Worklet/tick; bridge `/music/frame` | Latest 128-sample worklet buffer overwritten until a 20 Hz render tick; at 48 kHz only about 2,560/48,000 samples/s reach analysis under ideal scheduling. Stale PCM can be analyzed again. RGB value did not control LIFX's separate brightness channel; 250 ms default transitions repeatedly interrupted | A discontinuous, slowed analysis clock and missing brightness envelope. Confirmed source path plus pre-fix regression failures. Continuous capture consumption, independent brightness and transitions repaired |
| 2. `MusicChoreographyEngine.makeFrame`, native + web | Minimum floor bypasses master zero; flashes and old smoothing state bypass a newly lowered ceiling; nonzero base accent persists at sensitivity zero. Independent auto-gain makes quiet audio approach loud levels | Controls cannot restrain output as labeled; dynamics lose contrast. Native baseline tests fail, current tests exercise final bounds, zero response, PCM dynamics. Bed remains independent of accents; crest bounded without flattening every loud beat |
| 3. `AudioLevelMonitor` / freshness / engine | Receipt-time anchoring, unmarked dropped buffers, sample-rate history splice, and last snapshot held indefinitely after missing input. Off-grid max-envelope reuses the last onset | False seams or persistent energy after useful capture disappears. Monotonic buffer-end timing, discontinuity reset, duplicate rejection, generations and explicit freshness added. PCM/stale tests run; real interruption remains H |
| 4. Palette progression / role color | Accent invents a complement; transient mood/chroma alters selected colors; zero color-change still progresses; reacquired absolute beat count moves palette immediately | Theme drift and unrelated hue changes. All-role one-color and zero-hold tests fail on baseline Swift; fixed in both engines. New reacquisition test preserves current position |
| 5. Small-room topology / stereo | Linear positions 0 and 1 coincide on the sine wave; Mac capture downmix removes stereo before analyzer; metre samples only the hop where a predicted event fires | Two bulbs move together, stereo control is ineffective, metre sees a poor sample of kick weight. Linear spacing and preserved channels repaired; completed beat windows feed metre. Physical layout/automatic metre reliability still limited |
| 6. Renderer / transports / lifecycle | Renderer accepts old sequence/age; native ordinary Govee pending color survives stop; web launches overlapping HTTP requests and can restore over a newer manual edit | Stale changes, queue lag and scene interference. Latest-frame expiry, cancellation, owner guards, serialized web stop/restore, bridge revision checks added and tested at component/loopback levels |
| 7. Evidence and UI claims | “Working,” “safe,” “20 fps,” and timing compensation conflate bindings, generated output and visible output | Misleading confidence. Diagnostics distinguish stages; no-flash wording, sustained-energy labels, unsupported-control reasons and documents corrected |

## Rechecking the previous fixes

- **Dense kicks/hats and the prior dotted-tempo regression:** existing native
  `testTempoHoldsThePulseThroughDenseRealisticMaterial` now actually executes in
  macOS CI, with its >90% correct-tempo and <4 switches assertions unchanged.
  The original 120 BPM kick/hat lock and beat-count tests also remain intact.
  This supports those fixtures, not all music.
- **Sustained false confidence:** native 20 s continuous chord test retains zero
  locked snapshots and confidence <.38; production web chord test also has zero
  locks after settling. Does not establish behavior for vibrato, tremolo or room noise.
- **Envelope/comfort:** existing native ratio, quiet restraint, large-swing rate,
  low-confidence and half-time tests retained. New headroom curve initially broke
  role contrast and quiet restraint, then a broad Hit contour broke half-time
  contrast. CI caught these; production contours were corrected without relaxing
  those assertions. These are engineering proxies, not medical/perceptual guarantees.
- **Color stability:** earlier smoothing did not preserve single-color theme
  identity for every role or make zero mean hold. New tests establish both.
- **Native/web drift:** substantive capture, analyzer, MIDI, beat-count and
  brightness differences were present. Corrected production paths now have tests
  in both languages; no claim of bit-exact FFT or complete behavioral parity.
- **Pacing:** renderer unit limits do not establish transport throughput. Native
  Govee still has 100 ms/device datagram spacing underneath a 50 ms segment handoff
  ceiling. A claim that transport was conclusively “not the bottleneck” was unsupported.
- **Latency:** `outputLatencyCompensation = .045` remains an assumption. The engine
  also predicts by 0.8 × its .026 s attack. Neither number is a hardware measurement.

## Reproducible methods and results

### Actual native production tests

`MusicModeTests.testPCMProductionPipelineAcrossFormatsAndDynamics` drives the
production analyzer → choreography → renderer using continuous PCM kick + dense
sixteenth hats for 14 s, Soundcheck, one LIFX fixture, approximately 20 Hz rendering.
The generator uses a running sample offset; no oscillator restarts at buffer seams.
There is no audio capture framework or real transport in this deterministic test.

| Sample rate / chunk | Locked render samples after 8 s | Within 120 ± 6 BPM | Renderer handoffs over 14 s |
|---|---:|---:|---:|
| 48 kHz / 128 | 119 | 119 (100%) | 140 |
| 48 kHz / 1024 | 119 | 119 (100%) | 184 |
| 44.1 kHz / 512 | 120 | 120 (100%) | 140 |
| 44.1 kHz / 2048 | 121 | 121 (100%) | 151 |

These values were emitted by native CI at `53e4f24` and remained the same in
subsequent PCM runs. At least 60 locked render samples avoids vacuous success;
>90% within ±6 BPM tolerates onset/FFT resolution while excluding half, double
and dotted relatives. Sample age must be <= one 512-sample hop + 1 ms, excluding
real capture buffering. Handoffs must be <=235 (60 ms minimum plus first frame).
Different chunk boundaries change handoff count; these are not device receipts.

Other native production cases:

- Fixed-level 440 Hz PCM at .04 and .8 amplitude: reported levels **.18099 and
  1.0**. Quiet must remain >.1 and separation >.3; this is analyzer level, not
  light brightness. Onset gain remains adaptive. Duplicate timestamp rejected.
- Forty-second continuous PCM ramp 110→130 BPM and step 108→132 BPM at 18 s:
  **375/375** locked snapshots within ±6 BPM during final eight seconds for each.
  This tests settled recovery/drift, not an instantaneous transition guarantee.
- Ten seconds rhythm, twelve silence, fourteen recovery: late silence unlocks
  with energy <.01; recovered grid is 120 ±6. Stale non-silent snapshots also
  fade through silence policy rather than retriggering forever.
- Existing onset-driven BeatTracker tests cover gap prediction, phase, tempo
  changes and non-rhythmic input. Existing direct MetreTracker tests cover 3 and 4;
  deterministic Demo grooves cover 3/4, 5/4, 6/8, 7/8 and half-time. These are
  **not** all PCM automatic-metre validation.
- Native manager/controller tests cover shared permission, canceled starts,
  source conflicts, multiple scopes, excluded fixtures, live configuration,
  restore preferences, failed startup and legacy persistence. Renderer tests
  cover coalescing, provider pacing, stale sequence/age rejection and reset.

For a deterministic CSV of actual production output, set `MUSIC_TRACE_PATH` when
running the named PCM test. Columns contain format, time, tempo, confidence,
onset, event count, level, generated brightness and handoff count. This trace
contains only synthetic test data. The app's generated preview additionally uses
the shared real-device capability mask; it is not a physical-light preview.

### Before/after regressions on the same native inputs

`scripts/check_music_controls_baseline.sh` archives exactly `3ceeec2`, copies the
same two new control tests into that temporary checkout, builds Swift and runs
only those tests. It requires assertion failures in **both** tests; a compile
failure is not accepted as evidence. Current code runs the same assertions in
its regular suite.

| Identical test / settings | Baseline native | Repaired native |
|---|---|---|
| Master .5 / maximum .2, live after bright frame; flash enabled; then master 0 | Failed bounds/black assertions | Pass |
| Every role, red-only palette, noisy mood/chroma; then color-change 0 across bars | Failed hue/hold assertions | Pass |

Run [36008143805](https://github.com/SeanPVera/LumenDesk/actions/runs/36008143805)
shows the baseline tests ran and failed (963 assertions across two tests), while
the repaired suite at `53e4f24` passed 234 tests and the iOS build. Assertion count
reflects repeated color samples, not 963 independent defects.

### Shipped web production code and loopback transport

`npm --prefix web/app test` compiles `src/music` using
`tsconfig.music-tests.json`, then imports those emitted modules. There is no
copied analyzer/engine in the harness. **20 tests pass** at the final local check.
The first six assertions were also run against unchanged baseline modules before
repairs: **all six failed** (zero master, live ceiling, role palette, zero color,
independent brightness/transition, no render-clock PCM re-analysis).

Four-format kick/hat cases: 100% of locked render samples after 8 s were within
±6 BPM; final tempos **119.856** at 48 kHz and **120.084** at 44.1 kHz. A quiet .04
versus loud .8 kick signal produces mean generated brightness **.1851 vs .2951**
over seconds 5–10, same Soundcheck fixture/settings. The >.08 separation checks
retained dynamics, not merely lower variance. Chord, drift/step, duplicate/stale
input, stereo/rate switch, sample consumption, zero control, role/half-time,
MIDI and one-in-flight cancellation tests also execute.

`npm --prefix web/bridge test`: **60/60 pass**, versus 58 baseline. New loopback
integration cases verify independent LIFX HSBK brightness/transition and Govee
RGB/global-brightness behavior, restoration, and rejection after newer manual
control. Existing tests assert no invented `razer`, `ptReal` or LIFX segment
packets on the browser path. Loopback device simulators receive real UDP; that is
stronger than a mocked send, but still not physical firmware or Wi-Fi.

### Adversarial ambiguity probe: unresolved, not a passing accuracy test

After `npm --prefix web/app test`, run:

```sh
cd web/app
node --import ./test/register.mjs test/probe-ambiguity.mjs
```

This imports the shipped analyzer. It reports characterization without disguising
an accuracy failure as a green regression. All signals use continuous 48 kHz PCM,
1024-sample buffers and an intended 120 BPM grid:

| 24 s input | Final observed web result | Interpretation |
|---|---|---|
| Syncopated kicks at beats 0, 1.5, 2.5 with snare/backbeat and sixteenth hats | ~80.09 BPM, confidence .625, automatic double feel | **Wrong dotted relative persists**; not certified fixed |
| Sparse half-time kick/snare with dense hats | Unlocked, confidence .206 | Falls back to atmosphere; does not prove correct automatic half-time recognition |
| Strong kick every third beat | ~119.86 BPM, metre 6 | **3 versus 6 ambiguity persists**; override is needed |

These probe numbers are web production results, **not Swift execution**. A
matching PCM native ambiguity corpus and broader genre/recording comparisons are
still needed. Existing native half-time rendering and explicit metre support
remain tested; reliable automatic metre identification is not claimed.

## Build and test execution record

Commands used locally:

```sh
npm --prefix web/bridge test
npm --prefix web/app ci
npm --prefix web/app test
npm --prefix web/app run build
git diff --check
python3 scripts/audit_lighting_themes.py
```

Native CI commands (macos-15, actual Xcode):

```sh
xcodebuild -project LumenDesk.xcodeproj -scheme LumenDesk -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath "$RUNNER_TEMP/DerivedData/macOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
scripts/check_music_controls_baseline.sh
xcodebuild -project LumenDesk.xcodeproj -scheme LumenDesk -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath "$RUNNER_TEMP/DerivedData/iOS" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

- Initial patch native run [36006797033](https://github.com/SeanPVera/LumenDesk/actions/runs/36006797033): macOS tests and iOS build passed.
- `53e4f24` run [36008143805](https://github.com/SeanPVera/LumenDesk/actions/runs/36008143805): 234 native tests passed, baseline regression failures proved, iOS build passed.
- `4665a7d` run [36009456152](https://github.com/SeanPVera/LumenDesk/actions/runs/36009456152): 236 native tests, **2 failed** (Hit contrast, quiet restraint); later iOS step not run.
- `56acc2b` run [36010100374](https://github.com/SeanPVera/LumenDesk/actions/runs/36010100374): 236 native tests, **1 failed** (half-time contrast); later iOS step not run. Assertions retained; Hit crest corrected.
- Final revision: native CI verification pending while this record is assembled; replace this line with the exact completed run before delivery.
- Web PR workflow builds/tests only; its deployment job is restricted to main. No site was published by this patch.
- Not run: installed app/UI automation, signing/notarization, physical capture permission flows, browser permission dialogs/tab teardown, device acknowledgements/visible output, congested real LAN, offline/reconnect on actual firmware, medical safety evaluation.

## Practical listening and next measurement

1. Establish the installed build's provenance. Save a scene; choose Soundcheck,
   no-flash mode, your real fixture order. Use two bulbs first, then a strip; keep
   brightness comfortable. Open diagnostics and note source, age, confidence and
   transport counters. Do not assume a counter means a light changed.
2. Steady dance material: kick should anchor recognizable accents while added
   sixteenth hats do not make the whole room sparkle at hat rate. Compare Wash
   and Hit; verify master zero, a live low ceiling and single-color palette.
3. Half-time/syncopation: compare Auto and the Half-time preset. Check for an
   unwanted accent on intervening beats or an 80/120/160 relative. If the grid is
   wrong, record its confidence rather than claiming the recording is wrong.
4. Sustained/quiet music: pad/vocal intro should hold atmosphere and lose grid
   confidence. Quiet should remain useful; louder material should gain headroom.
   Pause/end capture and verify settling, then Stop and confirm restoration.
5. Changing tempo and non-4/4: try a gradual ramp and a track transition, then a
   waltz with Auto and explicit 3/4. Observe lock release/recovery and check that
   color does not jump when the grid returns.
6. Lifecycle: rapid start/stop, source replacement, two non-overlapping rooms,
   overlapping manual edits, one offline light and reconnection. New manual
   intent must survive Stop. For supported Govee segments, verify saved active
   zones remain fixed and no persistent-write behavior occurs during playback.

**Most useful next measurement:** record audio reference and visible light output
with a synchronized photodiode (or adequately timed high-frame-rate camera), plus
the new software timing counters, separately for LIFX, ordinary Govee and segment
streaming. Measure latency distribution and beat-alignment error under quiet and
loaded LAN conditions. That would separate analysis/clock error from command
queueing and firmware delay, and provide a defensible replacement for the 45 ms
assumption. Do not tune it from successful UDP submission alone.
