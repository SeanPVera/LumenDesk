# LumenDesk brand identity — Spectral Bench

## Brand idea

LumenDesk is the local lighting instrument for a home. It gives mixed LIFX and Govee lights one dependable place to be found, grouped, cued, and controlled.

The product should feel closer to an optical bench than to a lifestyle dashboard: precise, cold, machined, and honest about what the hardware did. A beam enters, it separates, and every light on the network lands somewhere along that spectrum.

**Positioning:** direct local control for people whose lights outgrew one vendor app.

**Product promise:** every light on the network, under one desk.

**Signature line:** One desk for every local light.

## The one rule

> **Chrome is achromatic. Colour means light.**

Everything below follows from it. Interface surfaces are cool obsidian neutrals with no hue of their own. The only colour authored into the product is a single dispersion ramp — the visible spectrum — sampled at fixed wavelengths for every semantic role the app needs, and drawn whole as the sole branded ornament. Illumination is rendered in beam white, so a lit control reads as *lit* rather than as *branded*. A physical light's own colour is data and appears only inside the controls that show or edit it.

The payoff: on any screen, the coloured thing is the light. Nothing competes with it.

## Audit of the previous identity

“The Lighting Desk” fixed the right problem — it replaced a generic cyan/violet/pink gradient system with something calmer and more specific. What it did not fix was the layer underneath:

- The palette was authored, but the *controls* were stock. `Slider`, `.toggleStyle(.switch)`, `.pickerStyle(.segmented)`, and `.toggleStyle(.button)` carried the product's primary interactions. A themed stock control still reads as a themed stock app.
- Warm graphite and signal amber are a well-worn pairing for anything wanting to look like professional equipment. It was tasteful, and it was not ours.
- Amber marked interface action while device colour marked lights, so two different colour languages competed for the same attention on every row.
- Soft 12–16 pt radii, capsules, and circular status dots gave every card the same silhouette as every other card in every other dark-mode app.
- The serif display voice read editorial rather than instrumental — closer to a magazine than to a console.

This direction keeps the information architecture, command-state clarity, accessibility work, and platform-native navigation. It replaces the palette, the type, the geometry, and — most importantly — the controls.

## Logo system

The mark keeps the geometry LumenDesk has always had and changes what the beam is made of. Light leaves a source slot white and lands on the desk rail as the full visible spectrum.

### Mark construction

- The upper slot is the source.
- The tapered centre is the controllable beam. Colour runs *across* it and saturation runs *down* it, so the mark reads as light separating rather than as a gradient poured into a shape.
- The lower rail is the desk and the stable control plane.
- The three vendor indicator dots are gone. The beam now carries that meaning: many colours, one surface.

### Lockups

- **Primary lockup:** colour mark with the LumenDesk wordmark in SF Pro Condensed Bold, uppercase, over a spectrum rule.
- **Compact mark:** colour aperture for onboarding, the menu-bar popover, repository avatar, and app icon.
- **Monochrome mark:** one-colour version for the macOS menu bar, small utilities, print, and constrained surfaces.
- **App icon:** the dispersing beam on a near-black tile. Small macOS sizes use hand-tuned geometry from `scripts/generate_brand_assets.py`.

Do not substitute a stock lightbulb, sparkle, orb, prism, or gradient letterform for the brand mark. A literal glass prism throwing a rainbow is specifically off-limits: it belongs to an album cover, not to this product.

## Colour system

### The bench — neutrals

| Role | Name | Value | Use |
| --- | --- | --- | --- |
| Window well | Void | `#04060A` | Deepest ground, key legends, wells |
| Base | Bench | `#080B11` | Main application background |
| Surface | Panel | `#0E1219` | Rows and standard panels |
| Raised | Faceplate | `#151A23` | Sheets, hover, elevated controls |
| Emphasis | Machined | `#1E2530` | Selection and important control groups |
| Border | Rule | `#1F2732` | Default hairlines |
| Strong border | Rail | `#333D4B` | Focused grouping and raised dividers |
| Primary text | Chalk | `#E8EEF7` | Headings and primary labels |
| Secondary text | Meter | `#9AA6B5` | Supporting copy |
| Tertiary text | Muted | `#64707F` | Metadata and quiet labels |

### The beam — illumination

| Role | Name | Value | Use |
| --- | --- | --- | --- |
| Interaction | Beam | `#DCE7F6` | Selection, lit keys, primary control |
| Illuminated | Beam bright | `#F6FAFF` | Key faces, focus ring, live readouts |
| At rest | Beam dim | `#8C99AB` | Unlit legends, inactive instrument labels |

### The ramp — every semantic colour in the product

Eight samples along the visible spectrum, short wavelength first. Nothing outside this list is coloured.

| Sample | Value | Semantic role |
| --- | --- | --- |
| 400 nm violet | `#6C4BF0` | LIFX fixtures, mid-band energy |
| 460 nm blue | `#3D7BF5` | Ramp continuity |
| 490 nm cyan | `#21C4DE` | Local link, discovery, network truth |
| 530 nm green | `#46D08A` | Online, confirmed, success |
| 570 nm yellow | `#D9D45F` | Ramp continuity |
| 590 nm amber | `#FFB13D` | Stale, partial, paused, warning |
| 620 nm orange | `#FF7A38` | Music, motion, creative energy |
| 660 nm red | `#F1495C` | Failure and destructive feedback |

