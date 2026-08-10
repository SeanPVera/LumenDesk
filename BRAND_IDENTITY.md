# LumenDesk brand identity — The Lighting Desk

## Brand idea

LumenDesk is the local lighting instrument for a home. It gives mixed LIFX and Govee lights one dependable place to be found, grouped, cued, and controlled.

The product should feel closer to a small architectural-lighting console than a lifestyle dashboard. It is precise, calm, tactile, and honest about what the hardware did.

**Positioning:** direct local control for people whose lights outgrew one vendor app.

**Product promise:** every light on the network, under one desk.

**Signature line:** One desk for every local light.

## Audit of the previous identity

The previous “Aurora Noir” direction had a strong dark-mode foundation and acceptable contrast. Several choices made it feel assembled from current interface trends instead of authored for this product:

- Cyan, violet, and pink gradients appeared in the wordmark, primary buttons, borders, backgrounds, and decorative glow. The same treatment could brand an AI assistant, crypto dashboard, meditation app, or audio tool.
- A stock filled-lightbulb symbol represented the product inside the interface, while a separate abstract three-beam mark represented it in app assets. That split weakened recognition.
- Rounded type, capsules, radial glows, oversized corner radii, and repeated “aurora” language stacked several familiar generative-design defaults at once.
- Most cards shared the same fill, radius, shadow, and icon treatment. Status, navigation, control, and creative content had too little visual distinction.
- Copy such as “Beautiful, local control,” “Choose your interface energy,” and “durable destination” described a mood around the product. It rarely sounded like a lighting controller.
- SF Symbols carried nearly the entire icon language. They worked functionally, though the product had no recurring proprietary shape inside its own chrome.

The redesign keeps the useful information architecture, command-state clarity, accessibility, and platform-native controls. It replaces the ornamental identity around them.

## Logo system

The LumenDesk mark is an aperture casting one warm beam onto a desk rail. Three small indicators on the rail represent a mixed local network under one control surface.

### Mark construction

- The upper slot is the light source.
- The tapered center is the controllable beam.
- The lower rail is the desk and the stable control plane.
- Blue, amber, and green indicators suggest connected devices without copying a vendor palette.

### Lockups

- **Primary lockup:** color mark with the LumenDesk wordmark in New York Semibold.
- **Compact mark:** color aperture for onboarding, the menu-bar popover, repository avatar, and app icon.
- **Monochrome mark:** one-color version for the macOS menu bar, small utilities, print, and constrained surfaces.
- **App icon:** warm beam on a near-black tile. Small macOS sizes use hand-tuned geometry from `scripts/generate_brand_assets.py`.

Do not substitute a stock lightbulb, sparkle, orb, or gradient letterform for the brand mark. Device controls may continue using SF Symbols when they communicate a standard action.

## Color system

| Role | Name | Value | Use |
| --- | --- | --- | --- |
| Window | Blackout | `#0B0C0A` | Window well, high-contrast controls |
| Base | Worktop | `#11120F` | Main application background |
| Surface | Console | `#191B17` | Rows and standard panels |
| Raised | Fader | `#22251F` | Sheets, hover, elevated controls |
| Emphasis | Patch | `#2B2F27` | Selection and important control groups |
| Border | Rule | `#34382F` | Default hairlines |
| Strong border | Rail | `#4C5345` | Focused grouping and raised dividers |
| Primary | Signal amber | `#E7B35A` | Selection, primary control, signal rail |
| Primary high | Lamp | `#FFD68A` | Illuminated key and aperture source |
| Network | Local blue | `#73B4BD` | Discovery, links, local-network truth |
| Creative | Copper | `#C97852` | Music, motion, restrained creative emphasis |
| Success | Circuit green | `#83B67A` | Online and confirmed |
| Warning | Hold amber | `#D6A24C` | Stale, partial, paused |
| Error | Trip red | `#D86E60` | Failure and destructive feedback |
| Primary text | Chalk | `#F1EFE8` | Headings and primary labels |
| Secondary text | Meter | `#B8B8AF` | Supporting copy |
| Tertiary text | Muted | `#858A80` | Metadata and quiet labels |

Signal amber owns interface action. Local blue owns the network. A physical light’s color remains data and belongs in swatches, previews, segment cells, and restrained live-state indicators.

## Typography

- **New York / serif system design:** brand wordmark, page titles, section titles, and high-level numeric orientation. It gives the interface an editorial, architectural voice.
- **SF Pro:** controls, body copy, forms, device names, and standard platform navigation.
- **SF Mono:** short uppercase instrument labels, network metadata, timings, values, and state readouts.

Serif type should orient the user. Mono should label the instrument. Dense control copy stays in SF Pro for legibility.

## Shape and composition

- Standard panels use 8–12 point corner radii and one-pixel rules.
- Primary buttons resemble illuminated console keys with 8-point corners.
- Capsules are reserved for statuses, tags, and controls whose behavior benefits from the shape.
- A three-point amber signal rail marks selection or a principal control panel.
- Shadows stay short and neutral. A physical light may cast a restrained color halo inside its own control.
- The aperture beam may appear once as a faint background device on brand-led surfaces such as onboarding.
- Palette artwork and Segment Studio may use full color. Routine controls remain quiet.

## Iconography

The aperture mark is proprietary. Functional icons remain platform-native SF Symbols so actions keep their learned meaning.

- Use consistent 14, 18, and 22 point optical sizes in navigation, controls, and summaries.
- Pair state icons with text. Color never carries device or command truth alone.
- Use filled variants for an active state and line variants for rest when the symbol family supports both.
- Reserve sparkles, wands, and decorative bulbs for content that literally concerns a scene, preset, or light.
- Place navigation symbols on the same baseline and use an amber rail for selection.

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

- **Onboarding:** the strongest brand moment. It introduces the aperture, local promise, mixed-vendor value, and precise setup language.
- **macOS sidebar:** persistent wordmark, proprietary selection rail, native destination symbols, and a local-link panel.
- **Home:** serif orientation, instrument-label summaries, and a highlighted Master panel.
- **Library:** controlled chrome around expressive, user-created lighting color.
- **Devices:** local blue for network truth and explicit command-state language.
- **Menu bar:** compact aperture mark, current device count, and immediate all-off control.
- **App icon and repository avatar:** the same aperture geometry at every size.

## Accessibility and platform behavior

- Body text targets WCAG 4.5:1 contrast; meaningful non-text controls target 3:1.
- The focus color is Lamp `#FFD68A`, paired with native focus behavior and a dark offset where custom focus appears.
- Reduced Transparency uses opaque Blackout or Fader surfaces.
- Quiet Interface removes the faint aperture beam and ornamental color activity.
- Primary mobile targets remain at least 44 × 44 points.
- macOS retains native window, toolbar, menu, keyboard, and sidebar behavior. iOS retains native tabs, navigation, sheets, and touch controls.
