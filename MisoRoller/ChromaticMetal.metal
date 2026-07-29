#include <metal_stdlib>
using namespace metal;
#include "PostProcess.h"
#include "Iridescence.h"

// Anodised / oil-slick metal: electric blue → violet → magenta → lime, warped and
// dispersed so the dice read as iridescent metal rather than tinted paper.
//
// The hard problem here is that a plain luminance→palette ramp can't give both a
// pale background AND saturated dice: the table's luminance sits in the *middle*
// of the dice's range (table ~0.78, die faces 0.50-1.00), so any palette light
// enough for the table is light where the dice are too. That's what bled the
// colour out of the previous version.
//
// The fix is a second axis. `chroma` below measures how far a pixel's tone sits
// from the table's own level — near zero across the flat table, large on every
// part of a die — and the saturated palette is washed toward paper wherever it's
// low. The table keeps a whisper of the palette (so it still drifts and pools),
// the dice get all of it.

// The stop colours have to climb in LUMINANCE as well as sweep in hue, or the
// grading fights the scene's own lighting. The previous set had the die's shaded
// sides on a fully saturated electric blue at luminance 0.40 and their lit faces
// on an orchid at 0.67 — a ratio of 1.7 against the scene's real 3.3 — so the
// shading came out at half strength, and because that blue was also the most
// saturated colour on screen the faces pointing AWAY from the light read as the
// brightest thing on the die. (It also ran backwards between azure 0.547 and
// violet 0.525: over that stretch the die got darker as the scene got brighter.)
// These climb 0.08 → 0.15 → 0.28 → 0.44 → 0.53 → 0.74 → 0.90 → 1.00, monotonic,
// with the saturation carried by the dark end where it doesn't inflate lightness.
// Luminances run 0.06 → 0.11 → 0.22 → 0.34 → 0.45 → 0.72 → 0.90 → 1.00: monotonic,
// and shaped as an S-curve rather than a straight line. The lower-mid is
// deliberately held down — a d20's partially-turned faces land around the azure
// stop, and at its old luminance of 0.44 they read as lit rather than shaded.
// Most of the climb is saved for the top three stops, so the faces actually
// facing the light are the brightest thing on the die by a clear margin.
constant float3 metalColors[8] = {
    float3(0.08, 0.02, 0.22),   // near-black indigo — numerals, deepest ink
    float3(0.06, 0.07, 0.48),   // deep blue
    float3(0.04, 0.21, 0.78),   // blue — steep side facets, dark but still vivid
    float3(0.10, 0.34, 0.95),   // azure — partially-turned faces
    float3(0.45, 0.34, 1.00),   // violet
    float3(1.00, 0.52, 1.00),   // orchid — where the lit die faces sit
    float3(0.88, 1.00, 0.44),   // lime — the catchlight along every bevel
    float3(1.00, 1.00, 0.96)    // white-hot
};
constant float metalStops[8] = { 0.00, 0.22, 0.42, 0.56, 0.68, 0.80, 0.88, 1.00 };

static float3 metalRamp(float t) {
    return rampColor(metalColors, metalStops, 8, t);
}

static float luma(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

/// The warp shifts HUE ONLY — never brightness.
///
/// Moving a pixel's position along the palette changes its lightness as well as
/// its hue, so a shaded facet sitting on a dark blue would get pushed up onto
/// azure by noise and come out looking lit. That's why only the very darkest
/// faces read as shaded; everything else was being randomly brightened. Rescaling
/// the warped colour back to the luminance its *unwarped* position implies makes
/// the iridescence purely chromatic and leaves the scene's own shading intact.
/// Fully locked: any residual swing puts light patches back on shaded faces,
/// which is the whole artefact being removed here.
constant float warpLumLock = 1.0;

/// The scene tone the table renders at. `chroma` measures distance from this, and
/// the palette map below is anchored to it.
constant float tableTone = 0.78;

/// Where the table's tone lands in the palette, and how fast the palette moves
/// with scene tone.
///
/// The obvious mapping — leave the table where it falls, 0.78 — is wrong, and it
/// was what kept bleaching the dice. It puts the die faces (0.92-1.00 raw) at the
/// very top of the palette, where every band has already converged on white, so
/// they came out pale mint no matter how the stops below were arranged. The table
/// is washed to paper by `paperWash` regardless of what colour it lands on, which
/// means its palette position is free — so it's parked low and the dice get the
/// whole range: facets in the blues, faces sweeping violet → orchid → lime.
/// The slope also decides *where on the palette a die face sits*, which matters
/// more than it sounds: orchid and lime are near-complementary, so the stretch
/// between them interpolates through grey. At 1.35 the faces landed exactly in
/// the middle of that stretch and came out muddy pastel however saturated the two
/// end colours were. At 1.05 they sit on orchid itself, and only the sheen's
/// peaks carry them up into the lime — across a gap narrow enough that few pixels
/// linger in the desaturated part.
constant float tablePalette = 0.62;
constant float paletteSlope = 1.05;

static float paletteCoord(float tone) {
    return tablePalette + (tone - tableTone) * paletteSlope;
}

static float toneAt(texture2d<float, access::sample> tex, float2 uv) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    return sceneTone(tex.sample(smp, uv).rgb);
}

