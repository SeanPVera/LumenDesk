# LumenDesk interactive product prototype

Responsive, local-only React/TypeScript prototype for the LumenDesk UX redesign. It sends no real lighting or network commands and requires no backend.

## Run locally

```bash
cd design-prototype
npm install
npm run dev
```

Open `http://localhost:4173/`.

For a production build:

```bash
npm run build
npm run preview
```

## Included flows

1. First-run setup: Welcome → Privacy → Prepare → Discovery → Review → Organize → Ready → Home.
2. Everyday control and scene creation: Home → Room/Light → command feedback → Library → Save Scene → Favorite.
3. Segment Studio: compatible Govee light → selection/paint/brightness/gradient → Live Preview → Cancel or Apply.

Representative interactions also cover search and filters, density, bulk selection, offline failure/retry, animated effects, automation pause, missed actions, Demo Mode, diagnostics, and a menu-bar controller simulation.

## Review sizes

- 1440 × 900 macOS workspace.
- Approximately 1000 × 700 compact macOS window.
- 390 × 844 contemporary 6.1-inch iPhone viewport.
- 320 × 720 narrow mobile overflow check.

## Deterministic simulations

- Commands show Sending after an optimistic update, then Applied locally and Confirmed for online devices.
- Stale/offline devices fail predictably and expose Retry.
- Retry makes the demo device reachable and confirms after a fixed interval.
- Discovery uses a fixed progress delay and exposes found, no-results, and denied states.

## Accessibility

- Native controls and visible focus rings.
- Polite live-region announcements for scanning and command transitions.
- Text/icon redundancy for semantic status.
- Reduced-motion, higher-contrast, and non-blur fallbacks.
- No page-level horizontal overflow at 320 px; intentionally scrollable carousels contain their own overflow.
