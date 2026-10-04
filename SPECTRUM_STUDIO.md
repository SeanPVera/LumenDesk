# Spectrum Studio — native implementation

The Mac workspace combines Spectrum's graphite/amber visual direction with
Light Table's exact per-region editing and Signal Desk's whole-room visibility.
It is designed for enthusiasts building detailed scenes and panel layouts.

- A native sidebar groups rooms, their devices, and secondary destinations.
- Room overview uses one hardware-aware lane per light, with shared room or
  selected-light controls and a shelf of saved scenes.
- Device detail embeds the existing Nanoleaf, Govee and Luna editors.
- Selected regions expose editable HEX, RGB readouts and numeric intensity.
  None disables painting; All explicitly targets all valid regions. Luna's four
  missing corners can never become edit targets.
- Govee/Luna drafts survive navigation for the shell's lifetime. Nanoleaf keeps
  controller-owned editing sessions. Leaving an editor restores temporary preview
  output through its existing cleanup path. No new persistence schema is added.
- Nanoleaf RGB includes panel intensity; master wall brightness is separate.
  Govee RGB and power remain independent of its 1–100% region intensity. Luna displays chroma
  separately from HSBK brightness. Existing vendor transport handles Apply.
- Running shows retain ownership. Saved scenes retain their original fixture IDs.
  Scene capture uses applied output, excluding presentation drafts.

The browser retains its current UI. iOS retains tabs and uses the shared editor
refinements. Physical output, permissions, VoiceOver and Full Keyboard Access need
release verification on Apple hardware.

Validation uses the existing macOS XCTest suite, AppKit-hosted production view
captures, macOS analysis, and generic iOS compilation. Region-selection regression
tests cover None, removed regions and Luna corners. CI captures room widths,
embedded device editors, exact-value tables, offline states and running shows.