Magenta `#E2569E` closes the ramp where a colour wheel must wrap.

Drawn whole, the ramp is the brand: a `SpectrumRule` under a page title, the underline on the live segment of a selector, the rail down a panel the user is working in, the fill of a music fader.

## Typography

No serif. Three voices:

- **SF Pro Condensed** (`LumenType.display`) — titles, page headers, device names. Condensed grotesque reads technical rather than editorial, and it holds up in the uppercase, wide-tracked settings the product uses for orientation.
- **SF Mono** (`LumenType.readout`, `LumenType.instrumentLabel`) — every measured value and every engraved label. If the user reads it as a number that changes, it is monospaced.
- **SF Pro** — body copy, controls, and platform navigation.

Rule of thumb: condensed names things, mono measures things, and SF Pro explains things.

## Shape and composition

- Radii collapse to 5 pt for panels, 4 pt for tiles, 3 pt for controls. The bench is machined, not moulded.
- **One corner is cut.** `LumenPanelShape` chamfers the top-trailing corner of every panel, which is what makes a stack of them read as one rack. It is the product's silhouette; use it rather than inventing another.
- Panels carry a 1 px lit top edge, a hairline stroke, and — when the user is working in them — a 2 px spectrum rail down the leading edge.
- Pills are reserved for nothing. Status indicators are small squares, because every round dot in every dashboard looks the same.
- Shadows stay short and neutral. A physical light may cast a restrained colour halo inside its own control.
- The backdrop is an optical-bench rail: faint graduated rules, not wallpaper.

## Controls

The controls a lighting desk needs do not ship with the platform, so LumenDesk draws its own in `DesignControls.swift`:

| Control | Replaces | Notes |
| --- | --- | --- |
| `LumenFader` | `Slider` | Engraved 20-division scale, machined cap, monospaced readout, drag / arrow keys / VoiceOver adjustable |
| `LumenPowerKeyStyle` | `.toggleStyle(.switch)` on light power | Illuminated console key |
| `LumenRockerStyle` | `.toggleStyle(.switch)` elsewhere | Squared rocker for settings and options |
| `LumenChipStyle` | `.toggleStyle(.button)` | Filter and day-of-week chips |
| `LumenSelector` | `.pickerStyle(.segmented)` | Recessed well, spectrum underline on the live option |
| `LumenIconButtonStyle` | `.buttonStyle(.bordered)` on glyphs | Compact square key |
| `LumenLens` | coloured `Circle()` | A fixture's lens plate — the one place arbitrary colour is allowed |
| `LumenMeter` | ad-hoc capsule bars | Segmented LED meter for watched values |

Native toolbars, menus, alerts, and sheets stay native. Bespoke means the instrument, not the window chrome.

## Iconography

The aperture mark is proprietary. Functional icons remain platform-native SF Symbols so actions keep their learned meaning.

- Use consistent 12, 14, and 18 point optical sizes in navigation, controls, and summaries.
- Pair state icons with text. Colour never carries device or command truth alone.
- Reserve sparkles, wands, and decorative bulbs for content that literally concerns a scene, preset, or light.
- Navigation destinations are numbered like console channels (`01`–`05`) so the sidebar is scannable without reading.

## Voice

LumenDesk speaks like a good instrument label: short, concrete, and close to the action.

### Vocabulary

- Use **desk** for the complete control surface.
- Use **master** for all-light power and level.
- Use **cue** when a scheduled or recalled lighting state behaves like one.
- Use **local link** for network availability.
- Use **scan** for discovery, **preview** for temporary output, and **apply** for durable output.
- Preserve **Sending**, **Applied locally**, **Confirmed by device**, and **Failed** for command truth.

### Voice examples

| Avoid | Use |
| --- | --- |
| Beautiful, local control | One desk for every local light |
| Choose your interface energy | Quiet interface |
| Explore every workflow | Try the controls on a demo rig |
| Your fastest routes | Pinned controls |
| Local effects in one durable destination | Recall a room, build a mood, or put motion on cue |

## Key surfaces

- **Onboarding:** the strongest brand moment. It introduces the aperture, the local promise, mixed-vendor value, and precise setup language.
- **macOS sidebar:** persistent wordmark, channel numbers, spectrum selection rail, and a local-link panel.
- **Home:** a master panel built around a 50 pt monospaced readout, with the fader beneath it.
- **Library:** controlled chrome around expressive, user-created lighting colour.
- **Devices:** spectrum cyan for network truth and explicit command-state language.
- **Music Mode:** the one place the whole ramp appears at once, on faders and segmented meters.
- **Menu bar:** compact aperture mark, current device count, and immediate all-off control.
- **App icon and repository avatar:** the same dispersing beam at every size.

## Accessibility and platform behaviour

- Body text targets WCAG 4.5:1 contrast; meaningful non-text controls target 3:1. The neutral stack is darker than the previous one, which widens the margin on every text pairing.
- The focus colour is Beam bright `#F6FAFF`, paired with native focus behaviour and a dark offset where custom focus appears.
- Every bespoke control is keyboard reachable and exposes a VoiceOver label, value, and — for faders — an adjustable action.
- Reduced Transparency uses opaque Void or Faceplate surfaces. Quiet Interface removes the bench rail and the beam glow.
- Primary mobile targets remain at least 44 × 44 points.
- macOS retains native window, toolbar, menu, keyboard, and sidebar behaviour. iOS retains native tabs, navigation, sheets, and touch controls.
