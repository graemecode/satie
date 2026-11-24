#include <metal_stdlib>
using namespace metal;

struct AcousticUniforms {
    float2 resolution;
    float2 coreCenter;     // Normalized [0..1] center for Circuit / Ecology focal region
    float  coreScale;      // Scale multiplier for core radius
    float  time;
    float  dt;
    float  bass;
    float  mid;
    float  treble;
    float  energy;
    float  flux;
    float  beat;
    float  stereoCorr;
    float  centroid;
    float  amberMode;      // 0 = P31 Emerald, 1 = P39 Amber (Phosphor Scope)
    float  isCompact;      // 1 = Popover/MiniHUD, 0 = Studio/Fullscreen
    float  chordAge;       // Seconds since last harmonic chord change
    float  barPhase;       // 0..1 within current musical bar
    float  isPlaying;      // 1 = audio playing, 0 = standby
    float4 bands[6];       // 24 log-spaced perceptual bands packed into 6 float4s (offset 80)
    float4 impulses[6];    // 24 per-band transient impulses
    float4 noteA[12];      // Live note events: (pitchNorm, pan, velocity, ageSec)
    float4 noteKinds[3];   // 12 note kind codes (0=figure, 1=melody, 2=glint, 3=sustain)
    float4 breathDepth;    // (breath01, depth01, isNight01, isDeepDive)
    float4 edrParams;      // (edrLinearP3Enabled, edrHeadroom, frameIndex, reserved)
};

static inline float getBand(constant AcousticUniforms& u, int idx) {
    int i = clamp(idx, 0, 23);
    return u.bands[i / 4][i % 4];
}

static inline float getNoteKind(constant AcousticUniforms& u, int idx) {
    int i = clamp(idx, 0, 11);
    return u.noteKinds[i / 4][i % 4];
}

struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenOut fullscreenVertex(uint vid [[vertex_id]]) {
    const float2 pos[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    FullscreenOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = pos[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y; // Top-left origin matching AppKit / CoreGraphics
    return out;
}

// ============================================================================
// UTILITY: HASH, NOISE, SEGMENT DISTANCE
// ============================================================================
static inline float2 hash22(float2 p) {
    p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

static inline float gradNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(dot(hash22(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
            dot(hash22(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
        mix(dot(hash22(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
            dot(hash22(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x),
        u.y
    );
}

static inline float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(1e-6, dot(ba, ba)), 0.0, 1.0);
    return length(pa - ba * h);
}

static inline float2 minDimCoord(float2 uv, float2 center, float aspect) {
    float2 d = uv - center;
    return (aspect >= 1.0) ? float2(d.x * aspect, d.y) : float2(d.x, d.y / max(0.25, aspect));
}

// ============================================================================
// APPLE EDR (EXTENDED LINEAR DISPLAY P3) + 64x64 SPATIOTEMPORAL BLUE NOISE
// ============================================================================
static inline float3 srgbToLinear(float3 c) {
    float3 x = max(c, float3(0.0));
    float3 lo = x / 12.92;
    float3 hi = pow((x + 0.055) / 1.055, float3(2.4));
    return select(hi, lo, x <= 0.04045);
}

static inline float3 linearSRGBToLinearP3(float3 c) {
    // Exact D65 Rec.709 / sRGB linear -> Display P3 linear transform
    return float3(
        0.8224621 * c.r + 0.1775380 * c.g,
        0.0331942 * c.r + 0.9668058 * c.g,
        0.0170826 * c.r + 0.0723974 * c.g + 0.9105200 * c.b
    );
}

static inline float3 additiveColorToTarget(float3 srgbCol, float alpha, float edrBoost, constant AcousticUniforms& u) {
    float3 premul = srgbCol * alpha;
    if (u.edrParams.x > 0.5) {
        float3 linP3 = linearSRGBToLinearP3(srgbToLinear(premul));
        float edrSpare = clamp(u.edrParams.y - 1.0, 0.0, 0.85);
        float circadianCap = mix(1.0, 0.25, clamp(u.breathDepth.z, 0.0, 1.0));
        return linP3 * (1.0 + clamp(edrBoost, 0.0, 1.0) * edrSpare * circadianCap);
    }
    return premul;
}

static inline float blueNoiseTPDF(texture2d<float> bnTex, float2 pixelPos, float frameIdx) {
    uint f = uint(max(0.0, frameIdx));
    // Coprime toroidal offsets mod 64 preserve the exact 2D FFT blue-noise spectrum every frame
    uint2 p1 = (uint2(pixelPos) + uint2(f * 23u, f * 37u)) & 63u;
    uint2 p2 = (uint2(pixelPos) + uint2(f * 23u + 31u, f * 37u + 17u)) & 63u;
    float b1 = bnTex.read(p1).r;
    float b2 = bnTex.read(p2).r;
    return b1 - b2; // Exact zero-mean triangular PDF in [-1, +1]
}

static inline float4 finalizeDisplayColor(float3 srgbCol,
                                          float edrBoostMask,
                                          float ditherAmp,
                                          float2 pixelPos,
                                          constant AcousticUniforms& u,
                                          texture2d<float> bnTex) {
    float bn = blueNoiseTPDF(bnTex, pixelPos, u.edrParams.z);
    // Luminance-modulated perceptual blue-noise dither eliminates 8-bit/10-bit OLED shadow banding
    float lum = dot(max(srgbCol, float3(0.0)), float3(0.2126, 0.7152, 0.0722));
    float darkMask = mix(1.0, 0.45, smoothstep(0.02, 0.45, lum));
    float modeScale = (u.edrParams.x > 0.5) ? 0.62 : 1.0;
    float3 dithered = max(srgbCol + bn * ditherAmp * darkMask * modeScale, float3(0.0));

    if (u.edrParams.x > 0.5) {
        float3 linP3 = linearSRGBToLinearP3(srgbToLinear(dithered));
        float edrSpare = clamp(u.edrParams.y - 1.0, 0.0, 0.85);
        // Protect evening melatonin: nocturnal low-melanopic mode caps EDR peak boost gently
        float circadianCap = mix(1.0, 0.25, clamp(u.breathDepth.z, 0.0, 1.0));
        float gain = 1.0 + clamp(edrBoostMask, 0.0, 1.0) * edrSpare * circadianCap;
        return float4(linP3 * gain, 1.0);
    }
    return float4(dithered, 1.0);
}

// ============================================================================
// PRESET 01: THE CIRCUIT — NOTE-PLUCKED 3D FILAMENT HARP & CHORD HALO
// ============================================================================
fragment float4 circuitBackgroundFragment(FullscreenOut in [[stage_in]],
                                          constant AcousticUniforms& u [[buffer(0)]],
                                          texture2d<float> blueNoiseTex [[texture(1)]]) {
    float aspectVal = u.resolution.x / max(1.0, u.resolution.y);
    float2 d = minDimCoord(in.uv, u.coreCenter, aspectVal);
    float dist = length(d);

    // Architectural Room C gradient (circadian-aware: warm slate-obsidian after 8 PM)
    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);
    float3 inner = mix(float3(0.068, 0.104, 0.172), float3(0.082, 0.056, 0.044), isNight * 0.72);
    float3 midC  = mix(float3(0.030, 0.048, 0.082), float3(0.036, 0.025, 0.020), isNight * 0.72);
    float3 outer = mix(float3(0.014, 0.022, 0.040), float3(0.016, 0.012, 0.010), isNight * 0.72);

    float3 col = mix(inner, midC, smoothstep(0.06, 0.50, dist));
    col = mix(col, outer, smoothstep(0.42, 0.92, dist));

    // Chord-change volumetric bloom + pan/pitch-localized note halos
    float chordBloom = (u.isPlaying > 0.5) ? exp(-max(0.0, u.chordAge) * 1.15) : 0.0;
    float haloR = max(0.14, u.coreScale * 0.56);
    float halo = exp(-(dist * dist) / (haloR * haloR * (0.68 + u.energy * 0.25 + chordBloom * 0.22)));
    float3 haloTint = mix(float3(0.20, 0.30, 0.48), float3(0.38, 0.22, 0.12), isNight * 0.75);
    col += haloTint * halo * (0.18 + u.energy * 0.22 + chordBloom * 0.18);
    // Ring-shaped ambient glow instead of hot white center spot so optical fibers read cleanly
    float ringGlow = exp(-pow((dist - haloR * 0.42) / (haloR * 0.34), 2.0));
    col += mix(float3(0.58, 0.70, 0.88), float3(0.76, 0.50, 0.28), isNight * 0.75) * ringGlow * (0.06 + chordBloom * 0.10);

    if (u.isPlaying > 0.5) {
        for (int n = 0; n < 12; n++) {
            float4 ev = u.noteA[n];
            float age = ev.w;
            if (age > 4.2 || ev.z <= 0.01) continue;
            float env = exp(-age * 1.45) * ev.z;
            float2 nPos = float2(ev.y * 0.26, (0.5 - ev.x) * 0.28);
            float nd = length(d - nPos);
            float ringR = 0.04 + age * 0.075;
            float softBloom = exp(-(nd * nd) / (0.012 + age * 0.012)) * env * 0.09;
            float fineWave = exp(-abs(nd - ringR) * 78.0) * env * 0.11;
            float kind = getNoteKind(u, n);
            float3 nCol = (kind > 0.5 && kind < 1.5)
                ? float3(1.00, 0.86, 0.64)
                : mix(float3(0.66, 0.84, 1.00), float3(0.92, 0.64, 0.38), isNight * 0.72);
            col += nCol * (softBloom + fineWave);
        }
    }

    // Spatiotemporal 64x64 blue-noise dither + linear Display P3 EDR output
    float edrMask = clamp(ringGlow * (0.18 + chordBloom * 0.35), 0.0, 0.40);
    return finalizeDisplayColor(col, edrMask, 0.0065, in.position.xy, u, blueNoiseTex);
}

struct RibbonVertOut {
    float4 position [[position]];
    float4 color;
};

// 240 strands x 112 segments — calm glass sculpture at rest, plucked locally by every struck note
vertex RibbonVertOut circuitRibbonVertex(uint vid [[vertex_id]],
                                         uint iid [[instance_id]],
                                         constant AcousticUniforms& u [[buffer(0)]]) {
    const uint segs = 112;
    uint segIdx = vid / 2;
    uint endBit = vid & 1;
    float frac = float(segIdx + endBit) / float(segs);

    float fi = float(iid);
    const float totalStrands = 240.0;
    float strandNorm = fi / totalStrands;

    int band = int(iid % 24);
    float bv = getBand(u, band);
    float imp = u.impulses[band / 4][band % 4];

    // Calm slow drift at rest; audio + notes are the primary cause of visible motion
    float t = u.time * (0.32 + u.isPlaying * 0.26);
    float phaseA = strandNorm * 6.2831853;
    float phaseB = fract(fi * 0.6180339887) * 6.2831853;
    float phaseC = fract(fi * 0.7548776662) * 6.2831853;
    float freq1 = 1.0 + float(iid % 5) * 0.31;
    float freq2 = 2.0 + float(iid % 7) * 0.27;
    float tilt  = (float(iid % 11) - 5.0) * 0.19;

    // Each strand has a home pitch register (0=low inner shell -> 1=high outer shell) and stereo pan side
    float strandPitch = fract(fi * 0.381966 + 0.13);
    float strandPan = cos(phaseA);

    float noteExcite = 0.0;
    float noteWave = 0.0;
    float noteWarmth = 0.0;
    if (u.isPlaying > 0.5) {
        for (int n = 0; n < 12; n++) {
            float4 ev = u.noteA[n];
            float age = ev.w;
            if (age > 4.5 || ev.z <= 0.01) continue;
            float kind = getNoteKind(u, n);
            float decayRate = (kind > 2.5) ? 0.65 : ((kind > 1.5) ? 2.1 : 1.35);
            float env = exp(-age * decayRate) * ev.z;
            float pitchMatch = exp(-pow((strandPitch - ev.x) / 0.15, 2.0));
            float panMatch = 0.32 + 0.68 * exp(-pow((strandPan - ev.y) / 0.72, 2.0));
            float hit = env * pitchMatch * panMatch;
            noteExcite += hit;
            // Traveling harmonic ripple along the plucked filament
            noteWave += hit * sin(frac * 12.56637 - age * 7.8 + phaseB) * exp(-age * 1.1);
            if (kind > 0.5 && kind < 1.5) {
                noteWarmth += hit; // Melody piano notes glow warm ivory-pearl
            }
        }
    }
    noteExcite = min(noteExcite, 1.8);

    // Three open architectural optical-fiber shells (spacious void center prevents white blowout)
    float shell = mix(0.60, 1.14, strandPitch);
    float baseR = shell * (0.88 + 0.16 * fract(fi * 0.7548776));
    float chordBreath = (u.isPlaying > 0.5) ? exp(-max(0.0, u.chordAge) * 1.3) * 0.08 : 0.0;
    float pulse = 1.0 + bv * 0.16 + chordBreath + noteExcite * 0.22 + noteWave * 0.10;

    float angle = frac * 6.2831853;
    float wobble = 0.18 + 0.10 * sin(angle * freq2 + t * 0.42 + phaseB)
                        + 0.06 * cos(angle * 3.0 - t * 0.28 + phaseC)
                        + bv * 0.14
                        + noteWave * 0.16;
    float theta = angle + phaseA + t * (0.09 + 0.03 * sin(phaseB + t * 0.05));
    float phi = angle * freq1 + phaseB - t * (0.14 + 0.04 * cos(phaseC));

    float rTube = baseR * pulse;
    float x = (rTube + wobble * cos(phi)) * cos(theta);
    float y = (rTube + wobble * cos(phi)) * sin(theta) * 0.88 + sin(phi * 1.5 + phaseC * 0.3) * 0.20;
    float z = wobble * sin(phi) + cos(theta * 2.0 + tilt) * 0.34;

    // Curl displacement blooms when music plays instead of churning constantly
    float2 nCoord = float2(x * 1.3 + t * 0.10, y * 1.3 - t * 0.08);
    float cn1 = gradNoise(nCoord + phaseB * 0.1);
    float cn2 = gradNoise(nCoord.yx + phaseC * 0.1 + 3.7);
    float curlAmp = 0.09 + u.mid * 0.18 + noteExcite * 0.16;
    x += cn1 * curlAmp;
    y += cn2 * curlAmp * 0.85;
    z += (cn1 - cn2) * curlAmp * 0.65;

    float rotY = t * 0.14 + u.bass * 0.18;
    float rotX = 0.36 + sin(t * 0.11) * 0.20;
    float cY = cos(rotY), sY = sin(rotY);
    float cX = cos(rotX), sX = sin(rotX);

    float x1 = x * cY - z * sY;
    float z1 = x * sY + z * cY;
    float y2 = y * cX - z1 * sX;
    float z2 = y * sX + z1 * cX;

    float persp = 2.55 / (3.15 - z2 * 0.68);
    float aspect = u.resolution.x / max(1.0, u.resolution.y);

    float2 centerNDC = float2(u.coreCenter.x * 2.0 - 1.0, 1.0 - u.coreCenter.y * 2.0);
    float radiusNDC = u.coreScale * 0.54;
    float2 pos = centerNDC + float2((x1 * persp * radiusNDC) / max(0.5, aspect), y2 * persp * radiusNDC);

    float depthFade = clamp(0.36 + 0.64 * (z2 * 0.5 + 0.5), 0.12, 1.0);
    float baseAlpha = (iid % 9 == 0) ? 0.14 : ((iid % 3 == 0) ? 0.068 : 0.036);
    // Calibrated linear-EDR opacity so every individual glowing glass filament stays crisp and sculptural
    float alpha = clamp((baseAlpha + bv * 0.09 + imp * 0.10 + noteExcite * 0.30) * depthFade, 0.012, 0.68);

    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);
    float3 coolSilk = mix(float3(0.76, 0.87, 1.00), float3(0.44, 0.72, 0.98), smoothstep(0.40, 0.95, bv));
    coolSilk = mix(coolSilk, float3(0.92, 0.66, 0.40), isNight * 0.72);
    float3 warmIvory = float3(1.00, 0.86, 0.62);
    float3 col = mix(coolSilk, warmIvory, clamp(noteWarmth * 0.90, 0.0, 0.92));

    RibbonVertOut out;
    out.position = float4(pos, 0.0, 1.0);
    float ribbonBoost = clamp(noteExcite * 0.55 + imp * 0.28, 0.0, 0.85);
    out.color = float4(additiveColorToTarget(col, alpha, ribbonBoost * 0.45, u), alpha);
    return out;
}

fragment float4 circuitRibbonFragment(RibbonVertOut in [[stage_in]]) {
    return in.color;
}

struct SpikeVertOut {
    float4 position [[position]];
    float  pointSize [[point_size]];
    float4 color;
};

vertex SpikeVertOut circuitSpikeVertex(uint vid [[vertex_id]],
                                       constant AcousticUniforms& u [[buffer(0)]]) {
    float fi = float(vid);
    int band = int(vid % 24);
    float bv = getBand(u, band);
    float imp = u.impulses[band / 4][band % 4];

    float u1 = fract(fi * 0.6180339887);
    float u2 = fract(fi * 0.3819660113);
    float tSlow = u.time * (0.28 + u.isPlaying * 0.30);
    float phi = acos(1.0 - 2.0 * u1);
    float theta = u2 * 6.2831853 + tSlow * (0.10 + 0.30 * fract(fi * 0.1731)) * (0.50 + bv);

    float pPitch = 1.0 - u1; // top = high pitch, bottom = low pitch
    float pPan = cos(theta);
    float noteSpark = 0.0;
    if (u.isPlaying > 0.5) {
        for (int n = 0; n < 12; n++) {
            float4 ev = u.noteA[n];
            float age = ev.w;
            if (age > 2.8 || ev.z <= 0.01) continue;
            float env = exp(-age * 1.9) * ev.z;
            float match = exp(-pow((pPitch - ev.x) / 0.16, 2.0)) * (0.3 + 0.7 * exp(-pow((pPan - ev.y) / 0.65, 2.0)));
            noteSpark += env * match;
        }
    }
    noteSpark = min(noteSpark, 1.6);

    float rad = (0.48 + 0.60 * fract(fi * 0.7548776)) * (0.86 + bv * 0.24 + noteSpark * 0.28);
    float x = rad * sin(phi) * cos(theta);
    float y = rad * cos(phi) * 0.88;
    float z = rad * sin(phi) * sin(theta);

    float rotY = tSlow * 0.16 + u.bass * 0.22;
    float rotX = 0.36 + sin(tSlow * 0.13) * 0.20;
    float cY = cos(rotY), sY = sin(rotY);
    float cX = cos(rotX), sX = sin(rotX);

    float x1 = x * cY - z * sY;
    float z1 = x * sY + z * cY;
    float y2 = y * cX - z1 * sX;
    float z2 = y * sX + z1 * cX;

    float persp = 2.55 / (3.15 - z2 * 0.68);
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 centerNDC = float2(u.coreCenter.x * 2.0 - 1.0, 1.0 - u.coreCenter.y * 2.0);
    float radiusNDC = u.coreScale * 0.57;

    float2 pos = centerNDC + float2((x1 * persp * radiusNDC) / max(0.5, aspect), y2 * persp * radiusNDC);
    float alpha = clamp((0.12 + bv * 0.36 + imp * 0.28 + noteSpark * 0.65) * (0.45 + 0.55 * (z2 * 0.5 + 0.5)), 0.04, 0.98);

    SpikeVertOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.pointSize = (1.4 + bv * 2.2 + noteSpark * 3.6) * persp * (u.isCompact > 0.5 ? 0.82 : 1.0);
    float3 col = mix(float3(0.92, 0.96, 1.0), float3(1.0, 0.94, 0.82), clamp(noteSpark * 0.7, 0.0, 0.85));
    out.color = float4(additiveColorToTarget(col, alpha, clamp(noteSpark * 0.6, 0.0, 0.75), u), alpha);
    return out;
}

fragment float4 softParticleFragment(SpikeVertOut in [[stage_in]],
                                     float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float mask = smoothstep(1.0, 0.1, r);
    return float4(in.color.rgb * mask, in.color.a * mask);
}

// ============================================================================
// PRESET 02: COURTYARD ECOLOGY — NOTE-SPAWNED WATER RIPPLES & CYMATIC RINGS
// ============================================================================
static inline float2 colonyAttractor(int idx, float t) {
    if (idx == 0) return float2(0.32 + sin(t * 0.14) * 0.04, 0.46 + cos(t * 0.12) * 0.05);
    if (idx == 1) return float2(0.56 + cos(t * 0.11) * 0.04, 0.36 + sin(t * 0.16) * 0.05);
    if (idx == 2) return float2(0.70 + sin(t * 0.18) * 0.04, 0.58 + cos(t * 0.13) * 0.05);
    if (idx == 3) return float2(0.44 + cos(t * 0.13) * 0.04, 0.68 + sin(t * 0.11) * 0.04);
    return float2(0.62 + sin(t * 0.15) * 0.04, 0.30 + cos(t * 0.17) * 0.04);
}

static inline float3 colonyColor(int idx) {
    if (idx == 0) return float3(0.91, 0.93, 0.96); // Chalk white
    if (idx == 1) return float3(0.85, 0.55, 0.37); // Warm terracotta ochre
    if (idx == 2) return float3(0.50, 0.76, 0.68); // Lichen sage / courtyard jade
    if (idx == 3) return float3(0.84, 0.71, 0.42); // Singing bowl gold
    return float3(0.54, 0.68, 0.86);               // Mineral rain slate blue
}

fragment float4 ecologyFieldFragment(FullscreenOut in [[stage_in]],
                                     constant AcousticUniforms& u [[buffer(0)]],
                                     texture2d<float> blueNoiseTex [[texture(1)]]) {
    // Deep charcoal courtyard backdrop
    float3 col = float3(0.045, 0.056, 0.074);

    float screenAspect = u.resolution.x / max(1.0, u.resolution.y);
    bool isPortrait = screenAspect < 0.95;

    // Active courtyard pool bounds (center panel in Studio mode, full frame in landscape compact, open stage in portrait iPhone)
    float2 minB = isPortrait ? float2(0.0, 0.12) : ((u.isCompact > 0.5) ? float2(0.0, 0.0) : float2(0.265, 0.055));
    float2 maxB = isPortrait ? float2(1.0, 0.76) : ((u.isCompact > 0.5) ? float2(1.0, 1.0) : float2(0.745, 0.945));

    if (in.uv.x >= minB.x && in.uv.x <= maxB.x && in.uv.y >= minB.y && in.uv.y <= maxB.y) {
        float2 p = (in.uv - minB) / (maxB - minB);
        float2 boxPx = (maxB - minB) * u.resolution;
        float boxAspect = max(0.35, boxPx.x / max(1.0, boxPx.y));
        col = isPortrait ? float3(0.036, 0.044, 0.058) : float3(0.032, 0.040, 0.054);
        float isNight = clamp(u.breathDepth.z, 0.0, 1.0);
        col = mix(col, float3(0.038, 0.026, 0.020), isNight * 0.65);

        // Whisper-subtle architectural pond survey hairs (recedes quietly behind organic ripples)
        float crossH = smoothstep(0.0018, 0.0, abs(p.y - 0.55));
        float crossV = smoothstep(0.0014, 0.0, abs(p.x - 0.62));
        col += float3(0.84, 0.71, 0.42) * max(crossH, crossV) * 0.045;

        // Delicate ambient rainfall stone-pond shimmer
        float rainMist = gradNoise(p * 18.0 + float2(u.time * 0.09, -u.time * 0.06)) * 0.008;
        col += max(rainMist, 0.0) * mix(float3(0.54, 0.72, 0.82), float3(0.82, 0.54, 0.32), isNight * 0.75);

        if (u.isPlaying > 0.5) {
            // Live expanding concentric water ripples + cymatic standing rings spawned directly by every struck note
            for (int n = 0; n < 12; n++) {
                float4 ev = u.noteA[n];
                float age = ev.w;
                if (age > 5.8 || ev.z <= 0.01) continue;
                float kind = getNoteKind(u, n);
                float2 origin = float2(clamp(0.5 + ev.y * 0.34, 0.14, 0.86), clamp(0.80 - ev.x * 0.58, 0.16, 0.84));
                float2 d = minDimCoord(p, origin, boxAspect);
                float dist = length(d);
                float ang = atan2(d.y, d.x);

                // Expanding physical wave crest + secondary cymatic inner echo
                float speed = (kind > 1.5 && kind < 2.5) ? 0.115 : 0.078;
                float rad1 = 0.018 + age * speed;
                float rad2 = max(0.008, rad1 - 0.042);
                float wobble = 1.0 + (0.045 + u.mid * 0.04) * sin(ang * (3.0 + float(n % 4)) + age * 1.4);
                float env = exp(-age * (kind > 2.5 ? 0.55 : 0.78)) * (0.45 + ev.z * 0.65);

                float crest1 = exp(-abs(dist - rad1 * wobble) * 155.0);
                float crest2 = exp(-abs(dist - rad2 * wobble) * 115.0) * 0.48 * smoothstep(0.18, 0.65, age);
                float fill = exp(-(dist * dist) / max(0.0008, rad1 * rad1 * 0.32)) * 0.14 * exp(-age * 1.6);

                float3 cc = colonyColor((n + int(kind)) % 5);
                col += cc * (crest1 * 0.72 + crest2 * 0.42 + fill) * env;
            }
        } else {
            // Calm resting courtyard pond rings when paused/standby
            for (int i = 0; i < 4; i++) {
                float2 c = colonyAttractor(i, u.time);
                float2 d = minDimCoord(p, c, boxAspect);
                float ang = atan2(d.y, d.x);
                float wobble = 1.0 + 0.08 * sin(ang * 3.0 + u.time * 0.45 + float(i));
                float rad = (0.095 + 0.018 * sin(u.time * 0.35 + float(i) * 1.7)) * wobble;
                float dist = length(d);
                float fill = smoothstep(rad, rad * 0.25, dist);
                float rim  = exp(-abs(dist - rad) * 145.0);
                float3 cc = colonyColor(i);
                col += cc * fill * 0.08 + cc * rim * 0.42;
            }
        }
    }

    float peak = max(col.r, max(col.g, col.b));
    float edrMask = smoothstep(0.28, 0.85, peak) * 0.55;
    return finalizeDisplayColor(col, edrMask, 0.0055, in.position.xy, u, blueNoiseTex);
}

vertex SpikeVertOut ecologyAgentVertex(uint vid [[vertex_id]],
                                       constant AcousticUniforms& u [[buffer(0)]]) {
    int slot = int(vid % 12);
    int band = int(vid % 24);
    float bv = getBand(u, band);
    float fi = float(vid);

    float screenAspect = u.resolution.x / max(1.0, u.resolution.y);
    bool isPortrait = screenAspect < 0.95;

    float2 minB = isPortrait ? float2(0.02, 0.12) : ((u.isCompact > 0.5) ? float2(0.02, 0.02) : float2(0.27, 0.065));
    float2 maxB = isPortrait ? float2(0.98, 0.76) : ((u.isCompact > 0.5) ? float2(0.98, 0.98) : float2(0.74, 0.935));
    float2 boxPx = (maxB - minB) * u.resolution;
    float boxAspect = max(0.35, boxPx.x / max(1.0, boxPx.y));

    float baseAngle = fract(fi * 0.6180339) * 6.2831853;
    float2 origin;
    float rad;
    float alpha;
    int colorIdx;

    if (u.isPlaying > 0.5) {
        float4 ev = u.noteA[slot];
        float age = ev.w;
        float kind = getNoteKind(u, slot);
        if (age < 5.8 && ev.z > 0.01) {
            origin = float2(clamp(0.5 + ev.y * 0.34, 0.14, 0.86), clamp(0.80 - ev.x * 0.58, 0.16, 0.84));
            float speed = (kind > 1.5 && kind < 2.5) ? 0.115 : 0.078;
            float ringR = 0.018 + age * speed;
            // Cluster stippled droplets right on the expanding cymatic crest + faint interior mist
            float radialJitter = (vid % 5 == 0) ? (0.4 + 0.6 * fract(fi * 0.7548776)) : (0.94 + 0.12 * fract(fi * 0.381966));
            rad = ringR * radialJitter;
            float env = exp(-age * 0.75) * (0.45 + ev.z * 0.65);
            alpha = clamp(env * (0.55 + bv * 0.45), 0.0, 0.96);
            colorIdx = (slot + int(kind)) % 5;
        } else {
            // Subtle quiet rain-mist flecks waiting for the next bowl strike
            origin = float2(fract(fi * 0.381966), fract(fi * 0.7548776));
            rad = 0.005;
            alpha = 0.04 + u.energy * 0.06;
            colorIdx = 4;
        }
    } else {
        int cluster = int(vid % 4);
        origin = colonyAttractor(cluster, u.time);
        float radialSeed = pow(fract(fi * 0.7548776), 0.62);
        rad = radialSeed * 0.105;
        alpha = 0.32;
        colorIdx = cluster;
    }

    float ang = baseAngle + u.time * 0.16 * ((vid % 2 == 0) ? 1.0 : -1.0);
    float2 offset = (boxAspect >= 1.0)
        ? float2(cos(ang) * rad / boxAspect, sin(ang) * rad)
        : float2(cos(ang) * rad, sin(ang) * rad * boxAspect);
    float2 p = clamp(origin + offset, 0.02, 0.98);

    float2 uv = mix(minB, maxB, p);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    float3 cc = colonyColor(colorIdx);
    SpikeVertOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.pointSize = (1.8 + bv * 2.2 + fract(fi * 0.13) * 1.2) * (u.isCompact > 0.5 ? 0.85 : 1.0);
    out.color = float4(additiveColorToTarget(cc, alpha, clamp(alpha * 0.55, 0.0, 0.55), u), alpha);
    return out;
}

// ============================================================================
// PRESET 03: PHOSPHOR SCOPE — TRIGGER-LOCKED GPU RGBA16F CRT LISSAJOUS
// ============================================================================
static inline float2 phosphorSamplePoint(constant float2* waveLR, int idx, float scale, float time, float idleMix) {
    float2 live = waveLR[idx] * scale;
    if (idleMix <= 0.001) return live;
    float ph = float(idx) * (6.2831853 / 256.0);
    float2 idle = float2(sin(ph * 2.0 + time * 0.65) * 0.26, sin(ph * 3.0 - time * 0.42) * 0.19);
    return mix(live, idle, idleMix);
}

fragment float4 phosphorUpdateFragment(FullscreenOut in [[stage_in]],
                                       texture2d<float> prevTex [[texture(0)]],
                                       constant AcousticUniforms& u [[buffer(0)]],
                                       constant float2* waveLR [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 prev = prevTex.sample(s, in.uv).rgb;

    // Frame-rate independent exponential phosphor persistence decay
    float decay = pow(0.00018, clamp(u.dt, 0.004, 0.05));
    float3 col = prev * clamp(decay, 0.72, 0.91);

    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.5);
    float2 p = minDimCoord(in.uv, center, aspect);

    // P31 Emerald daytime phosphor; shifts gracefully toward low-melanopic P39 Amber after 8 PM
    float nightAmber = max(u.amberMode, clamp(u.breathDepth.z, 0.0, 1.0) * 0.88);
    float3 beamCol = mix(
        float3(0.24, 1.00, 0.56),  // P31 Emerald Phosphor
        float3(1.00, 0.60, 0.16),  // P39 Warm Amber
        nightAmber
    );

    // Crisp CRT electron-beam intensity surge on fresh note plucks & sub beats
    float notePulse = 0.0;
    if (u.isPlaying > 0.5) {
        for (int n = 0; n < 12; n++) {
            float age = u.noteA[n].w;
            if (age < 0.45 && u.noteA[n].z > 0.01) {
                notePulse = max(notePulse, exp(-age * 7.5) * u.noteA[n].z);
            }
        }
    }

    float scale = 0.42 * (1.0 + u.beat * 0.08 + notePulse * 0.06);
    float minDist = 10.0;
    float accum = 0.0;
    float haloAccum = 0.0;

    float idleMix = smoothstep(0.03, 0.005, u.energy);

    // Full 255-segment stride-1 beam + min-distance continuous core eliminates vertex knot beading
    float2 a = phosphorSamplePoint(waveLR, 0, scale, u.time, idleMix);
    for (int i = 1; i < 256; i++) {
        float2 b = phosphorSamplePoint(waveLR, i, scale, u.time, idleMix);
        float d = sdSegment(p, a, b);
        minDist = min(minDist, d);
        float vel = length(b - a);
        float dwell = clamp(0.011 / (vel + 0.010), 0.25, 1.35);
        accum += exp(-d * 300.0) * dwell * 0.45;
        haloAccum += exp(-d * 68.0) * dwell * 0.055;
        a = b;
    }
    float silkyCore = exp(-minDist * 360.0) * 0.95;

    // Trigger-locked horizontal L-channel time-domain waveform
    float wIdx = clamp(in.uv.x * 255.0, 0.0, 254.0);
    int wi = int(wIdx);
    float wyLive = mix(waveLR[wi].x, waveLR[wi + 1].x, fract(wIdx)) * 0.30;
    float wyIdle = sin(in.uv.x * 12.56637 + u.time * 1.1) * 0.055 * sin(in.uv.x * 3.14159);
    float wy = mix(wyLive, wyIdle, idleMix);
    float wDist = abs(p.y - wy);
    float trace = exp(-wDist * 230.0) * mix(0.32 + notePulse * 0.18, 0.20, idleMix);

    float3 coreHot = mix(beamCol, float3(0.98, 0.99, 0.95), 0.72);
    float idleDim = mix(1.0 + notePulse * 0.22, 0.48, idleMix);
    col += (coreHot * (silkyCore + min(accum, 1.4) * 0.32) * 0.58 + beamCol * min(haloAccum, 1.2) * 0.26) * idleDim + beamCol * trace;

    return float4(min(col, 4.0), 1.0);
}

fragment float4 phosphorDisplayFragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> scopeTex [[texture(0)]],
                                        texture2d<float> blueNoiseTex [[texture(1)]],
                                        constant AcousticUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 beam = scopeTex.sample(s, in.uv).rgb;

    float nightAmber = max(u.amberMode, clamp(u.breathDepth.z, 0.0, 1.0) * 0.88);
    float3 bg = mix(float3(0.014, 0.028, 0.019), float3(0.030, 0.020, 0.010), nightAmber);
    float3 grCol = mix(float3(0.36, 1.0, 0.60), float3(1.0, 0.68, 0.26), nightAmber);

    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.5);

    // Crisp calibration CRT graticule (square cells on both landscape and portrait screens)
    float2 gridUV = (aspect >= 1.0)
        ? (in.uv * float2(12.0, 8.0))
        : ((in.uv - center) * float2(8.0, 8.0 / max(0.35, aspect)) + 0.5);
    float2 gv = abs(fract(gridUV - 0.5) - 0.5) / max(float2(1e-4), fwidth(gridUV));
    float gridLine = 1.0 - min(min(gv.x, gv.y), 1.0);

    float2 axis = abs(in.uv - center) * u.resolution;
    float centerAxis = max(smoothstep(1.3, 0.0, axis.x), smoothstep(1.3, 0.0, axis.y));

    float3 col = bg + grCol * (gridLine * 0.055 + centerAxis * 0.14) + beam;

    // Gentle CRT glass vignette + filmic curve + EDR phosphor core bloom
    float vig = smoothstep(1.3, 0.25, length((in.uv - center) * 1.45));
    col *= mix(0.75, 1.0, vig);
    float beamPeak = max(beam.r, max(beam.g, beam.b));
    col = col / (1.0 + col * 0.35);
    float edrMask = smoothstep(0.42, 1.65, beamPeak) * 0.92;
    return finalizeDisplayColor(col, edrMask, 0.0055, in.position.xy, u, blueNoiseTex);
}

static inline float3 nocturnePalette(float t) {
    // Deep nocturnal Satie palette: midnight indigo -> moonlit silver-blue -> warm candlelight amber -> velvet slate
    float p = fract(t);
    float3 c0 = float3(0.14, 0.20, 0.38); // Midnight indigo
    float3 c1 = float3(0.46, 0.56, 0.74); // Moonlit silver-slate
    float3 c2 = float3(0.82, 0.60, 0.36); // Warm candlelight amber / cello rosin
    float3 c3 = float3(0.32, 0.24, 0.42); // Quiet twilight plum
    if (p < 0.25) return mix(c0, c1, smoothstep(0.0, 1.0, p * 4.0));
    if (p < 0.50) return mix(c1, c2, smoothstep(0.0, 1.0, (p - 0.25) * 4.0));
    if (p < 0.75) return mix(c2, c3, smoothstep(0.0, 1.0, (p - 0.50) * 4.0));
    return mix(c3, c0, smoothstep(0.0, 1.0, (p - 0.75) * 4.0));
}

// ============================================================================
// PRESET 04: NOCTURNE — CANDLELIT SUMI-E INK RINGS & MOONLIT WATER REFLECTION
// ============================================================================
fragment float4 liquidUpdateFragment(FullscreenOut in [[stage_in]],
                                     texture2d<float> prevTex [[texture(0)]],
                                     constant AcousticUniforms& u [[buffer(0)]],
                                     constant float2* waveLR [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.5);
    float2 p = minDimCoord(in.uv, center, aspect);
    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);

    // Multi-scale curl smoke/ink advection (delicate rising lantern wisps, zero mushy zoom blur)
    float eps = 0.015;
    float psi0 = gradNoise(p * 3.1 + float2(u.time * 0.045, -u.time * 0.032))
               + 0.45 * gradNoise(p * 6.8 - float2(u.time * 0.03, u.time * 0.04) + 3.1);
    float psiX = gradNoise((p + float2(eps, 0.0)) * 3.1 + float2(u.time * 0.045, -u.time * 0.032))
               + 0.45 * gradNoise((p + float2(eps, 0.0)) * 6.8 - float2(u.time * 0.03, u.time * 0.04) + 3.1);
    float psiY = gradNoise((p + float2(0.0, eps)) * 3.1 + float2(u.time * 0.045, -u.time * 0.032))
               + 0.45 * gradNoise((p + float2(0.0, eps)) * 6.8 - float2(u.time * 0.03, u.time * 0.04) + 3.1);
    // Divergence-free curl velocity (preserves crisp delicate ink filaments across 5+ seconds!)
    float2 curl = float2(psiY - psi0, -(psiX - psi0)) / eps;
    float2 vel = curl * 0.00055 + float2(0.0, 0.00075);
    float2 advUV = in.uv + ((aspect >= 1.0) ? float2(vel.x / aspect, vel.y) : float2(vel.x, vel.y * aspect));

    float3 prev = prevTex.sample(s, advUV).rgb;
    float decay = pow(0.32, clamp(u.dt, 0.004, 0.05));
    prev *= clamp(decay, 0.93, 0.988);

    float3 inject = float3(0.0);

    if (u.isPlaying > 0.5) {
        // Each struck nocturnal piano / cello / glass note paints a crisp gilded ink-wash halo + hairline echo
        for (int n = 0; n < 12; n++) {
            float4 ev = u.noteA[n];
            float age = ev.w;
            if (age > 2.4 || ev.z <= 0.01) continue;
            float kind = getNoteKind(u, n);
            float env = smoothstep(0.0, 0.045, age) * exp(-age * 2.15) * ev.z;
            float2 nPos = float2(ev.y * 0.32, (0.48 - ev.x) * 0.28);
            float2 dp = p - nPos;
            float nd = length(dp);
            float ang = atan2(dp.y, dp.x);

            // Delicate brush-ink ring radius expanding gracefully with harmonic azimuth ripple
            float rBase = (kind > 2.5) ? 0.065 : ((kind > 0.5 && kind < 1.5) ? 0.042 : 0.032);
            float rExp = rBase + age * 0.058;
            float brushWobble = 1.0 + 0.06 * sin(ang * (2.0 + float(n % 3)) + age * 1.1 + psi0 * 2.5);
            float ringMain = exp(-abs(nd - rExp * brushWobble) * 145.0);
            float ringEcho = exp(-abs(nd - max(0.01, rExp - 0.024) * brushWobble) * 95.0) * 0.42;
            float emberCore = exp(-(nd * nd) / max(0.00025, rBase * rBase * 0.16)) * exp(-age * 4.5) * 0.45;

            float3 nCol;
            if (kind > 2.5) {
                nCol = mix(float3(0.30, 0.44, 0.72), float3(0.56, 0.32, 0.18), isNight * 0.72); // Cello midnight indigo
            } else if (kind > 1.5) {
                nCol = mix(float3(0.84, 0.88, 0.96), float3(0.95, 0.76, 0.50), isNight * 0.75); // Glass moon-pearl
            } else if (kind > 0.5) {
                nCol = float3(0.98, 0.70, 0.34); // Felt-piano warm candlelight gold
            } else {
                nCol = mix(nocturnePalette(ev.x * 0.55 + u.time * 0.02), float3(0.88, 0.52, 0.24), isNight * 0.65);
            }
            inject += nCol * (ringMain * 0.88 + ringEcho * 0.48 + emberCore) * env;
        }
    } else {
        // Serene moonlit sumi-ink halo at rest
        float r = length(p);
        float ang = atan2(p.y, p.x);
        float ringR = 0.16 + 0.008 * sin(ang * 3.0 + u.time * 0.35);
        float ring = exp(-abs(r - ringR) * 115.0);
        float3 col2 = mix(float3(0.88, 0.66, 0.38), float3(0.84, 0.50, 0.22), isNight);
        inject += col2 * ring * 0.26;
    }

    // Subtle cello/bass breath whisper (used only to breathe luminance softly, zero cartoon waveform bar!)
    float subEnergy = abs(waveLR[0].x + waveLR[64].y) * 0.05;
    float3 outCol = prev + inject * (0.36 + subEnergy);
    float vig = smoothstep(1.25, 0.20, length((in.uv - center) * 1.38));
    outCol *= mix(0.80, 1.0, vig);

    return float4(clamp(outCol, 0.0, 2.2), 1.0);
}

fragment float4 liquidDisplayFragment(FullscreenOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]],
                                      texture2d<float> blueNoiseTex [[texture(1)]],
                                      constant AcousticUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.5);
    float2 p = minDimCoord(in.uv, center, aspect);
    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);

    float3 raw = tex.sample(s, in.uv).rgb;

    // Soft moonlit water reflection along the lower third (mirrors the upper candlelight rings subtly)
    float waterMask = smoothstep(0.08, 0.36, p.y);
    float rippleX = gradNoise(float2(p.x * 16.0 + u.time * 0.25, p.y * 42.0 - u.time * 0.18)) * 0.008;
    float2 reflUV = float2(clamp(in.uv.x + rippleX, 0.0, 1.0), clamp(1.0 - in.uv.y * 0.85, 0.0, 1.0));
    float3 refl = tex.sample(s, reflUV).rgb * waterMask * 0.26;
    raw += refl;

    // Subtle ambient candlelit room paper grain + deep velvet obsidian midnight wash
    float paper = gradNoise(in.uv * 48.0) * 0.004;
    float3 bgObsidian = mix(float3(0.015, 0.020, 0.036), float3(0.022, 0.013, 0.010), isNight * 0.80);
    float3 glowTint = mix(float3(0.14, 0.18, 0.32), float3(0.24, 0.12, 0.06), isNight * 0.82);
    float radGlow = exp(-dot(p, p) * 2.8) * (0.09 + 0.08 * u.energy);

    float rawPeak = max(raw.r, max(raw.g, raw.b));
    float3 c = (raw * (2.51 * raw + 0.03)) / (raw * (2.43 * raw + 0.59) + 0.14);
    c = pow(max(c, 0.0), float3(0.95));
    c = bgObsidian + glowTint * radGlow + c + paper;

    float edrMask = smoothstep(0.36, 1.25, rawPeak) * 0.72;
    return finalizeDisplayColor(c, edrMask, 0.0060, in.position.xy, u, blueNoiseTex);
}

