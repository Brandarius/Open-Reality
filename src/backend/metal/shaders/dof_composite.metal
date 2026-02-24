#include <metal_stdlib>
using namespace metal;

// ---- Vertex Output ----

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ---- Fullscreen Quad Vertex Shader ----

vertex VertexOut dof_quad_vertex(
    const device float4* quad_data [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    float4 d = quad_data[vid];
    out.position = float4(d.xy, 0.0, 1.0);
    out.texCoord = d.zw;
    return out;
}

// ---- DOF Composite Fragment Shader ----
// Mixes the sharp (original) scene with the blurred DOF result based on the CoC value.
// Uses smoothstep for a perceptually smooth transition between focused and defocused regions.

fragment float4 dof_composite_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sharpTexture   [[texture(0)]],
    texture2d<float> blurredTexture [[texture(1)]],
    texture2d<float> cocTexture     [[texture(2)]],
    sampler samp [[sampler(0)]]
) {
    float4 sharp = sharpTexture.sample(samp, in.texCoord);
    float4 blurred = blurredTexture.sample(samp, in.texCoord);
    float coc = cocTexture.sample(samp, in.texCoord).r;

    // Smooth blend between sharp and blurred based on CoC
    float blend = smoothstep(0.0, 1.0, coc);
    float4 result = mix(sharp, blurred, blend);

    return result;
}