// MARK: - Bloom chain

/// Only the top of the scene's tonal range counts as a highlight — the die top
/// faces and bevel catchlights — so the glow stays local to the dice instead of
/// flattening the whole frame. Measured on the raw tone, before the expansion.
constant float metalKneeLow = 0.87;
constant float metalKneeHigh = 1.00;
constant float metalBlurSpacing = 2.6;
constant float metalStrength = 0.85;

/// Bright-pass + downsample. Runs into a 1/8-scale target, so it averages a 4x4
/// grid spanning roughly one destination texel of the full-res source.
fragment half4 chromatic_bright_fragment(PostVertexOut in [[stage_in]],
                                         texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = 1.0 / float2(colorSampler.get_width(), colorSampler.get_height());

    float3 sum = float3(0.0);
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 o = (float2(i, j) - 1.5) * 3.0 * texel;
            float tone = sceneTone(colorSampler.sample(smp, in.uv + o).rgb);
            float w = smoothstep(metalKneeLow, metalKneeHigh, tone);
            // Tint the glow with the same palette the frame is graded through — up
            // here that's orchid into lime, which is what gives the halo its cast.
            sum += metalRamp(paletteCoord(tone)) * w;
        }
    }
    return half4(half3(sum / 16.0), 1.0);
}

fragment half4 chromatic_blur_h_fragment(PostVertexOut in [[stage_in]],
                                         texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    return half4(half3(separableBlur(colorSampler, in.uv, float2(1.0, 0.0), metalBlurSpacing)), 1.0);
}

fragment half4 chromatic_blur_v_fragment(PostVertexOut in [[stage_in]],
                                         texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    return half4(half3(separableBlur(colorSampler, in.uv, float2(0.0, 1.0), metalBlurSpacing)), 1.0);
}

// MARK: - Composite

/// How far the palette is washed out over flat ground. The table keeps 1 - this
/// much of whatever colour it landed on, which is enough for it to drift and pool
/// without ever reading as a coloured background.
constant float paperWash = 0.82;

/// The paper the table washes toward — and crucially, how bright that paper is at
/// a given scene tone.
///
/// Washing toward a *constant* colour throws away 82% of the ground's tonal
/// variation, which is what flattened the cast shadow into a single tone and made
/// the background's wavy bands so faint: a shadow 0.06 darker than the table came
/// out only 0.011 darker on screen. Tracking the scene's own tone instead — and
/// slightly expanding it — puts the shadow's gradation and the bands back, because
/// the thing being mixed in now varies with the pixel rather than being flat.
constant float3 paperColor = float3(0.97, 0.965, 0.98);
/// Shadowed paper leans cool, the way real shade lit by ambient does. Blending
/// toward this by darkness gives the cast shadow a colour of its own rather than
/// just less of the same one.
constant float3 paperShade = float3(0.88, 0.92, 1.00);
constant float paperLightPivot = 0.96;   // lightness of paper at the table's tone
constant float paperLightSlope = 1.10;   // >1 expands ground contrast rather than compressing it
/// Ceiling on how chromatic ground below the table's tone may get. See the note
/// at the use site: full chroma buries the cast shadow in near-black, none of it
/// drops the shadow out of the shader altogether.
constant float groundChromaCap = 0.45;
// NOTE: pushing more of the palette's hue into the ground was tried twice and
// both attempts blew out. Raising the palette's share of the mix flattens the
// wavy bands, because the palette is much darker than the paper and dilutes the
// lightness variation the bands are made of. Rescaling the palette colour up to
// the paper's luminance instead clips its blue channel — the palette's blues run
// to 1.0 already — and turns the whole table cyan. If the ground needs to feel
// more like the dice, reach for grain (below), not colour.
/// Peak per-channel sampling offset, in pixels.
constant float dispersion = 7.0;

