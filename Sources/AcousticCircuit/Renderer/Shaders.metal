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
    float  _pad0;
    float  _pad1;
    float  _pad2;
    float4 bands[6];       // 24 log-spaced perceptual bands packed into 6 float4s (offset 80)
    float4 impulses[6];    // 24 per-band transient impulses
};

static inline float getBand(constant AcousticUniforms& u, int idx) {
    int i = clamp(idx, 0, 23);
    return u.bands[i / 4][i % 4];
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
// UTILITY: HASH, NOISE, SEGMENT DISTANCE, PALETTE
// ============================================================================
static inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

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

static inline float3 cosinePalette(float t) {
    float3 a = float3(0.55, 0.45, 0.66);
    float3 b = float3(0.45, 0.42, 0.46);
    float3 c = float3(1.00, 0.92, 0.84);
    float3 d = float3(0.08, 0.34, 0.64);
    return a + b * cos(6.2831853 * (c * t + d));
}

// ============================================================================
// PRESET 01: THE CIRCUIT — BACKGROUND + 160-RIBBON 3D CONNECTOME CORE + SPIKES
// ============================================================================
fragment float4 circuitBackgroundFragment(FullscreenOut in [[stage_in]],
                                          constant AcousticUniforms& u [[buffer(0)]]) {
    float2 aspect = float2(u.resolution.x / max(1.0, u.resolution.y), 1.0);
    float2 d = (in.uv - u.coreCenter) * aspect;
    float dist = length(d);

    // Midnight-slate Room C architectural gradient
    float3 inner = float3(0.086, 0.133, 0.212);
    float3 midC  = float3(0.043, 0.067, 0.110);
    float3 outer = float3(0.024, 0.039, 0.067);

    float3 col = mix(inner, midC, smoothstep(0.05, 0.48, dist));
    col = mix(col, outer, smoothstep(0.42, 0.95, dist));

    // Soft volumetric luminous halo breathing behind the 3D filament core
    float haloR = max(0.12, u.coreScale * 0.56);
    float halo = exp(-(dist * dist) / (haloR * haloR * (0.65 + u.beat * 0.22)));
    col += float3(0.24, 0.34, 0.52) * halo * (0.28 + u.energy * 0.38);
    col += float3(0.68, 0.78, 0.94) * exp(-(dist * dist) / (haloR * haloR * 0.18)) * (0.12 + u.beat * 0.18);

    // Subtle film dither so 10-bit / OLED dark slate never bands
    float grain = (hash12(in.position.xy + fract(u.time)) - 0.5) * 0.012;
    return float4(max(col + grain, 0.0), 1.0);
}

struct RibbonVertOut {
    float4 position [[position]];
    float4 color;
};

// 240 strands x 112 segments (non-periodic golden-ratio curl connectome volume)
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

    float t = u.time;
    float phaseA = strandNorm * 6.2831853;
    float phaseB = fract(fi * 0.6180339887) * 6.2831853;
    float phaseC = fract(fi * 0.7548776662) * 6.2831853;
    float freq1 = 1.0 + float(iid % 5) * 0.31;
    float freq2 = 2.0 + float(iid % 7) * 0.27;
    float tilt  = (float(iid % 11) - 5.0) * 0.19;

    // Three nested neural shells for genuine Room-C translucent depth
    float shell = (iid % 4 == 0) ? 0.46 : ((iid % 4 == 1) ? 0.72 : ((iid % 4 == 2) ? 0.90 : 1.06));
    float baseR = shell * (0.82 + 0.24 * fract(fi * 0.381966));
    float pulse = 1.0 + bv * 0.28 + u.beat * 0.08 + imp * 0.08;

    float angle = frac * 6.2831853;
    // Multi-frequency irrational drift so trajectories never visibly loop
    float wobble = 0.22 + 0.14 * sin(angle * freq2 + t * 0.58 + phaseB)
                        + 0.08 * cos(angle * 3.0 - t * 0.37 + phaseC)
                        + bv * 0.18;
    float theta = angle + phaseA + t * (0.11 + 0.05 * sin(phaseB + t * 0.07));
    float phi = angle * freq1 + phaseB - t * (0.21 + 0.06 * cos(phaseC));

    float rTube = baseR * pulse;
    float x = (rTube + wobble * cos(phi)) * cos(theta);
    float y = (rTube + wobble * cos(phi)) * sin(theta) * 0.88 + sin(phi * 1.5 + phaseC * 0.3) * 0.22;
    float z = wobble * sin(phi) + cos(theta * 2.0 + tilt) * 0.36;

    // 2D gradient curl-noise displacement driven by harmonic mid/treble texture
    float2 nCoord = float2(x * 1.4 + t * 0.14, y * 1.4 - t * 0.11);
    float cn1 = gradNoise(nCoord + phaseB * 0.1);
    float cn2 = gradNoise(nCoord.yx + phaseC * 0.1 + 3.7);
    float curlAmp = 0.14 + u.mid * 0.24 + u.treble * 0.14;
    x += cn1 * curlAmp;
    y += cn2 * curlAmp * 0.85;
    z += (cn1 - cn2) * curlAmp * 0.65;

    float rotY = t * 0.19 + u.bass * 0.26;
    float rotX = 0.38 + sin(t * 0.14) * 0.26 + cos(t * 0.09) * 0.08;
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

    float depthFade = clamp(0.42 + 0.58 * (z2 * 0.5 + 0.5), 0.16, 1.0);
    float baseAlpha = (iid % 9 == 0) ? 0.30 : ((iid % 3 == 0) ? 0.14 : 0.068);
    float alpha = clamp((baseAlpha + bv * 0.24 + imp * 0.22) * depthFade, 0.015, 0.72);

    float blueGlint = smoothstep(0.58, 0.94, bv) * ((iid % 5 == 0) ? 1.0 : 0.25);
    float3 col = mix(float3(0.93, 0.96, 1.00), float3(0.52, 0.76, 1.00), blueGlint);

    RibbonVertOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.color = float4(col * alpha, alpha);
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

    // Golden-angle Fibonacci sphere distribution with radial breathing
    float u1 = fract(fi * 0.6180339887);
    float u2 = fract(fi * 0.3819660113);
    float phi = acos(1.0 - 2.0 * u1);
    float theta = u2 * 6.2831853 + u.time * (0.12 + 0.42 * fract(fi * 0.1731)) * (0.55 + bv);

    float rad = (0.48 + 0.62 * fract(fi * 0.7548776)) * (0.86 + bv * 0.34 + u.beat * 0.12);
    float x = rad * sin(phi) * cos(theta);
    float y = rad * cos(phi) * 0.88;
    float z = rad * sin(phi) * sin(theta);

    float rotY = u.time * 0.22 + u.bass * 0.30;
    float rotX = 0.38 + sin(u.time * 0.18) * 0.24;
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
    float alpha = clamp((0.16 + bv * 0.62 + imp * 0.40) * (0.45 + 0.55 * (z2 * 0.5 + 0.5)), 0.05, 0.95);

    SpikeVertOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.pointSize = (1.6 + bv * 3.4 + imp * 2.4) * persp * (u.isCompact > 0.5 ? 0.82 : 1.0);
    out.color = float4(float3(0.94, 0.97, 1.0) * alpha, alpha);
    return out;
}

