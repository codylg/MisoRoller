#ifndef PostProcess_h
#define PostProcess_h

#include <metal_stdlib>
using namespace metal;

/// Output of the shared fullscreen-quad vertex stage (`post_vertex`, defined in
/// PostProcess.metal). Every post-process fragment shader takes this as its
/// stage_in, so a new look only has to add a fragment function.
struct PostVertexOut {
    float4 position [[position]];
    float2 uv;
};

#endif /* PostProcess_h */
