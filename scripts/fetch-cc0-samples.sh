#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/Sources/AcousticCore/Resources/Samples"
TMP_DIR="$(mktemp -d /tmp/satie-cc0-samples.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$OUT_DIR"

VSCO_BASE="https://raw.githubusercontent.com/sgossner/VSCO-2-CE/master"
VCSL_BASE="https://raw.githubusercontent.com/sgossner/VCSL/master"

# Format: out_name|url|max_seconds|trim_db
SAMPLES=(
  # 1. Studio Upright Piano (pianissimo layer — felt/intimate acoustic base)
  "piano_36|$VSCO_BASE/Keys/Upright%20Nr1/UR1_C2_pp_RR1.wav|5.5|-46"
  "piano_43|$VSCO_BASE/Keys/Upright%20Nr1/UR1_G2_pp_RR1.wav|5.5|-46"
  "piano_48|$VSCO_BASE/Keys/Upright%20Nr1/UR1_C3_pp_RR1.wav|5.0|-46"
  "piano_55|$VSCO_BASE/Keys/Upright%20Nr1/UR1_G3_pp_RR1.wav|5.0|-46"
  "piano_60|$VSCO_BASE/Keys/Upright%20Nr1/UR1_C4_pp_RR1.wav|4.8|-46"
  "piano_67|$VSCO_BASE/Keys/Upright%20Nr1/UR1_G4_pp_RR1.wav|4.5|-46"
  "piano_72|$VSCO_BASE/Keys/Upright%20Nr1/UR1_C5_pp_RR1.wav|4.2|-46"
  "piano_79|$VSCO_BASE/Keys/Upright%20Nr1/UR1_G5_pp_RR1.wav|4.0|-46"
  "piano_84|$VSCO_BASE/Keys/Upright%20Nr1/UR1_C6_pp_RR1.wav|3.8|-46"
  "piano_91|$VSCO_BASE/Keys/Upright%20Nr1/UR1_G6_pp_RR1.wav|3.5|-46"

  # 2. Studio Soft-Mallet Vibraphone (VCSL CC0 — Satoshi Ashikawa / Hiroshi Yoshimura warmth)
  "vibe_41|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_F2_v1_rr1_Main.wav|5.5|-48"
  "vibe_45|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_A2_v1_rr1_Main.wav|5.5|-48"
  "vibe_48|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_C3_v1_rr2_Main.wav|5.2|-48"
  "vibe_52|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_E3_v1_rr2_Main.wav|5.0|-48"
  "vibe_55|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_G3_v1_rr1_Main.wav|4.8|-48"
  "vibe_59|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_B3_v1_rr1_Main.wav|4.6|-48"
  "vibe_62|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_D4_v1_rr1_Main.wav|4.4|-48"
  "vibe_65|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_F4_v1_rr1_Main.wav|4.2|-48"
  "vibe_69|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_A4_v1_rr1_Main.wav|4.0|-48"
  "vibe_72|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_C5_v1_rr1_Main.wav|3.8|-48"
  "vibe_76|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Soft%20Mallets/Vibes_soft_E5_v1_rr1_Main.wav|3.6|-48"

  # 3. Studio Concert Harp (VSCO-2-CE CC0 — delicate acoustic plucks)
  "harp_38|$VSCO_BASE/Strings/Harp/KSHarp_D2_mf.wav|5.0|-46"
  "harp_45|$VSCO_BASE/Strings/Harp/KSHarp_A2_mf.wav|4.8|-46"
  "harp_48|$VSCO_BASE/Strings/Harp/KSHarp_C3_mf.wav|4.5|-46"
  "harp_52|$VSCO_BASE/Strings/Harp/KSHarp_E3_mf.wav|4.5|-46"
  "harp_59|$VSCO_BASE/Strings/Harp/KSHarp_B3_mf.wav|4.2|-46"
  "harp_62|$VSCO_BASE/Strings/Harp/KSHarp_D4_mf.wav|4.0|-46"
  "harp_65|$VSCO_BASE/Strings/Harp/KSHarp_F4_mf.wav|3.8|-46"
  "harp_69|$VSCO_BASE/Strings/Harp/KSHarp_A4_mf.wav|3.6|-46"
  "harp_72|$VSCO_BASE/Strings/Harp/KSHarp_C5_mf.wav|3.5|-46"
  "harp_76|$VSCO_BASE/Strings/Harp/KSHarp_E5_mf.wav|3.2|-46"

  # 4. Studio Cello Section Sustained Vibrato (VSCO-2-CE CC0 — organic orchestral warmth)
  "cello_31|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_G1_v1_1.wav|5.5|-50"
  "cello_38|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_D2_v1_1.wav|5.5|-50"
  "cello_41|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_F2_v1_1.wav|5.5|-50"
  "cello_45|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_A2_v1_1.wav|5.5|-50"
  "cello_48|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_C3_v1_1.wav|5.5|-50"
  "cello_52|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_E3_v1_1.wav|5.5|-50"
  "cello_55|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_G3_v1_1.wav|5.5|-50"
  "cello_62|$VSCO_BASE/Strings/Cello%20Section/susvib/susvib_D4_v1_1.wav|5.5|-50"

  # 5. Friction-Bowed Crystal Wine Glasses + Bowed Vibraphone (VCSL CC0 — kankyō glass bloom)
  "glass_52|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Bowed/Vibes_bowed_E3_rr1_Main.wav|5.5|-52"
  "glass_55|$VCSL_BASE/Idiophones/Struck%20Idiophones/Vibraphone/Bowed/Vibes_bowed_G3_rr1_Main.wav|5.5|-52"
  "glass_63|$VCSL_BASE/Idiophones/Friction%20Idiophones/Wine%20Glasses/Sustains/Slow/glass1_D%234_Slow_1_Main.wav|5.5|-52"
  "glass_66|$VCSL_BASE/Idiophones/Friction%20Idiophones/Wine%20Glasses/Sustains/Slow/glass2_F%234_Slow_1_Main.wav|5.5|-52"
  "glass_70|$VCSL_BASE/Idiophones/Friction%20Idiophones/Wine%20Glasses/Sustains/Slow/glass3_A%234_Slow_1_Main.wav|5.5|-52"
  "glass_74|$VCSL_BASE/Idiophones/Friction%20Idiophones/Wine%20Glasses/Sustains/Slow/glass4_D5_Slow_2_Main.wav|5.5|-52"
)