fragment float4 softParticleFragment(SpikeVertOut in [[stage_in]],
                                     float2 pc [[point_coord]]) {
    float r = length(pc - 0.5) * 2.0;
    float mask = smoothstep(1.0, 0.1, r);
    return float4(in.color.rgb * mask, in.color.a * mask);
}

// ============================================================================
// PRESET 02: ECOLOGY WALL — TERRITORY FIELD + 5,000 STIPPLED COLONY AGENTS
// ============================================================================
static inline float2 colonyAttractor(int idx, float t) {
    if (idx == 0) return float2(0.28 + sin(t * 0.36) * 0.09, 0.48 + cos(t * 0.31) * 0.11);
    if (idx == 1) return float2(0.54 + cos(t * 0.28) * 0.10, 0.35 + sin(t * 0.42) * 0.10);
    if (idx == 2) return float2(0.73 + sin(t * 0.46) * 0.08, 0.58 + cos(t * 0.37) * 0.11);
    if (idx == 3) return float2(0.43 + cos(t * 0.34) * 0.09, 0.69 + sin(t * 0.29) * 0.09);
    return float2(0.65 + sin(t * 0.39) * 0.08, 0.28 + cos(t * 0.48) * 0.08);
}

static inline float3 colonyColor(int idx) {
    if (idx == 0) return float3(0.91, 0.93, 0.96); // Chalk white
    if (idx == 1) return float3(0.85, 0.55, 0.37); // Warm terracotta ochre
    if (idx == 2) return float3(0.50, 0.72, 0.63); // Lichen sage
    if (idx == 3) return float3(0.84, 0.71, 0.42); // Desert gold
    return float3(0.54, 0.66, 0.84);               // Mineral slate blue
}

