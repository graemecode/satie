# Acoustic Circuit

A native macOS menu bar audio visualizer & harmonic instrument built with **Core Audio Process Taps**, **Apple Accelerate (`vDSP`)**, and **120Hz Metal**.

No virtual audio drivers (no BlackHole/Soundflower), no Electron bloat — **2.3 MB native arm64 app**, **Apple Developer ID signed & notarized**.

## Install

### Homebrew
```bash
brew install --cask graemecode/tap/acoustic-circuit
```

### Direct Download
Download the notarized [AcousticCircuit-1.0.0.dmg](https://github.com/graemecode/acoustic-circuit/releases/latest/download/AcousticCircuit-1.0.0.dmg) (macOS 15 Sequoia or later, Apple Silicon), drag **Acoustic Circuit** to **Applications**, and launch.

> **Tip:** Hide macOS's built-in icon in **System Settings → Menu Bar → Now Playing → Don't Show in Menu Bar**.

## Visual Modes (`1`–`4`)
1. **01 The Circuit** — 160-strand GPU 3D luminous connectome core + 2,400 spike particles, paired in Studio/Fullscreen with a 24-band sensor mosaic, curved Bézier impulse routing, live Circle of Fifths chromagram, musical key detector, and 24 stark-white dB bars.
2. **02 Ecology Wall** — 5,000 stippled GPU colony agents across 5 organic frequency territories, framed by `FULL VIEW` minimap, `ACOUSTIC ANALYTICS`, scrolling thermal `SPECTRAL HEATMAP`, and `SIGNAL EVENT LOG`.
3. **03 Phosphor Scope** — `RGBA16Float` ping-pong CRT Lissajous electron beam with velocity-modulated dwell glow + **P31 Emerald / P39 Amber** toggle.
4. **04 Liquid Warp** — `RGBA16Float` ping-pong curl-noise HDR feedback warp with chromatic dispersion and ACES filmic tonemapping.

## Form Factors & Shortcuts
- **Menu Bar:** Live 8-bar architectural micro-meter + detected musical key pill (right-click for Sensitivity, Launch at Login, Demo mode, and quick switching).
- **Menu Bar Popover:** Click the menu bar icon for the compact Now Playing replacement.
- **Floating Mini HUD (`⌘M`):** Draggable borderless corner monitor with hover-only controls.
- **Studio Window (`⌘W` closes back to menu bar):** Resizable native window with per-app **Core Audio Process Tap** isolation (`System Output (All)` or any active audio app).
- **Fullscreen Wall (`⌘F` / `Esc`):** Edge-to-edge installation view with auto-hiding HUD after 2.5s idle.
- **Controls:** `Space` play/pause, `1`–`4` switch presets.

## Build from Source
```bash
# Run unit tests + build release .app
./scripts/build-app.sh

# Build, install to /Applications, and launch
./scripts/build-app.sh --install

# Full signed + Apple-notarized release DMG
./scripts/build-app.sh --release --install
```

## Diagnostics
```bash
log stream --predicate 'subsystem == "com.strangechances.AcousticCircuit"' --info
```
