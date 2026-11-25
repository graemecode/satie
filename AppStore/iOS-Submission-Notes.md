# Satie for iOS — App Store Connect Submission Pack (v4.1.1)

- **App Store Connect Record:** `6837572453` (`com.strangechances.Satie`, universal with macOS)
- **Live App Store URL:** https://apps.apple.com/us/app/satie-focus-soundscapes/id6837572453
- **Version / Build:** `4.1.1` (Build `23`) — major upgrade from live `3.1.0` (Build `18`)
- **Screenshots:**
  - iPhone 6.9" (`1320×2868`): `AppStore/Screenshots-iOS/iPhone/` (`01-dive-oculus.png` through `05-night-nocturne.png`)
  - iPad 13" (`2064×2752`): `AppStore/Screenshots-iOS/iPad/` (`01-dive-oculus.png` through `03-night-nocturne.png`)

## What's New in Version 4.1.1 (Release Notes for App Store Connect)

- **New World — Deep Dive & 06 Oculus:** Evidence-based meditation world pairing bowed cello drones, stochastic rain, bronze singing bowls, and a decelerating 8.5 → 5.5 bpm breath guide with a circadian James Turrell skyspace shader (−90.4% nocturnal blue light after 8 PM or in Sleep Focus).
- **Native 8-Language Support:** Automatically matches your iPhone or iPad language in English, Japanese, French, Simplified Chinese, Traditional Chinese (Taiwan), Spanish, German, and Korean — including Siri Shortcuts and widgets.
- **Dynamic Island, Lock Screen & StandBy Widgets:** Follow live sessions and countdown timers at zero background GPU cost, or start Focus / Deep Dive straight from StandBy and your Home Screen.
- **Apple Shortcuts, Action Button & Focus Filters:** Bind Work Focus to Soft Light or Sleep Focus to Deep Dive with nocturnal low-melanopic mode automatically enabled.
- **Audio & Visual Engine v4:** 16-bit Apple EDR (`rgba16Float`) with spatiotemporal blue-noise dithering across all 6 Metal shaders, 32-tap Velvet-Noise + orthogonal FDN reverb, IRCAM Factor Oracle non-repeating phrasing, non-repeating stochastic rain, and silky beat-locked 14.4 Hz Kinetic Pulse.

## App Store Listing Copy

- **Name:** `Satie`
- **Subtitle (30 chars max):** `Offline Focus Sound & Visuals` *(29 chars)*
- **Promotional Text (170 chars max):**
  `Six calm generative worlds paired with 120 Hz Apple EDR Metal visuals, Dynamic Island & StandBy widgets, and 8 languages. 100% offline, zero tracking.` *(151 chars)*
- **Keywords (100 chars max):**
  `focus,ambient,soundscape,meditation,breath,rain,brown noise,sleep,study,visualizer,offline,minimal` *(98 chars)*
- **Primary Category:** `Music` (Secondary: `Productivity`)
- **Support URL:** `https://strangechances.com/satie/`
- **Marketing URL:** `https://strangechances.com/satie/`
- **Privacy Policy URL:** `https://strangechances.com/satie/privacy/`

## Description

Satie is a native Swift 6 & Metal generative focus and meditation instrument for iPhone and iPad — inspired by Erik Satie's *musique d'ameublement* ("furniture music"), James Turrell's skyspaces, and Braun industrial minimalism.

**Six Unified Audiovisual Worlds**
- **FOCUS — Soft Light:** Studio felt piano, soft-mallet vibraphone, and concert harp paired with a 3D optical connectome (*01 Circuit*).
- **PULSE — Kinetic Pulse:** Silky beat-locked 14.4 Hz beta flow shimmer and soft felt pulse paired with a trigger-locked CRT Lissajous oscilloscope (*03 Scope*).
- **RAIN — Rain & Glass:** Non-repeating stochastic Kyoto courtyard rain with friction-bowed singing glass paired with luminescent water ripples (*02 Ecology*).
- **STILL — Still:** Zero-melody harmonic stillness and warm velvet brown-noise cocoon paired with a monochrome horizon plane (*05 Horizon*).
- **DIVE — Deep Dive:** Meditation engine with decelerating 8.5 → 5.5 bpm breath pacing, bowed cello drone, and bronze singing bowls paired with a circadian James Turrell skyspace (*06 Oculus*) that shifts to low-melanopic 2200 K ember at night.
- **NIGHT — Gymnopédie:** Slow nocturnal felt piano and cello swells paired with warm silk ink blooms (*04 Nocturne*).

**Built for Real iPhone & iPad Workflows**
- **100% Offline & Private:** Synthesizes 48 kHz stereo audio locally from 46 bundled CC0 studio samples, a Velvet-Noise FDN hall, and an IRCAM Factor Oracle composer. Zero accounts, zero analytics, zero network calls, zero permissions.
- **Dynamic Island, StandBy & Lock Screen:** Native Live Activities, pure-OLED StandBy / Lock Screen / Home Screen widgets, AirPods transport controls, and AirPlay routing.
- **Shortcuts, Action Button & Focus Filters:** Automatically launch *Soft Light* during Work Focus or *Deep Dive* in low-melanopic night mode during Sleep Focus.
- **8 Languages Included:** Automatically matches your device language in English, Japanese, French, Simplified Chinese, Traditional Chinese (Taiwan), Spanish, German, and Korean.
- **Mix with Other Audio & Sleep Timer:** Layer Satie (or add Rain / Brown Noise) underneath podcasts or audiobooks, set 15m–90m fade-out timers, tap for Immersion Mode, or rotate horizontally with Keep Screen Awake on a desk stand.

## App Review Information

- **Sign-in required:** No
- **Review Notes:**
  > Satie is a 100% offline generative focus & meditation soundscape instrument and real-time Metal visualizer. No account, network connection, or system permissions are required.
  >
  > Background Audio (`UIBackgroundModes: audio`) is used strictly so users can continue listening while the device is locked or while using other apps.
  >
  > To test: tap Play or any of the six soundscape icons (FOCUS, PULSE, RAIN, STILL, DIVE, NIGHT). Lock the device to verify continuous background audio, Dynamic Island / Lock Screen Live Activity, and Lock Screen transport controls. Tap the options button (bottom right) to test the fade-out sleep timer, optional Rain/Brown Noise layer, visual pairing, Mix with Other Audio, Keep Screen Awake, and the Privacy Policy link. Widgets and Focus Filters ("Set Satie Soundscape") can also be tested from StandBy, Home Screen, or Settings → Focus.

## App Privacy & Age Rating Checklist

- **Data Collected:** `Data Not Collected` (`PrivacyInfo.xcprivacy` declares only `UserDefaults` `CA92.1` + `1C8F.1` for local preferences and shared App Group widget state).
- **Export Compliance:** `ITSAppUsesNonExemptEncryption = false` (no custom encryption).
- **Content Rights:** Yes — uses CC0-1.0 public-domain acoustic samples (Versilian Studios / VCSL) and original procedural synthesis.
- **Age Rating:** `4+` (all content descriptors: None; no user-generated content, no social features, no location sharing, no ads, no in-app purchases).