fragment float4 ecologyFieldFragment(FullscreenOut in [[stage_in]],
                                     constant AcousticUniforms& u [[buffer(0)]]) {
    // Deep charcoal gallery backdrop
    float3 col = float3(0.055, 0.067, 0.086);

    float screenAspect = u.resolution.x / max(1.0, u.resolution.y);
    bool isPortrait = screenAspect < 0.95;

    // Map active colony box (center panel in Studio mode, full frame in compact landscape, open stage in portrait iPhone)
    float2 minB = isPortrait ? float2(0.0, 0.12) : ((u.isCompact > 0.5) ? float2(0.0, 0.0) : float2(0.265, 0.055));
    float2 maxB = isPortrait ? float2(1.0, 0.72) : ((u.isCompact > 0.5) ? float2(1.0, 1.0) : float2(0.745, 0.945));

    if (in.uv.x >= minB.x && in.uv.x <= maxB.x && in.uv.y >= minB.y && in.uv.y <= maxB.y) {
        float2 p = (in.uv - minB) / (maxB - minB);
        float2 boxPx = (maxB - minB) * u.resolution;
        float boxAspect = max(0.35, boxPx.x / max(1.0, boxPx.y));
        col = isPortrait ? float3(0.055, 0.067, 0.086) : float3(0.045, 0.056, 0.074);

        // Subtle gold survey crosshair matching the ecology wall installation
        float crossH = smoothstep(0.0022, 0.0, abs(p.y - 0.55));
        float crossV = smoothstep(0.0018, 0.0, abs(p.x - 0.62));
        col += float3(0.84, 0.71, 0.42) * max(crossH, crossV) * 0.22;

        float energies[5] = { u.bass, u.mid, u.treble, u.energy, u.flux };
        for (int i = 0; i < 5; i++) {
            float2 c = colonyAttractor(i, u.time);
            float2 d = minDimCoord(p, c, boxAspect);
            float ang = atan2(d.y, d.x);
            float wobble = 1.0 + 0.16 * sin(ang * 3.0 + u.time + float(i)) + 0.10 * cos(ang * 5.0 - u.time * 1.3);
            float rad = (0.11 + energies[i] * 0.15 + u.beat * 0.03) * wobble;
            float dist = length(d);

            float fill = smoothstep(rad, rad * 0.25, dist);
            float rim  = exp(-abs(dist - rad) * 145.0);
            float3 cc = colonyColor(i);
            col += cc * fill * 0.11 + cc * rim * 0.55;
        }
    }

    return float4(col, 1.0);
}

vertex SpikeVertOut ecologyAgentVertex(uint vid [[vertex_id]],
                                       constant AcousticUniforms& u [[buffer(0)]]) {
    int cluster = int(vid % 5);
    int band = int(vid % 24);
    float bv = getBand(u, band);
    float fi = float(vid);

    float2 att = colonyAttractor(cluster, u.time);
    float baseAngle = fract(fi * 0.6180339) * 6.2831853;
    float orbitSpeed = (0.22 + 0.65 * fract(fi * 0.381966)) * ((vid % 2 == 0) ? 1.0 : -1.0);
    float ang = baseAngle + u.time * orbitSpeed * (0.4 + bv * 1.15);

    float radialSeed = pow(fract(fi * 0.7548776), 0.62);
    float wobble = 1.0 + 0.16 * sin(ang * 3.0 + u.time + float(cluster));
    float rad = radialSeed * (0.11 + bv * 0.17 + u.beat * 0.035) * wobble;

    float screenAspect = u.resolution.x / max(1.0, u.resolution.y);
    bool isPortrait = screenAspect < 0.95;

    float2 minB = isPortrait ? float2(0.02, 0.12) : ((u.isCompact > 0.5) ? float2(0.02, 0.02) : float2(0.27, 0.065));
    float2 maxB = isPortrait ? float2(0.98, 0.72) : ((u.isCompact > 0.5) ? float2(0.98, 0.98) : float2(0.74, 0.935));
    float2 boxPx = (maxB - minB) * u.resolution;
    float boxAspect = max(0.35, boxPx.x / max(1.0, boxPx.y));

    float2 offset = (boxAspect >= 1.0)
        ? float2(cos(ang) * rad / boxAspect, sin(ang) * rad)
        : float2(cos(ang) * rad, sin(ang) * rad * boxAspect);
    float2 p = att + offset;
    // Slight curl drift
    float2 drift = (boxAspect >= 1.0)
        ? float2(gradNoise(p * 5.0 + u.time * 0.25) / boxAspect, gradNoise(p * 5.0 - u.time * 0.22 + 4.1))
        : float2(gradNoise(p * 5.0 + u.time * 0.25), gradNoise(p * 5.0 - u.time * 0.22 + 4.1) * boxAspect);
    p += drift * 0.025;
    p = clamp(p, 0.02, 0.98);

    float2 uv = mix(minB, maxB, p);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);

    float3 cc = colonyColor(cluster);
    float alpha = clamp(0.45 + bv * 0.55, 0.35, 0.98);

    SpikeVertOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.pointSize = (2.0 + bv * 2.8 + fract(fi * 0.13) * 1.4) * (u.isCompact > 0.5 ? 0.85 : 1.0);
    out.color = float4(cc * alpha, alpha);
    return out;
}

