#include <metal_stdlib>
using namespace metal;
#include "PostProcess.h"
#include "Iridescence.h"

// Soft bloom. A pale, barely-coloured off-white table with a heavy grain, and a
// wide glow that comes off the dice themselves — the brightest thing on screen —
// rather than washing the whole frame.
//
// This is the calm sibling of the Metal look in ChromaticMetal.metal: same bloom
// chain (see PostProcessTechnique.makeBloomChain), same grain, but a palette that
// stays within a few percent of white across everything above the dice's own
// shading. Metal reuses the structure and pushes the colour hard.

// Stops are fitted to the scene's measured plateaus, in the perceptual space
// `sceneTone` produces: numerals ~0.10, die side facets 0.50-0.70, cast shadow
// ~0.73, the table 0.71-0.80, die top faces 0.90-1.00.
//
// Everything from 0.66 up — which is where the table lives — is within a few
// percent of white, and the tints there differ only in *which* channel is held
// back. That's what keeps the background a barely-coloured off-white that pools
// gently between pink and mint, rather than a field of blue: a colour is only as
// subtle as its weakest channel, and pinning blue to 0.95 across the whole upper
// range tints the entire frame no matter how light it is.
constant float3 glowColors[8] = {
    float3(0.30, 0.26, 0.44),   // soft plum — numerals, deepest ink
    float3(0.44, 0.42, 0.72),   // muted indigo
    float3(0.56, 0.66, 0.88),   // soft blue      \ die side facets
    float3(0.74, 0.83, 0.92),   // pale cyan      /
    float3(0.88, 0.90, 0.95),   // whisper of blue — cast-shadow edge
    float3(0.98, 0.93, 0.96),   // pale pink   \ the table drifts
    float3(0.92, 0.97, 0.94),   // pale mint   / between these two — pulled a
                                //   touch darker than before so the final
                                //   stop below has more headroom to separate
                                //   the die's top faces from one another
    float3(1.00, 0.99, 0.98)    // warm white — die top faces
};
// The last stop moved from 0.86 to 0.90 to hug the die top faces' measured
// plateau (0.90-1.00) more tightly, so the mint->white transition — the pair
// that actually spans the top faces — happens over a narrower, steeper slice
// of input tone instead of being diluted across the flatter table range below.
constant float glowStops[8] = { 0.00, 0.24, 0.42, 0.56, 0.66, 0.76, 0.90, 1.00 };

static float3 glowRamp(float t) {
    return rampColor(glowColors, glowStops, 8, t);
}

// MARK: - Bloom chain

/// Only the top of the scene's tonal range counts as a highlight. The table
/// renders around 0.80, so this knee picks out the die top faces and bevel
/// catchlights and leaves the background contributing nothing — that's what keeps
/// the glow local to the dice instead of flattening the whole frame.
constant float glowKneeLow = 0.87;
constant float glowKneeHigh = 1.00;
constant float glowBlurSpacing = 2.6;
constant float glowStrength = 1.15;

/// Bright-pass + downsample. Runs into a 1/8-scale target, so it averages a 4x4
/// grid spanning roughly one destination texel of the full-res source.
fragment half4 glow_bright_fragment(PostVertexOut in [[stage_in]],
                                    texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = 1.0 / float2(colorSampler.get_width(), colorSampler.get_height());

    float3 sum = float3(0.0);
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 o = (float2(i, j) - 1.5) * 3.0 * texel;
            float tone = sceneTone(colorSampler.sample(smp, in.uv + o).rgb);
            float w = smoothstep(glowKneeLow, glowKneeHigh, tone);
            // Tint the glow with the same ramp the frame is graded through, so
            // the halo carries the palette instead of being neutral white.
            sum += glowRamp(tone) * w;
        }
    }
    return half4(half3(sum / 16.0), 1.0);
}

fragment half4 glow_blur_h_fragment(PostVertexOut in [[stage_in]],
                                    texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    return half4(half3(separableBlur(colorSampler, in.uv, float2(1.0, 0.0), glowBlurSpacing)), 1.0);
}

fragment half4 glow_blur_v_fragment(PostVertexOut in [[stage_in]],
                                    texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    return half4(half3(separableBlur(colorSampler, in.uv, float2(0.0, 1.0), glowBlurSpacing)), 1.0);
}

// MARK: - Composite

fragment half4 glow_composite_fragment(PostVertexOut in [[stage_in]],
                                       texture2d<float, access::sample> colorSampler [[texture(0)]],
                                       texture2d<float, access::sample> bloomSampler [[texture(1)]],
                                       texture2d<float, access::sample> noiseSampler [[texture(2)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 texSize = float2(colorSampler.get_width(), colorSampler.get_height());
    float t = sceneTone(colorSampler.sample(smp, in.uv).rgb);

    // The shading that sits just under the table's own tone — the dice's cast
    // shadow above all — spans only a few percent of luminance, and the pale top
    // of the ramp renders that as one flat tint, leaving the dice looking like
    // they float. Expanding contrast about the table's level separates it again
    // (and deepens the numerals) while leaving the background itself unmoved,
    // since the table sits on the pivot. Only the shaded side needs this lift:
    // stretching the lit side by the same 1.45 pushes the die's top faces
    // (already sitting at 0.90-1.00) past 1.0, and `saturate` below then clips
    // all of them to the same pure-white stop — that's the literal mechanism
    // behind faces merging into one flat white. Leaving tone above the pivot
    // unstretched keeps their real, if narrow, spread intact for the (now
    // steeper) ramp above to render.
    t = t < 0.78 ? 0.78 + (t - 0.78) * 1.45 : t;

    // Colour warp: two noise fields at different scales, the second offset by the
    // first, so the palette bends and pools across a surface rather than sitting
    // in flat bands. Aspect-corrected so the cells stay round — baked once per
    // quarter-scale texel by post_noise_fragment rather than re-derived from ~30
    // hashes at every pixel of every frame.
    float warp = noiseSampler.sample(smp, in.uv).r;
    t += (warp - 0.5) * 0.12;

    // Coarse grain, applied to the ramp coordinate so each speck lands on its own
    // colour — this is what gives the surface its iridescent fizz.
    t += grain(in.uv, texSize, 1.5) * 0.20;

    float3 base = glowRamp(t);

    float3 bloom = saturate(bloomSampler.sample(smp, in.uv).rgb * glowStrength);
    // A screen blend lifts the darkest pixels hardest — which is exactly where
    // the scene's shading lives, and the numerals sit right in the middle of the
    // brightest thing on screen. Ungoverned, the glow erases both. Easing it back
    // below the table's tone keeps the roll readable and the dice grounded,
    // without softening the effect over the background or the bright faces.
    bloom *= mix(0.40, 1.0, smoothstep(0.05, 0.55, t));
    float3 lit = 1.0 - (1.0 - base) * (1.0 - bloom);
    lit += bloom * 0.16;   // a little additive haze so the highlights still bleed

    // Fine grain on the finished colour, so it survives in the areas the bloom
    // has flattened out.
    lit *= 1.0 + grain(in.uv + 0.37, texSize, 1.0) * 0.12;

    // The technique's output is consumed as LINEAR and gamma-encoded on the way
    // to the display, but the ramp above is authored in the sRGB values it should
    // actually look like. Without this the whole palette lifts.
    return half4(half3(pow(saturate(lit), 2.2)), 1.0);
}
