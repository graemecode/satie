# Satie

Named after **Erik Satie**, who invented *musique d'ameublement* ("furniture music") in 1917 — sound meant to inhabit a room without demanding attention.

**Satie** is a native macOS **generative focus soundscape** & **120Hz Metal harmonic instrument** living quietly in your menu bar.

**Website & live preview:** [strangechances.com/satie](https://strangechances.com/satie/)

Zero subscriptions, zero virtual audio drivers, zero Electron bloat — **native Apple Silicon app with 45 studio-recorded CC0 acoustic multi-samples + real-time physical & granular synthesis**, **Apple Developer ID signed & notarized**.

## Install

### Homebrew
```bash
brew install --cask graemecode/tap/satie
```

### Direct Download
Download the notarized [Satie-3.0.0.dmg](https://github.com/graemecode/satie/releases/latest/download/Satie-3.0.0.dmg) (macOS 15 Sequoia or later, Apple Silicon), drag **Satie** to **Applications**, and launch.

> **Tip:** Hide Apple's built-in icon in **System Settings → Menu Bar → Now Playing → Don't Show in Menu Bar**.

## Why People Keep It Running All Day
- **Five distinct studio-grade worlds (`FOCUS` Soft Light · `PULSE` Kinetic · `RAIN` Rain & Glass · `DRIFT` Gymnopédie · `STILL` Still):** Fuses **45 studio-recorded CC0-1.0 acoustic multi-samples** (Versilian Studios / VCSL Upright Felt Piano, Soft-Mallet Vibraphone, Concert Harp, Bowed Cello Section, Friction-Bowed Wine Glasses) + real CC0 velvet studio rain played via 4-point Hermite cubic interpolation with **Mutable Instruments *Rings*** 56-mode physical modal resonators, **Mutable Instruments *Beads*** 14-grain live stereo granular clouds (octave shimmer & reverse halos), **3D Woodworth Binaural spatialization**, **Roland RE-201-style wow/flutter Tape Space Echo**, an **8×8 modulated Hadamard FDN acoustic chamber** with early reflections & 4-stage allpass diffusion, **Eno prime-length (5/7/11/13-bar) macro evolution**, and a **24 dB/oct elliptical vinyl-mastering output bus** (strict mono sub-bass, RMS optical glue, 2.5 ms lookahead true-peak limiter) — all lock-free and allocation-free on the Core Audio thread at ~3.8% CPU.
- **Auto-ducks for calls & music:** Uses Core Audio Process Taps to detect when Zoom, Loom, YouTube, Chrome, or Spotify starts playing — smoothly fades out your focus soundscape, visualizes your external audio live, and gently blooms back in after silence returns.
- **Radial Focus Timer & Live Sculptor:** 24-tick circular dial (`∞` / 5–120m with Force Touch tick haptics and Arrival → Deep Lock → Soft Landing audio choreography), 24-hour Circadian Curve, plus live **Depth (`STILL · FLOW · DEEP`)** and **Masking (`OFF · RAIN · BROWN`)**.

## Four 120Hz Metal Visual Modes (`1`–`4`)
1. **01 The Circuit** — 240-strand GPU 3D curl-turbulence connectome + 3,200 neural spikes, paired in Studio/Fullscreen with a 24-band sensor mosaic, curved Bézier impulse routing, 4096-pt `vDSP` Circle of Fifths chromagram, musical key detector, and 24 stark-white dB bars.
2. **02 Ecology Wall** — 5,000 stippled GPU colony agents across 5 organic frequency territories, framed by `FULL VIEW` minimap, `ACOUSTIC ANALYTICS`, scrolling thermal `SPECTRAL HEATMAP`, and `SIGNAL EVENT LOG`.
3. **03 Phosphor Scope** — `RGBA16Float` ping-pong CRT Lissajous electron beam with velocity-modulated dwell glow + **P31 Emerald / P39 Amber** toggle.
4. **04 Liquid Warp** — `RGBA16Float` ping-pong curl-noise HDR feedback warp with chromatic dispersion and ACES filmic tonemapping.

## Form Factors & Global Shortcuts
- **Global Hotkeys (zero permissions required):** `⌥⌘S` summon/dismiss panel · `⌥⌘Space` play/stop · `⌥⌘]` cycle soundscape · `⌥⌘M` instant mute.
- **AirPods & MacBook Media Keys:** Registered with macOS Control Center (`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`) — tap AirPods or press `⏯` / `⏭` to pause or switch pieces.
- **Menu Bar:** Ultra-compact `22pt` 6-bar architectural meter with muted slash indicator (`⌥`-click to stop/mute; right-click for menu; `autosaveName` remembers position right of notch).
- **Notch-Safe Floating Panel (`⌥⌘S`):** Always renders cleanly below the MacBook camera notch, with live 32-bar score strip, live chord/pass readout, instant `STOP` / `MUTE`, flow timer, and `1`–`4` mode switching.
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
