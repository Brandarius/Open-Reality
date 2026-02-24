#include <metal_stdlib>
using namespace metal;

// ---- Motion Blur Uniforms ----

struct MotionBlurUniforms {
    float4x4 inv_view_proj;
    float4x4 prev_view_proj;
    float    max_velocity;
    int      num_samples;
    float    intensity;
    float    screen_width;
};

// ---- Vertex Output ----

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// ---- Fullscreen Quad Vertex Shader ----

vertex VertexOut mb_quad_vertex(
    const device float4* quad_data [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    float4 d = quad_data[vid];
    out.position = float4(d.xy, 0.0, 1.0);
    out.texCoord = d.zw;
    return out;
}

// ---- Velocity Buffer Fragment Shader ----
// Reconstructs world position from depth + inverse view-projection,
// projects to previous frame via prev_view_proj, and outputs per-pixel
// screen-space velocity (current_uv - prev_uv), clamped by max_velocity.
//
// Metal NDC depth is [0,1] (not [-1,1] like OpenGL), so clip space
// construction uses depth directly without the * 2 - 1 remap.

fragment float4 mb_velocity_fragment(
    VertexOut in [[stage_in]],
    constant MotionBlurUniforms& uniforms [[buffer(1)]],
    texture2d<float> depthTexture [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float depth = depthTexture.sample(samp, in.texCoord).r;

    // Sky / far plane: no motion
    if (depth >= 1.0) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    // Reconstruct clip-space position from UV + depth
    // Metal NDC: x,y in [-1,1], z in [0,1]
    float2 ndc = in.texCoord * 2.0 - 1.0;
    float4 clipPos = float4(ndc.x, ndc.y, depth, 1.0);

    // World-space position via inverse view-projection
    float4 worldPos = uniforms.inv_view_proj * clipPos;
    worldPos /= worldPos.w;

    // Reproject to previous frame's clip space
    float4 prevClip = uniforms.prev_view_proj * worldPos;
    prevClip /= prevClip.w;

    // Previous UV (NDC -> [0,1])
    float2 prevUV = prevClip.xy * 0.5 + 0.5;

    // Velocity = current UV - previous UV
    float2 velocity = in.texCoord - prevUV;

    // Clamp velocity magnitude by max_velocity (in pixels, normalized to UV space)
    float maxVel = uniforms.max_velocity / uniforms.screen_width;
    float velMag = length(velocity);
    if (velMag > maxVel) {
        velocity = normalize(velocity) * maxVel;
    }

    return float4(velocity, 0.0, 1.0);
}
