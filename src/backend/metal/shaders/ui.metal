#include <metal_stdlib>
using namespace metal;

// ---- UI Uniforms ----

struct UIUniforms {
    float4x4 projection;
    int      has_texture;
    int      is_font;
    float    _pad1, _pad2;
};

// ---- Vertex Output ----

struct UIVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

// ---- Vertex Shader ----
// Interleaved: pos2 + uv2 + color4 = 8 floats per vertex

vertex UIVertexOut ui_vertex(uint vid [[vertex_id]],
                              const device float* vertices [[buffer(0)]],
                              constant UIUniforms& uniforms [[buffer(1)]]) {
    uint base = vid * 8;
    UIVertexOut out;
    float2 pos = float2(vertices[base], vertices[base + 1]);
    out.texCoord = float2(vertices[base + 2], vertices[base + 3]);
    out.color = float4(vertices[base + 4], vertices[base + 5], vertices[base + 6], vertices[base + 7]);
    out.position = uniforms.projection * float4(pos, 0.0, 1.0);
    return out;
}

// ---- Fragment Shader ----

fragment float4 ui_fragment(UIVertexOut in [[stage_in]],
                             constant UIUniforms& uniforms [[buffer(1)]],
                             texture2d<float> tex [[texture(0)]],
                             sampler samp [[sampler(0)]]) {
    float4 color = in.color;
    if (uniforms.has_texture != 0) {
        if (uniforms.is_font != 0) {
            // Font atlas: R channel as alpha
            float alpha = tex.sample(samp, in.texCoord).r;
            color.a *= alpha;
        } else {
            color *= tex.sample(samp, in.texCoord);
        }
    }
    return color;
}
