# Satie

Named after **Erik Satie**, who invented *musique d'ameublement* ("furniture music") in 1917 — sound meant to inhabit a room without demanding attention.

**Satie** is a native macOS **generative focus soundscape** & **120Hz Metal harmonic instrument** living quietly in your menu bar.

**Website & live preview:** [strangechances.com/satie](https://strangechances.com/satie/)

Zero subscriptions, zero virtual audio drivers, zero Electron bloat — **2.4 MB native Apple Silicon app**, **Apple Developer ID signed & notarized**.

## Install

### Homebrew
```bash
brew install --cask graemecode/tap/satie
```

### Direct Download
Download the notarized [Satie-2.2.0.dmg](https://github.com/graemecode/satie/releases/latest/download/Satie-2.2.0.dmg) (macOS 15 Sequoia or later, Apple Silicon), drag **Satie** to **Applications**, and launch.

> **Tip:** Hide Apple's built-in icon in **System Settings → Menu Bar → Now Playing → Don't Show in Menu Bar**.

## Why People Keep It Running All Day
- **Four offline procedural pieces (`FOCUS` Soft Light · `PULSE` Kinetic · `RAIN` Rain & Glass · `DRIFT` Gymnopédie):** Powered by a pure-Swift deterministic 32-bar score engine (`SatieScore`) and lock-free physical-modeling synthesizer (`AVAudioSourceNode`) — FM glassy bells (`-3¢/+3¢`, decaying modulation depth, `2×/4×/9×` overtones, asymmetric `tanh` pickup), 3-player wooden-body bowed strings (`520 / 1,150 / 2,900 Hz` formant tables + delayed vibrato), Pass 2+ harmony-preserving figure swaps & pentatonic water glints, tempo-synced dotted echo, dual-LFO chorus, and 4×4 Hadamard bandpass room reverb. Zero audio sample files.
- **Auto-ducks for calls & music:** Uses Core Audio Process Taps to detect when Zoom, Loom, YouTube, Chrome, or Spotify starts playing — smoothly fades out your focus soundscape, visualizes your external audio live, and gently blooms back in after silence returns.
- **Flow Session Timer (`∞` / `25M` / `50M`):** Subtle hairline progress arc ending with a single warm open-fifth chime.

## Four 120Hz Metal Visual Modes (`1`–`4`)
1. **01 The Circuit** — 240-strand GPU 3D curl-turbulence connectome + 3,200 neural spikes, paired in Studio/Fullscreen with a 24-band sensor mosaic, curved Bézier impulse routing, 4096-pt `vDSP` Circle of Fifths chromagram, musical key detector, and 24 stark-white dB bars.
2. **02 Ecology Wall** — 5,000 stippled GPU colony agents across 5 organic frequency territories, framed by `FULL VIEW` minimap, `ACOUSTIC ANALYTICS`, scrolling thermal `SPECTRAL HEATMAP`, and `SIGNAL EVENT LOG`.
3. **03 Phosphor Scope** — `RGBA16Float` ping-pong CRT Lissajous electron beam with velocity-modulated dwell glow + **P31 Emerald / P39 Amber** toggle.
4. **04 Liquid Warp** — `RGBA16Float` ping-pong curl-noise HDR feedback warp with chromatic dispersion and ACES filmic tonemapping.

## Form Factors & Shortcuts
- **Menu Bar:** Fixed `30pt` 8-bar architectural hairline meter (right-click for Work Soundscapes, Auto-Duck toggle, Sensitivity, Launch at Login, and Global Media Keys).
- **Menu Bar Popover:** Click the menu bar meter for instant focus soundscapes, flow timer, and compact Metal visuals.
- **Floating Mini HUD (`⌘M`):** Draggable borderless corner monitor with hover-only controls.
- **Studio Window (`⌘W` closes back to menu bar):** Resizable native window with per-app **Core Audio Process Tap** isolation (`System Output (All)` or any active audio app).
- **Fullscreen Wall (`⌘F` / `Esc`):** Edge-to-edge installation view with auto-hiding HUD after 2.5s idle.

## Build from Source
```bash
# Run unit tests + build release .app
./scripts/build-app.sh

# Build, install to /Applications, and launch
./scripts/build-app.sh --install

# Full signed + Apple-notarized release DMG
./scripts/build-app.sh --release --install
```
