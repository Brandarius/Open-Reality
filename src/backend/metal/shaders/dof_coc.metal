#include <metal_stdlib>
using namespace metal;

// ---- DOF Uniforms ----

struct DOFUniforms {
    float focus_distance;
    float focus_range;
    float bokeh_radius;
    int   horizontal;
    float near_plane;
    float far_plane;
    float _pad1;
    float _pad2;
};

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

// ---- Depth Linearization ----
// Metal depth is [0,1] (reverse-Z or standard), not [-1,1] like OpenGL.

float linearize_depth(float d, float near, float far) {
    return near * far / (far - d * (far - near));
}

// ---- CoC Fragment Shader ----
// Computes Circle of Confusion from the depth buffer.
// Output: single float CoC value in [0,1].

fragment float dof_coc_fragment(
    VertexOut in [[stage_in]],
    constant DOFUniforms& uniforms [[buffer(1)]],
    texture2d<float> depthTexture [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float depth = depthTexture.sample(samp, in.texCoord).r;

    // Sky / far plane: no blur
    if (depth >= 1.0) {
        return 0.0;
    }

    float linearDepth = linearize_depth(depth, uniforms.near_plane, uniforms.far_plane);
    float coc = clamp(abs(linearDepth - uniforms.focus_distance) / uniforms.focus_range, 0.0, 1.0);
    return coc;
}
