# LumenDesk interactive product prototype

Responsive, local-only React/TypeScript prototype for the LumenDesk UX redesign. It sends no real lighting or network commands and requires no backend.

## Live demo

The prototype is published to GitHub Pages from `main`:
<https://seanpvera.github.io/LumenDesk/>

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

## Deploying to GitHub Pages

`.github/workflows/deploy-pages.yml` builds this directory and publishes
`design-prototype/dist` whenever `design-prototype/**` changes on `main`
(or on `workflow_dispatch`). Pull requests run the same build without
deploying, so a broken prototype fails before it reaches the site.

The repository's Pages source must be set to Actions for the deploy to
succeed: **Settings → Pages → Build and deployment → Source: GitHub
Actions**.

GitHub Pages serves a project site from `https://<user>.github.io/<repo>/`,
so the build needs a matching `base` or every asset URL 404s. `vite.config.ts`
reads it from the `BASE_PATH` environment variable, which the workflow fills
from `actions/configure-pages` (`/LumenDesk` here, or `/` for a user site or
custom domain). `dev`, `preview`, and a plain `npm run build` leave it unset
and serve from `/`, so local workflows are unchanged.

To reproduce the deployed build locally:

```bash
BASE_PATH=/LumenDesk npm run build
```

The result must then be served from a matching subpath — opening
`dist/index.html` directly, or serving it at a server root, will not find
the assets.

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
