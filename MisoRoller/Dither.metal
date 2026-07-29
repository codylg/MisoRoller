#include <metal_stdlib>
using namespace metal;
#include "PostProcess.h"

constant float bayer8x8[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,
    48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,
    60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,
    51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,
    63, 31, 55, 23, 61, 29, 53, 21
};

fragment half4 dither_fragment(PostVertexOut in [[stage_in]],
                               texture2d<float, access::sample> colorSampler [[texture(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::nearest);

    const float pixelSize = 3.0;
    float2 texSize = float2(colorSampler.get_width(), colorSampler.get_height());
    float2 cell = floor(in.uv * texSize / pixelSize);
    float2 uv = (cell + 0.5) * pixelSize / texSize;

    float3 c = colorSampler.sample(smp, uv).rgb;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    lum = pow(lum, 0.80);
    lum = clamp((lum - 0.5) * 1.06 + 0.5, 0.0, 1.0);

    int bx = int(fmod(cell.x, 8.0));
    int by = int(fmod(cell.y, 8.0));
    float threshold = (bayer8x8[by * 8 + bx] + 0.5) / 64.0;

    const float3 ink   = float3(0.043, 0.030, 0.020);
    const float3 paper = float3(1.000, 0.960, 0.870);   // warm tone, unchanged

    // >0.95 = the flat bright table base and the brightest die faces — kept clean.
    // Everything else (die shading, cast shadows, the vignette, and the sparse dots
    // baked into the floor texture) goes through the dither.
    float3 outc = (lum > 0.95) ? paper : ((lum > threshold) ? paper : ink);
    return half4(half3(outc), 1.0);
}
