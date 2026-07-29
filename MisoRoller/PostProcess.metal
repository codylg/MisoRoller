#include <metal_stdlib>
using namespace metal;   // must precede scn_metal or the SDK header fails to compile
#include <SceneKit/scn_metal>
#include "PostProcess.h"
#include "Iridescence.h"

struct PostVertexIn {
    float3 position [[attribute(SCNVertexSemanticPosition)]];
};

/// Shared by every post-process technique: passes the fullscreen quad straight
/// through and hands the fragment stage its screen UV.
vertex PostVertexOut post_vertex(PostVertexIn in [[stage_in]]) {
    PostVertexOut out;
    out.position = float4(in.position, 1.0);
    out.uv = in.position.xy * float2(0.5, -0.5) + 0.5;
    return out;
}

/// Bakes the iridescent looks' screen-space noise fields into a quarter-scale
/// target, shared by both bloom-chain composites (see makeBloomChain).
///
/// Every noise field in those composites is a pure function of `uv` — there is no
/// time term anywhere in this pipeline — so each one was re-deriving the same
/// answer per pixel per frame: about fifty `hash21` evaluations for Metal and
/// thirty for Glow, at full resolution, for a pattern that never changes. Doing
/// it once per quarter-scale texel instead is the same picture for a sixteenth of
/// the arithmetic.
///
/// Quarter scale is safe because all three fields are far coarser than the target
/// resolves: the tightest of them, the sheen at 22 cycles across the frame, still
/// spans ~30 texels per cycle there, and value noise is smooth between lattice
/// points, so the bilinear upsample in the composite reconstructs it faithfully.
/// The grain deliberately stays in the composites — it is per-pixel by
/// definition, and it is only one hash each.
///
/// All three channels are stored raw in 0...1; the composites recentre them, and
/// each one is scaled down hard enough afterwards (the widest, the dispersion
/// angle, reaches a sub-pixel offset) that 8-bit quantisation is invisible.
///
/// `colorSampler` is bound for its dimensions alone, never sampled: the aspect
/// correction has to be computed from the full-resolution scene target so that
/// `wp` here matches `wp` in the composite exactly.
fragment half4 post_noise_fragment(PostVertexOut in [[stage_in]],
                                   texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    float2 texSize = float2(colorSampler.get_width(), colorSampler.get_height());
    float aspect = texSize.x / max(texSize.y, 1.0);
    float2 wp = float2(in.uv.x * aspect, in.uv.y);

    // The broad warp: a noise field bent by a second, coarser one.
    float broad = fbm(wp * 2.4 + fbm(wp * 1.1) * 1.5);
    // The fine sheen that carries the dice across palette bands, offset by the
    // broad field — computed here at full precision, before either is quantised.
    float sheen = valueNoise(wp * 22.0 + (broad - 0.5) * 3.0);
    // The field that bends the chromatic dispersion off pure radial.
    float angle = fbm(wp * 3.0);

    return half4(half(broad), half(sheen), half(angle), 1.0h);
}