// ============================================================================
// PRESET 03: PHOSPHOR SCOPE — TRUE GPU RGBA16F PING-PONG CRT LISSAJOUS
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

    float3 beamCol = (u.amberMode > 0.5)
        ? float3(1.00, 0.64, 0.18)   // P39 Warm Amber
        : float3(0.24, 1.00, 0.56);  // P31 Emerald Phosphor

    float scale = 0.42 * (1.0 + u.beat * 0.10);
    float accum = 0.0;
    float haloAccum = 0.0;

    // Evaluate 128 stereo Lissajous beam segments with velocity-dependent intensity
    // When paused/silent, trace a calm breathing harmonic Lissajous figure-8 instead of collapsing to a hot center dot
    float idleMix = smoothstep(0.03, 0.005, u.energy);

    float2 a = phosphorSamplePoint(waveLR, 0, scale, u.time, idleMix);
    for (int i = 1; i < 128; i++) {
        float2 b = phosphorSamplePoint(waveLR, i * 2, scale, u.time, idleMix);
        float d = sdSegment(p, a, b);
        float vel = length(b - a);
        // Real CRT physics: slower beam dwells longer -> hotter phosphor excitation
        float dwell = clamp(0.018 / (vel + 0.012), 0.30, 1.85);
        accum += exp(-d * 340.0) * dwell;
        haloAccum += exp(-d * 72.0) * dwell * 0.11;
        a = b;
    }

    // Crisp horizontal L-channel time-domain waveform behind the Lissajous knot
    float wIdx = clamp(in.uv.x * 255.0, 0.0, 254.0);
    int wi = int(wIdx);
    float wyLive = mix(waveLR[wi].x, waveLR[wi + 1].x, fract(wIdx)) * 0.32;
    float wyIdle = sin(in.uv.x * 12.56637 + u.time * 1.1) * 0.055 * sin(in.uv.x * 3.14159);
    float wy = mix(wyLive, wyIdle, idleMix);
    float wDist = abs(p.y - wy);
    float trace = exp(-wDist * 220.0) * mix(0.34, 0.22, idleMix);

    float3 coreHot = mix(beamCol, float3(0.95, 1.0, 0.96), 0.72);
    float idleDim = mix(1.0, 0.48, idleMix);
    col += (coreHot * min(accum, 2.2) * 0.56 + beamCol * min(haloAccum, 1.4) * 0.28) * idleDim + beamCol * trace;

    return float4(min(col, 4.0), 1.0);
}

