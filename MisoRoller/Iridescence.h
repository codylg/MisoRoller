#ifndef Iridescence_h
#define Iridescence_h

#include <metal_stdlib>
using namespace metal;

// Shared machinery for the iridescent post-process looks (Metal and Glow): noise,
// film grain, the scene→perceptual tone mapping, palette interpolation, and the
// separable blur their bloom chains run through. Each look keeps its own palette
// and its own fragment entry points; only the maths lives here.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

/// Hash with no axis correlation. `hash21` is fine for the value-noise lattice,
/// but on a per-pixel integer grid its `fract(p.x * p.y)` tail lines the speckle
/// up into faint vertical striations — very visible once the grain is strong, and
/// against a near-white background.
static float hashGrain(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Four octaves, normalised to 0...1.
static float fbm(float2 p) {
    float sum = 0.0, amp = 0.5, total = 0.0;
    for (int i = 0; i < 4; ++i) {
        sum += amp * valueNoise(p);
        total += amp;
        p *= 2.0;
        amp *= 0.5;
    }
    return sum / total;
}

/// Scene luminance, re-encoded to a perceptual 0...1.
///
/// The technique's render targets hold LINEAR values (the same reason a composite
/// has to `pow(…, 2.2)` on the way out). Feeding that straight into a palette
/// squashes everything the eye reads as "light" into the bottom half — a table
/// authored at 0.80 arrives as 0.65 and grades out blue. The gamma here puts the
/// value back in the space the palette stops are written in, which is also the
/// space a plain screenshot of the scene measures in.
static float sceneTone(float3 c) {
    return pow(max(dot(c, float3(0.299, 0.587, 0.114)), 0.0), 1.0 / 2.2);
}

/// Signed speckle in -0.5...0.5, pushed toward its extremes so it reads as sharp
/// grain rather than a soft haze. `cell` is the noise cell size in pixels.
static float grain(float2 uv, float2 texSize, float cell) {
    float g = hashGrain(floor(uv * texSize / cell)) - 0.5;
    return sign(g) * pow(abs(g) * 2.0, 0.65) * 0.5;
}

/// Piecewise-linear lookup through a palette of `n` stops.
static float3 rampColor(constant float3 *colors, constant float *stops, int n, float t) {
    t = clamp(t, 0.0, 1.0);
    float3 c = colors[n - 1];
    for (int i = 0; i < n - 1; ++i) {
        if (t <= stops[i + 1]) {
            float f = (t - stops[i]) / max(stops[i + 1] - stops[i], 1e-5);
            c = mix(colors[i], colors[i + 1], f);
            break;
        }
    }
    return c;
}

/// 13-tap Gaussian (sigma 2.5 taps). Run at 1/8 scale, `spacing` of ~2.5 texels
/// reaches ~100 full-resolution pixels either side — wide enough to read as a
/// heavy glow rather than a soft edge.
constant float blurWeights[7] = { 0.16100, 0.14863, 0.11691, 0.07838, 0.04476, 0.02179, 0.00903 };

static float3 separableBlur(texture2d<float, access::sample> tex,
                            float2 uv, float2 dir, float spacing) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 step = dir / float2(tex.get_width(), tex.get_height()) * spacing;
    float3 sum = tex.sample(smp, uv).rgb * blurWeights[0];
    for (int i = 1; i < 7; ++i) {
        float2 o = step * float(i);
        sum += (tex.sample(smp, uv + o).rgb + tex.sample(smp, uv - o).rgb) * blurWeights[i];
    }
    return sum;
}

#endif /* Iridescence_h */