// ============================================================================
// PRESET 05: HORIZON — DRONE-COUPLED TURRELL LIGHT PLANE & WATER STANDING WAVE
// ============================================================================
fragment float4 horizonFragment(FullscreenOut in [[stage_in]],
                                constant AcousticUniforms& u [[buffer(0)]],
                                constant float2* waveLR [[buffer(1)]],
                                texture2d<float> blueNoiseTex [[texture(1)]]) {
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.50);
    float2 p = minDimCoord(in.uv, center, aspect);

    // Deep obsidian zenith fading subtly into still slate water below (warm ember-obsidian after 8 PM)
    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);
    float3 zenith = mix(float3(0.018, 0.024, 0.038), float3(0.024, 0.014, 0.012), isNight * 0.80);
    float3 nadir  = mix(float3(0.011, 0.015, 0.024), float3(0.014, 0.009, 0.008), isNight * 0.80);
    float3 col = mix(zenith, nadir, smoothstep(-0.35, 0.45, p.y));

    float t = u.time * (0.35 + u.isPlaying * 0.45);
    float mist1 = gradNoise(float2(p.x * 2.2 + t * 0.055, p.y * 4.5 - t * 0.028));
    float mist2 = gradNoise(float2(p.x * 4.6 - t * 0.038, p.y * 8.0 + t * 0.020) + 4.3);
    float mist = mist1 * 0.65 + mist2 * 0.35;

    // When playing, 100% of the light breathing comes from real audio energy + harmonic chord shifts (no fake sine clock)
    float idleBreath = 0.5 + 0.5 * sin(u.time * 0.35);
    float acousticBreath = mix(idleBreath * 0.25, clamp(u.energy * 1.35 + u.bass * 0.45, 0.0, 1.4), u.isPlaying);
    float chordWarm = (u.isPlaying > 0.5) ? exp(-max(0.0, u.chordAge) * 0.65) : 0.0;

    float spread = 0.12 + acousticBreath * 0.11;
    float yShift = p.y - mist * (0.018 + u.mid * 0.022);

    // Wide horizontal Rothko twilight bloom
    float xMask = exp(-(p.x * p.x) / (0.58 + acousticBreath * 0.30));
    float bandWide = exp(-(yShift * yShift) / (spread * spread * 2.2)) * (0.52 + 0.48 * xMask);
    float bandCore = exp(-(yShift * yShift) / (spread * spread * 0.16)) * xMask;

    // Luminous dome kissing the horizon (echoing the STILL glyph)
    float2 domeP = float2(p.x, p.y + 0.012);
    float domeDist = length(domeP);
    float domeRadius = 0.110 + u.bass * 0.042 + acousticBreath * 0.014;
    float aboveHorizon = smoothstep(0.012, -0.018, p.y);
    float domeGlow = exp(-(domeDist * domeDist) / (domeRadius * domeRadius * 1.15)) * aboveHorizon;
    float domeRim = exp(-abs(domeDist - domeRadius) * 88.0) * aboveHorizon * (0.36 + acousticBreath * 0.34);

    // Perspective-foreshortened moonlit sea reflection (Sugimoto / Rothko physics — zero synthetic zebra bars)
    float wIdx = clamp(in.uv.x * 255.0, 0.0, 254.0);
    int wi = int(wIdx);
    float droneWave = mix(waveLR[wi].x + waveLR[wi].y, waveLR[wi + 1].x + waveLR[wi + 1].y, fract(wIdx)) * 0.5;
    float belowHorizon = smoothstep(-0.004, 0.018, p.y);
    float pyPos = max(0.001, p.y);
    float zDepth = 0.070 / (pyPos + 0.024); // true perspective foreshortening toward horizon
    float wN1 = gradNoise(float2(p.x * 9.5 + mist1 * 1.4 + t * 0.14, zDepth * 3.4 - t * 0.28));
    float wN2 = gradNoise(float2(p.x * 21.0 - t * 0.18, zDepth * 6.8 + t * 0.22 + droneWave * 2.2));
    float causticGlint = pow(clamp(0.5 + 0.5 * (wN1 * 0.62 + wN2 * 0.38), 0.0, 1.0), 2.8);
    float waterSpreadX = 0.055 + pyPos * 0.55 + acousticBreath * 0.035;
    float refl = exp(-pyPos * 5.2) * exp(-(p.x * p.x) / max(0.01, waterSpreadX * waterSpreadX * 3.2))
               * belowHorizon * (0.18 + 0.92 * causticGlint);

    // Hairline silver-pearl horizon filament subtly modulated by stereo waveform
    float lineY = p.y - droneWave * (u.isPlaying > 0.5 ? 0.007 : 0.0);
    float horizonLine = exp(-abs(lineY) * 280.0) * (0.28 + 0.50 * xMask);

    // Architectural dawn-silver palette; shifts warmly toward twilight amber-parchment on chords & after 8 PM
    float3 mistDay = mix(float3(0.28, 0.36, 0.50), float3(0.48, 0.42, 0.38), chordWarm * 0.48);
    float3 warmDay = mix(float3(0.76, 0.80, 0.88), float3(0.95, 0.84, 0.72), chordWarm * 0.55);
    float3 lineDay = float3(0.94, 0.96, 1.00);

    float3 mistCol = mix(mistDay, float3(0.42, 0.22, 0.14), isNight * 0.80);
    float3 warmCol = mix(warmDay, float3(0.86, 0.52, 0.26), isNight * 0.82);
    float3 lineCol = mix(lineDay, float3(0.96, 0.74, 0.46), isNight * 0.82);

    col += mistCol * bandWide * (0.24 + acousticBreath * 0.26 + mist * 0.05);
    col += warmCol * bandCore * (0.20 + u.mid * 0.24 + chordWarm * 0.10);
    col += warmCol * domeGlow * (0.22 + acousticBreath * 0.26) + lineCol * domeRim * (0.42 + u.mid * 0.32);
    col += warmCol * refl * (0.20 + u.bass * 0.24);
    col += lineCol * horizonLine * (0.44 + u.treble * 0.28 + chordWarm * 0.12);

    // Spatiotemporal 64x64 blue-noise dither + localized EDR lift on horizon filament and dome rim
    float edrMask = clamp(horizonLine * 0.72 + domeRim * 0.55 + bandCore * 0.18, 0.0, 0.85);
    return finalizeDisplayColor(col, edrMask, 0.0065, in.position.xy, u, blueNoiseTex);
}