fragment float4 phosphorDisplayFragment(FullscreenOut in [[stage_in]],
                                        texture2d<float> scopeTex [[texture(0)]],
                                        constant AcousticUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 beam = scopeTex.sample(s, in.uv).rgb;

    float3 bg = (u.amberMode > 0.5) ? float3(0.036, 0.026, 0.014) : float3(0.018, 0.036, 0.024);
    float3 grCol = (u.amberMode > 0.5) ? float3(1.0, 0.72, 0.30) : float3(0.36, 1.0, 0.60);

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

    // Gentle CRT glass vignette + filmic curve
    float vig = smoothstep(1.3, 0.25, length((in.uv - center) * 1.45));
    col *= mix(0.75, 1.0, vig);
    col = col / (1.0 + col * 0.35);
    return float4(col, 1.0);
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
// PRESET 04: NOCTURNE SILK — TRUE GPU RGBA16F HDR VELVET FEEDBACK SHADER
// ============================================================================
fragment float4 liquidUpdateFragment(FullscreenOut in [[stage_in]],
                                     texture2d<float> prevTex [[texture(0)]],
                                     constant AcousticUniforms& u [[buffer(0)]],
                                     constant float2* waveLR [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.5);
    float2 p = minDimCoord(in.uv, center, aspect);

    float r = length(p);
    float ang = atan2(p.y, p.x);

    // Slow, velvety curl-noise domain warp + gentle bass breath
    float n1 = gradNoise(p * 2.8 + float2(u.time * 0.14, -u.time * 0.11));
    float n2 = gradNoise(p * 2.8 + float2(-u.time * 0.12, u.time * 0.16) + 5.2);

    float zoom = 0.991 - u.bass * 0.007 - u.beat * 0.008;
    float rot = 0.004 * sin(u.time * 0.30) + 0.006 * u.mid * sin(r * 3.0);
    float cR = cos(rot), sR = sin(rot);

    float2 rotP = float2(p.x * cR - p.y * sR, p.x * sR + p.y * cR) * zoom;
    float2 centered = (aspect >= 1.0) ? float2(rotP.x / aspect, rotP.y) : float2(rotP.x, rotP.y * aspect);
    float2 sampleUV = centered + center + float2(n1, n2) * (0.0028 + u.treble * 0.0042);

    // Subtle warm optical dispersion
    float2 dirP = normalize(p + 1e-4) * (0.0012 + u.beat * 0.0024);
    float2 disp = (aspect >= 1.0) ? float2(dirP.x / aspect, dirP.y) : float2(dirP.x, dirP.y * aspect);
    float3 prev;
    prev.r = prevTex.sample(s, sampleUV + disp).r;
    prev.g = prevTex.sample(s, sampleUV).g;
    prev.b = prevTex.sample(s, sampleUV - disp).b;
    prev *= (0.930 + u.bass * 0.015);

    // Soft nocturnal waveform ribbon
    float wIdx = clamp(in.uv.x * 255.0, 0.0, 254.0);
    int wi = int(wIdx);
    float wave = mix(waveLR[wi].x, waveLR[wi + 1].x, fract(wIdx)) * (0.36 + u.bass * 0.24);
    float ribbon = exp(-abs(p.y - wave * 0.56) * (64.0 - u.beat * 12.0));

    // Smoothly interpolated nocturnal halo ring (no jagged wedge seams)
    float normAng = fract(ang / 6.2831853 + 0.5 + u.time * 0.038);
    float bandPos = normAng * 24.0;
    int b0 = int(floor(bandPos)) % 24;
    int b1 = (b0 + 1) % 24;
    float bf = smoothstep(0.0, 1.0, fract(bandPos));
    float spec = mix(getBand(u, b0), getBand(u, b1), bf);
    float ringR = 0.20 + spec * 0.15 + u.bass * 0.05 + 0.016 * sin(ang * 4.0 + u.time * 0.65);
    float ring = exp(-abs(r - ringR) * (54.0 - u.beat * 8.0));
    float innerRing = exp(-abs(r - ringR * 0.56) * 76.0) * 0.42;

    float3 col1 = nocturnePalette(u.time * 0.042 + in.uv.x * 0.32 + u.bass * 0.16);
    float3 col2 = nocturnePalette(u.time * 0.042 + 0.36 + spec * 0.28);

    float3 inject = col1 * ribbon * (0.56 + u.mid * 0.58) + col2 * (ring + innerRing) * (0.58 + u.beat * 0.68);
    float3 outCol = prev + inject * 0.24;

    float vig = smoothstep(1.28, 0.22, length((in.uv - center) * 1.4));
    outCol *= mix(0.84, 1.0, vig);

    return float4(clamp(outCol, 0.0, 2.6), 1.0);
}

fragment float4 liquidDisplayFragment(FullscreenOut in [[stage_in]],
                                      texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = tex.sample(s, in.uv).rgb;
    // ACES filmic HDR tonemapping into deep midnight obsidian
    c = (c * (2.51 * c + 0.03)) / (c * (2.43 * c + 0.59) + 0.14);
    c = pow(max(c, 0.0), float3(0.96));
    c = mix(float3(0.022, 0.028, 0.048), c, smoothstep(0.0, 0.10, length(c)));
    return float4(c, 1.0);
}

// ============================================================================
// PRESET 05: HORIZON — TURRELL / ROTHKO MONOCHROME ATMOSPHERIC LIGHT PLANE
// ============================================================================
fragment float4 horizonFragment(FullscreenOut in [[stage_in]],
                                constant AcousticUniforms& u [[buffer(0)]]) {
    float aspect = u.resolution.x / max(1.0, u.resolution.y);
    float2 center = (aspect < 1.0) ? u.coreCenter : float2(0.5, 0.50);
    float2 p = minDimCoord(in.uv, center, aspect);

    // Deep obsidian zenith fading subtly into still slate water below
    float3 zenith = float3(0.022, 0.028, 0.042);
    float3 nadir  = float3(0.016, 0.020, 0.030);
    float3 col = mix(zenith, nadir, smoothstep(-0.35, 0.45, p.y));

    // Ultra-slow drifting atmospheric mist (zero sharp jitter)
    float t = u.time;
    float mist1 = gradNoise(float2(p.x * 2.2 + t * 0.055, p.y * 4.5 - t * 0.028));
    float mist2 = gradNoise(float2(p.x * 4.6 - t * 0.038, p.y * 8.0 + t * 0.020) + 4.3);
    float mist = mist1 * 0.65 + mist2 * 0.35;

    // Gentle acoustic breath modulates the horizon thickness & warmth
    float breath = 0.5 + 0.5 * sin(t * 0.42);
    float spread = 0.13 + u.bass * 0.08 + u.energy * 0.05 + breath * 0.018;
    float yShift = p.y - mist * (0.022 + u.mid * 0.018);

    // Wide horizontal Rothko twilight bloom
    float xMask = exp(-(p.x * p.x) / (0.62 + u.energy * 0.24));
    float bandWide = exp(-(yShift * yShift) / (spread * spread * 2.2)) * (0.55 + 0.45 * xMask);
    float bandCore = exp(-(yShift * yShift) / (spread * spread * 0.16)) * xMask;

    // Luminous rising sun/moon dome gently kissing the horizon (echoing the STILL glyph)
    float2 domeP = float2(p.x, p.y + 0.012);
    float domeDist = length(domeP);
    float domeRadius = 0.115 + u.bass * 0.032 + breath * 0.008;
    float aboveHorizon = smoothstep(0.012, -0.018, p.y);
    float domeGlow = exp(-(domeDist * domeDist) / (domeRadius * domeRadius * 1.15)) * aboveHorizon;
    float domeRim = exp(-abs(domeDist - domeRadius) * 85.0) * aboveHorizon * 0.42;

    // Quiet water-reflection striations below the horizon line
    float belowHorizon = smoothstep(-0.006, 0.020, p.y);
    float rippleWave = 0.5 + 0.5 * sin(p.y * 130.0 - t * 0.9 + mist1 * 2.5);
    float refl = exp(-max(0.0, p.y) * 5.8) * exp(-(p.x * p.x) / 0.12) * belowHorizon * (0.35 + 0.65 * rippleWave);

    // Hairline silver-pearl horizon filament
    float horizonLine = exp(-abs(p.y) * 260.0) * (0.32 + 0.46 * xMask);

    // Calm desaturated monochrome architectural palette (cool silver mist + whisper of warm parchment)
    float3 mistCol = float3(0.32, 0.39, 0.50);
    float3 warmCol = float3(0.76, 0.78, 0.84);
    float3 lineCol = float3(0.92, 0.94, 0.98);

    col += mistCol * bandWide * (0.28 + u.energy * 0.24 + mist * 0.06);
    col += warmCol * bandCore * (0.24 + u.mid * 0.22);
    col += warmCol * domeGlow * (0.26 + u.energy * 0.24) + lineCol * domeRim * (0.45 + u.mid * 0.35);
    col += warmCol * refl * (0.16 + u.bass * 0.14);
    col += lineCol * horizonLine * (0.48 + u.treble * 0.28);

    // Subtle film dither so 10-bit OLED / Retina gradients never band
    float grain = (hash12(in.position.xy + fract(u.time)) - 0.5) * 0.012;
    return float4(max(col + grain, 0.0), 1.0);
}