echo "==> Downloading & mastering ${#SAMPLES[@]} CC0-1.0 studio acoustic samples..."

process_one() {
  local spec="$1"
  IFS='|' read -r name url max_sec trim_db <<< "$spec"
  local raw="$TMP_DIR/${name}.raw.wav"
  local f32="$TMP_DIR/${name}.f32.wav"
  local clean="$TMP_DIR/${name}.clean.wav"
  local out="$OUT_DIR/${name}.m4a"

  curl -fsSL "$url" -o "$raw"
  # Decode any 16/24-bit mono/stereo WAV to 48kHz stereo 16-bit PCM for reliable trimming
  afconvert -f WAVE -d LEI16@48000 -c 2 "$raw" "$f32"

  python3 - "$f32" "$clean" "$max_sec" "$trim_db" <<'PY'
import sys, wave, struct, math

inp, outp, max_sec, trim_db = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
with wave.open(inp, 'rb') as w:
    sr = w.getframerate()
    ch = w.getnchannels()
    n = w.getnframes()
    raw = w.readframes(n)

samples = struct.unpack(f'<{n * ch}h', raw)
# Find peak
peak = max((abs(s) for s in samples), default=1)
if peak < 10:
    peak = 1
thresh = peak * (10.0 ** (trim_db / 20.0))

# Find attack onset with 3ms pre-roll
start_frame = 0
for i in range(n):
    v = max(abs(samples[i*2]), abs(samples[i*2+1]))
    if v >= thresh:
        start_frame = max(0, i - int(sr * 0.003))
        break

max_frames = int(sr * max_sec)
end_frame = min(n, start_frame + max_frames)
out_frames = end_frame - start_frame

# Normalize peak to -1.5 dBFS (0.841 * 32767) + smooth 3ms attack & 120ms tail fade-out
gain = (0.841 * 32767.0) / float(peak)
fade_in = min(int(sr * 0.003), out_frames // 4)
fade_out = min(int(sr * 0.140), out_frames // 3)

out_data = bytearray(out_frames * 4)
for idx in range(out_frames):
    src = (start_frame + idx) * 2
    env = 1.0
    if idx < fade_in and fade_in > 0:
        t = idx / float(fade_in)
        env = t * t * (3.0 - 2.0 * t)
    elif idx >= out_frames - fade_out and fade_out > 0:
        t = (out_frames - 1 - idx) / float(fade_out)
        env = t * t * (3.0 - 2.0 * t)
    g = gain * env
    l = max(-32767, min(32767, int(round(samples[src] * g))))
    r = max(-32767, min(32767, int(round(samples[src + 1] * g))))
    struct.pack_into('<hh', out_data, idx * 4, l, r)

with wave.open(outp, 'wb') as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(sr)
    w.writeframes(out_data)
PY

  afconvert -f m4af -d aac -b 256000 "$clean" "$out"
  echo "  ✓ ${name}.m4a ($(du -h "$out" | cut -f1))"
}

export -f process_one
export TMP_DIR OUT_DIR

printf "%s\n" "${SAMPLES[@]}" | xargs -P 8 -I {} bash -c 'process_one "$@"' _ {}

echo "==> Done! Total CC0 studio sample pack size: $(du -sh "$OUT_DIR" | cut -f1)"