// ============================================================================
// PRESET 06: OCULUS — JAMES TURRELL ATEN REIGN / SKYSPACE + BOWL CAUSTICS
// ============================================================================
// Four recessed architectural plaster tiers bathed in indirect cove light,
// coupled directly to Deep Dive's live 8.5 -> 5.5 bpm respiratory pacer and
// 20-minute physiological descent (Warm Aten Reign Dusk -> Guggenheim Twilight
// -> Nocturnal Skyspace Cerulean). Struck bronze bowls project translucent
// Faraday water-caustic ripples across the plaster domes before returning to
// motionless contemplative stillness during Ma silence.

static inline float3 turrellMix3(float3 a, float3 b, float3 c, float t) {
    float u = clamp(t, 0.0, 1.0);
    if (u < 0.5) {
        return mix(a, b, smoothstep(0.0, 0.5, u));
    }
    return mix(b, c, smoothstep(0.5, 1.0, u));
}

fragment float4 oculusFragment(FullscreenOut in [[stage_in]],
                               constant AcousticUniforms& u [[buffer(0)]],
                               device const float* wave [[buffer(1)]],
                               texture2d<float> blueNoiseTex [[texture(1)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float playing = u.isPlaying;
    float isDeep = u.breathDepth.w;

    // Live physiological breath (exact ResonanceBreathPacer in Deep Dive; soft acoustic breath on other modes)
    float breath01 = (playing > 0.5)
        ? ((isDeep > 0.5)
            ? u.breathDepth.x
            : clamp(0.45 + 0.35 * sin(u.time * 0.57) + 0.20 * u.bass, 0.0, 1.0))
        : 0.42;

    // Live physiological depth arc (0 = Arrival warm dusk -> 0.5 = Twilight -> 1.0 = Deep Skyspace)
    // In Standby (paused), rests quietly at serene nocturnal twilight (0.72) with soft low luminance.
    float depth01 = (playing > 0.5)
        ? ((isDeep > 0.5)
            ? u.breathDepth.y
            : (0.28 + 0.44 * (0.5 + 0.5 * sin(u.time * 0.018))))
        : 0.72;

    // Frame-aware architectural centering (all 4 concentric tiers fit gracefully in Popover, Studio, iPhone & iPad)
    float centerY = (u.isCompact > 0.5) ? 0.50 : ((aspect < 1.0) ? 0.45 : 0.505);
    float2 p = uv - float2(0.5, centerY);
    if (aspect >= 1.0) {
        p.x *= aspect;
        p.x *= (u.isCompact > 0.5) ? 0.76 : 0.80;
        if (u.isCompact > 0.5) p *= 1.18; // Frame all 4 recessed chambers cleanly in compact popover card
    } else {
        p.y /= aspect;
        p.y *= 0.72; // Tall cathedral oculus on portrait iPhone
        p *= 0.96;
    }

    // Imperceptible respiratory dilation (+3.0% on inhale, deep warm settle on exhale)
    float breathScale = 1.0 + playing * (breath01 - 0.5) * 0.058;
    float2 bp = p / breathScale;

    // Subtle Guggenheim off-axis vertical parallax between deeper recessed architectural tiers
    float par = (u.isCompact > 0.5) ? 0.005 : 0.0085;
    float2 p1 = bp;
    float2 p2 = bp + float2(0.0, -par);
    float2 p3 = bp + float2(0.0, -par * 2.0);
    float2 p4 = bp + float2(0.0, -par * 2.8);

    float r1 = length(p1);
    float r2 = length(p2);
    float r3 = length(p3);
    float r4 = length(p4);

    // 3-Keyframe Perceptually Curated Turrell Ganzfeld Trajectory (zero muddy midpoint!)
    // Daytime arc: Aten Reign Warm Dusk -> Guggenheim Velvet Twilight -> Nocturnal Skyspace Cerulean
    float3 oA = float3(0.028, 0.032, 0.082);
    float3 t1A = float3(0.110, 0.082, 0.242);
    float3 t2A = float3(0.360, 0.136, 0.312);
    float3 t3A = float3(0.735, 0.298, 0.280);
    float3 skA = float3(0.955, 0.720, 0.495);

    float3 oM = float3(0.020, 0.028, 0.072);
    float3 t1M = float3(0.068, 0.088, 0.235);
    float3 t2M = float3(0.185, 0.145, 0.365);
    float3 t3M = float3(0.395, 0.255, 0.455);
    float3 skM = float3(0.785, 0.675, 0.775);

    float3 oD = float3(0.013, 0.022, 0.056);
    float3 t1D = float3(0.036, 0.086, 0.198);
    float3 t2D = float3(0.074, 0.195, 0.340);
    float3 t3D = float3(0.145, 0.375, 0.470);
    float3 skD = float3(0.635, 0.805, 0.875);

    float3 cOuterDay = turrellMix3(oA,  oM,  oD,  depth01);
    float3 cTier1Day = turrellMix3(t1A, t1M, t1D, depth01);
    float3 cTier2Day = turrellMix3(t2A, t2M, t2D, depth01);
    float3 cTier3Day = turrellMix3(t3A, t3M, t3D, depth01);
    float3 cSkyDay   = turrellMix3(skA, skM, skD, depth01);

    // Nocturnal Low-Melanopic Ember Arc (20:00-05:59): strips 460-490 nm ipRGC blue/cyan spike
    // to protect evening melatonin (< 10 melanopic EDI) while preserving deep Turrell warmth
    float3 noA = float3(0.026, 0.014, 0.010);
    float3 nt1A = float3(0.105, 0.036, 0.022);
    float3 nt2A = float3(0.285, 0.088, 0.044);
    float3 nt3A = float3(0.560, 0.205, 0.078);
    float3 nskA = float3(0.840, 0.495, 0.185);

    float3 noM = float3(0.020, 0.010, 0.008);
    float3 nt1M = float3(0.078, 0.024, 0.016);
    float3 nt2M = float3(0.205, 0.058, 0.032);
    float3 nt3M = float3(0.415, 0.140, 0.056);
    float3 nskM = float3(0.680, 0.365, 0.125);

    float3 noD = float3(0.014, 0.008, 0.005);
    float3 nt1D = float3(0.048, 0.017, 0.010);
    float3 nt2D = float3(0.125, 0.038, 0.018);
    float3 nt3D = float3(0.265, 0.095, 0.036);
    float3 nskD = float3(0.485, 0.255, 0.082);

    float isNight = clamp(u.breathDepth.z, 0.0, 1.0);
    float3 cOuter = mix(cOuterDay, turrellMix3(noA,  noM,  noD,  depth01), isNight);
    float3 cTier1 = mix(cTier1Day, turrellMix3(nt1A, nt1M, nt1D, depth01), isNight);
    float3 cTier2 = mix(cTier2Day, turrellMix3(nt2A, nt2M, nt2D, depth01), isNight);
    float3 cTier3 = mix(cTier3Day, turrellMix3(nt3A, nt3M, nt3D, depth01), isNight);
    float3 cSky   = mix(cSkyDay,   turrellMix3(nskA, nskM, nskD, depth01), isNight);

    // Tier radii spanning cleanly across the viewport
    float R1 = 0.64;
    float R2 = 0.47;
    float R3 = 0.32;
    float R4 = 0.19;

    // Subtle matte architectural plaster micro-grain (makes flat OLED light feel physical & tactile)
    float grainFine = gradNoise(uv * 54.0) * 0.0042 + gradNoise(uv * 17.0) * 0.0036;

    // Outer room architectural ceiling cove
    float gOut = clamp(1.0 - max(0.0, r1 - R1) * 1.20, 0.0, 1.0);
    float3 col = cOuter * (0.44 + 0.60 * pow(gOut, 1.40))
               + cTier1 * exp(-max(0.0, r1 - R1) * 6.8) * (0.30 + 0.09 * breath01);

    // Tier 1 (crisp architectural bevel at R1, recessed inner shadow, indirect light spilling from R2)
    float m1 = 1.0 - smoothstep(R1 - 0.0065, R1 + 0.0085, r1);
    float shadow1 = smoothstep(R1, R1 - 0.055, r1);
    float cove1 = pow(clamp((R1 - r1) / (R1 - R2), 0.0, 1.0), 1.45);
    float3 t1 = mix(cOuter * 0.82, cTier1, 0.34 + 0.66 * shadow1) * (0.70 + 0.38 * cove1)
              + cTier2 * pow(cove1, 2.5) * 0.28;
    float edge1 = exp(-pow((r1 - R1) / 0.0048, 2.0)) * 0.13;
    col = mix(col, t1, m1) + mix(cTier1, cTier2, 0.5) * edge1;

    // Tier 2 (crisp recessed step at R2, richer cove glow from R3)
    float m2 = 1.0 - smoothstep(R2 - 0.0058, R2 + 0.0075, r2);
    float shadow2 = smoothstep(R2, R2 - 0.048, r2);
    float cove2 = pow(clamp((R2 - r2) / (R2 - R3), 0.0, 1.0), 1.40);
    float3 t2 = mix(cTier1 * 0.82, cTier2, 0.34 + 0.66 * shadow2) * (0.74 + 0.34 * cove2)
              + cTier3 * pow(cove2, 2.4) * 0.32;
    float edge2 = exp(-pow((r2 - R2) / 0.0044, 2.0)) * 0.15;
    col = mix(col, t2, m2) + mix(cTier2, cTier3, 0.5) * edge2;

    // Tier 3 (crisp recessed step at R3, warm luminous cove glow framing the central oculus)
    float m3 = 1.0 - smoothstep(R3 - 0.0052, R3 + 0.0068, r3);
    float shadow3 = smoothstep(R3, R3 - 0.040, r3);
    float cove3 = pow(clamp((R3 - r3) / (R3 - R4), 0.0, 1.0), 1.35);
    float3 t3 = mix(cTier2 * 0.82, cTier3, 0.36 + 0.64 * shadow3) * (0.78 + 0.32 * cove3)
              + cSky * pow(cove3, 2.2) * 0.36;
    float edge3 = exp(-pow((r3 - R3) / 0.0038, 2.0)) * 0.17;
    col = mix(col, t3, m3) + mix(cTier3, cSky, 0.5) * edge3;

    // Central Skyspace Oculus (infinite atmospheric dusk aperture breathing in exact lockstep with audio)
    float m4 = 1.0 - smoothstep(R4 - 0.0042, R4 + 0.0058, r4);
    float skyGrad = clamp(0.5 - p4.y * 1.65, 0.0, 1.0);
    // Whisper-soft living sky atmosphere (high-altitude rain veil drifting imperceptibly across the skylight)
    float skyVeil = gradNoise(p4 * 5.2 + float2(u.time * 0.016, -u.time * 0.011)) * (0.030 + 0.025 * u.treble);
    int wIdx = clamp(int(fract(uv.x) * 511.0), 0, 511);
    float airShimmer = playing * wave[wIdx] * 0.012 * (0.4 + 0.6 * u.energy);

    float3 skyCol = mix(cSky * 0.87, cSky * 1.08 + float3(0.05, 0.04, 0.03), skyGrad + skyVeil)
                  * (0.86 + 0.20 * breath01 + airShimmer);
    float skyRim = smoothstep(R4, R4 - 0.024, r4);
    skyCol = mix(cTier3 * 0.90, skyCol, 0.54 + 0.46 * skyRim);
    float edge4 = exp(-pow((r4 - R4) / 0.0034, 2.0)) * 0.19;
    col = mix(col, skyCol, m4) + cSky * edge4;

    // Live Multi-Bowl Faraday Water-Caustic Resonance (100% silence-respectful during Ma gaps!)
    float causticEdr = 0.0;
    if (playing > 0.5) {
        float causticAccum = 0.0;
        float ringAccum = 0.0;
        for (int n = 0; n < 12; n++) {
            float4 na = u.noteA[n]; // (pitchNorm, pan, velocity, ageSec)
            float age = na.w;
            if (age > 0.001 && age < 14.5) {
                float vel = na.z;
                float env = exp(-age * 0.30) * smoothstep(0.0, 0.18, age) * vel;
                float2 bc = p4 - float2(na.y * 0.042, (na.x - 0.5) * 0.024);
                float rb = length(bc);
                float ab = atan2(bc.y, bc.x);

                // Pitch-locked angular Faraday eigenmode (m=3 deep temple bowls -> m=7 high Zen rin bells)
                float mA = floor(3.0 + na.x * 3.0);
                float mB = mA + 2.0;
                float precess = u.time * (0.36 + 0.18 * na.x) * (na.y >= 0.0 ? 1.0 : -1.0);

                float front = 0.03 + age * 0.095;
                float band = exp(-pow((rb - front) / 0.115, 2.0)) * exp(-rb * 1.65);
                float wA = cos(rb * 40.0 - age * 2.4) * cos(ab * mA + precess);
                float wB = cos(rb * 45.0 - age * 2.1 + 0.85) * cos(ab * mB - precess * 0.72);
                float web = pow(max(0.0, 0.5 + 0.5 * (0.58 * wA + 0.42 * wB)), 5.2);
                float softHalo = exp(-pow((rb - front) / 0.022, 2.0)) * smoothstep(0.01, 0.07, rb);

                causticAccum += web * band * env;
                ringAccum += softHalo * env;
            }
        }
        if (causticAccum > 0.0005 || ringAccum > 0.0005) {
            float3 lightTint = mix(cSky * 1.18, float3(1.0, 0.97, 0.92), 0.52);
            float tierReach = 0.22 + 0.78 * m1;
            float cMix = min(1.0, causticAccum) * 0.26 + min(1.0, ringAccum) * 0.13;
            col += lightTint * cMix * tierReach;
            causticEdr = clamp(cMix * 2.2 * tierReach, 0.0, 0.65);
        }
    }

    // Gentle standby dim when paused so silence feels deeply restful
    col *= mix(0.62, 1.0, playing);

    // Subtle edge obsidian darkening so white Braun top/bottom chrome always reads effortlessly
    float2 vig = uv - 0.5;
    float edgeDark = clamp(1.05 - dot(vig, vig) * 0.62, 0.38, 1.0);
    float dockContrast = 1.0 - 0.24 * smoothstep(0.76, 1.0, uv.y) - 0.14 * smoothstep(0.18, 0.0, uv.y);
    col = (col + grainFine) * edgeDark * dockContrast;

    // Filmic highlight rolloff + localized Apple EDR skylight aperture & Faraday caustic glow + 64x64 Blue Noise
    col = col / (1.0 + col * 0.22);
    float oculusEdr = clamp(m4 * (0.24 + 0.22 * breath01) * skyRim + edge4 * 0.95 + causticEdr, 0.0, 0.75) * playing;
    return finalizeDisplayColor(col, oculusEdr, 0.0062, in.position.xy, u, blueNoiseTex);
}