fragment half4 chromatic_composite_fragment(PostVertexOut in [[stage_in]],
                                            texture2d<float, access::sample> colorSampler [[texture(0)]],
                                            texture2d<float, access::sample> bloomSampler [[texture(1)]],
                                            texture2d<float, access::sample> noiseSampler [[texture(2)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 texSize = float2(colorSampler.get_width(), colorSampler.get_height());

    // The warp fields, baked once per quarter-scale texel by post_noise_fragment
    // rather than re-derived from ~50 hashes at every pixel of every frame. They
    // depend only on screen position, so this is the same picture.
    float3 noise = noiseSampler.sample(smp, in.uv).rgb;

    float3 scene = colorSampler.sample(smp, in.uv).rgb;
    float tone = sceneTone(scene);

    // Is this pixel part of a die, or the table? Two independent tests, either of
    // which is enough.
    //
    // Distance from the table's own level catches most of a die — bright faces
    // above it, facets and ink below. But it is blind to a face whose shading
    // happens to land on the table's exact tone, and those got washed to paper:
    // white patches sitting brighter than the genuinely lit faces.
    //
    // Warmth settles those. The floor texture is written r=g=b and both lights are
    // untinted, so the table renders EXACTLY neutral — measured 0.0000 across open
    // table, table near the dice, and cast shadow alike — while the dice are paper
    // (1.00, 0.98, 0.93) and carry a consistent red-over-blue lean whatever the
    // light does to their brightness. It is the one cue that separates a die face
    // from table of identical luminance. Normalised by luminance so it holds from
    // the brightest face down to the ink, with a floor on the divisor so near-black
    // pixels don't amplify noise.
    float warmth = (scene.r - scene.b) / max(dot(scene, float3(0.299, 0.587, 0.114)), 0.02);
    float warmMask = smoothstep(0.04, 0.11, warmth);
    float toneMask = smoothstep(0.10, 0.22, abs(tone - tableTone));

    // Ground darker than the table — the cast shadow above all — is still part of
    // this look and has to keep the palette and the grain. But at FULL chroma it
    // lands near the bottom of the palette and comes out an almost-black saturated
    // blue (measured 0.18 luminance, 0.94 saturation) where neither the grain nor
    // the shadow's own gradation can be seen. Zero chroma is no better: it drops
    // out of the shader entirely and reads as a plain grey drop-shadow pasted
    // under a chromatic die. Capping it keeps it in the palette while letting
    // enough paper through to lift it to a luminance where the texture reads.
    float darkGround = (1.0 - warmMask) * smoothstep(0.0, 0.08, tableTone - tone);
    toneMask = mix(toneMask, min(toneMask, groundChromaCap), darkGround);

    float chroma = max(toneMask, warmMask);

    // Two warp fields. The broad one bends the palette across the whole frame so
    // it pools rather than banding.
    float broad = noise.r - 0.5;

    // The second is what actually makes the dice iridescent, and it has to be
    // this aggressive. Lit from near-overhead, a die only produces two tones —
    // bright upward faces around 0.95 and near-vertical sides around 0.55 — so
    // shading alone can never fetch more than two colours out of the palette, no
    // matter how it's arranged. This field is pitched finer than a single facet
    // and swung wide enough to cross several bands, so the sweep from violet
    // through orchid to lime happens *across* a face rather than between faces.
    // A single smooth octave rather than fbm: fbm's top octaves land at a few
    // pixels here and read as speckle fighting the grain, not as sheen.
    // (Offset by the broad field at full precision inside the noise pass.)
    float sheen = noise.g - 0.5;

    // Amplitudes are kept well inside one band of the palette. The blue-to-orchid
    // span is only 0.38 palette units, so the old ±0.20 sheen could carry a fully
    // lit face all the way onto the blue end. Locking luminance keeps such a pixel
    // correctly bright, but a *bright blue* face still reads as "in shade yet
    // brighter than the lit ones" — hue carries the lighting here as much as
    // lightness does. Held to ±0.075, hue stays adjacent to the band the face's
    // own tone selects, so blue only ever appears where the die is actually dark.
    float warp = broad * mix(0.08, 0.15, chroma) + sheen * 0.15 * chroma;

    // Coarse grain on the ramp coordinate, so each speck lands on its own colour.
    float shift = warp + grain(in.uv, texSize, 1.5) * 0.20;

    // Dispersion: the channels sample the scene a few pixels apart, so wherever
    // the scene is shading the three of them land on different parts of the
    // palette and split into rainbow fringes. Flat ground is unaffected — all
    // three offsets read the same tone there. The direction is radial (a lens
    // splits outward) bent by a noise field, so the fringes curve around the
    // dice instead of pointing uniformly at the screen edge.
    float angle = (noise.b - 0.5) * 12.0;
    float aspect = texSize.x / max(texSize.y, 1.0);
    float2 v = (in.uv - 0.5) * float2(aspect, 1.0) * 2.0 + float2(cos(angle), sin(angle)) * 0.6;
    float len = max(length(v), 1e-4);
    float2 offset = (v / len) * min(len, 1.6) * mix(0.25, 1.0, chroma) * dispersion / texSize;

    float3 col = float3(metalRamp(paletteCoord(toneAt(colorSampler, in.uv + offset)) + shift).r,
                        metalRamp(paletteCoord(tone) + shift).g,
                        metalRamp(paletteCoord(toneAt(colorSampler, in.uv - offset)) + shift).b);

    // Take the hue from the warped/dispersed lookup but the lightness from the
    // unwarped one, so the shading the scene actually has survives the sheen.
    float3 unwarped = metalRamp(paletteCoord(tone));
    col *= mix(1.0, luma(unwarped) / max(luma(col), 1e-4), warpLumLock);

    // Wash toward paper whose lightness follows the ground's own shading, cooling
    // as it darkens, so the cast shadow and the wavy bands keep their shape.
    float paperLight = saturate(paperLightPivot + (tone - tableTone) * paperLightSlope);
    float3 paper = mix(paperShade, paperColor, smoothstep(0.78, 1.02, paperLight)) * paperLight;

    col = mix(col, paper, paperWash * (1.0 - chroma));

    float3 bloom = saturate(bloomSampler.sample(smp, in.uv).rgb * metalStrength);
    // A screen blend lifts the darkest pixels hardest — which is exactly where
    // the scene's shading lives, and the numerals sit right in the middle of the
    // brightest thing on screen. Ungoverned, the glow erases both.
    bloom *= mix(0.40, 1.0, smoothstep(0.05, 0.55, tone));
    // And hold it back over the dice themselves. Screening a near-white glow over
    // the very surface that generated it drags lime and violet straight back to
    // white — which is exactly the colour this look is meant to have. Letting the
    // glow spill outward while leaving the dice to the palette keeps both.
    bloom *= mix(1.0, 0.40, chroma);

    // Screening a coloured glow over a near-white table just clips to white and
    // throws the colour away. Splitting it works better: screen with the glow's
    // *brightness* to get the blow-out, then multiply by its *hue* so the halo
    // actually carries the lime out onto the background.
    float bloomLum = dot(bloom, float3(0.299, 0.587, 0.114));
    float3 bloomHue = bloom / max(bloomLum, 1e-3);
    float3 lit = 1.0 - (1.0 - col) * (1.0 - bloomLum);
    lit *= mix(float3(1.0), bloomHue, 0.35 * bloomLum);

    // Fine grain on the finished colour, so it survives where the bloom has
    // flattened things out. This one runs AFTER the wash, which makes it the only
    // grain the table gets — the coarse grain further up rides the ramp
    // coordinate, and the wash removes most of that on ground while the dice keep
    // all of it. Pitched high enough here that ground and dice still read as the
    // same material.
    float fine = grain(in.uv + 0.37, texSize, 1.0);
    lit *= 1.0 + fine * 0.13;
    // Multiplicative grain alone scales with luminance, so the darker the area the
    // less texture it gets — the cast shadow ended up visibly smoother than the
    // table around it. A small fixed component keeps the texture readable down
    // there. Faded out below the shadow's range so it doesn't turn the numerals,
    // which are darker still, into noise.
    lit += fine * 0.028 * smoothstep(0.05, 0.25, luma(lit));

    // The technique's output is consumed as LINEAR and gamma-encoded on the way
    // to the display, but the palette is authored in the sRGB values it should
    // actually look like. Without this the whole thing lifts.
    return half4(half3(pow(saturate(lit), 2.2)), 1.0);
}
