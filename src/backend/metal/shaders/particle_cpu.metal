#include <metal_stdlib>
using namespace metal;

// ---- CPU Particle Render Uniforms ----

struct CPUParticleUniforms {
    float4x4 view_proj;
    float4   cam_right;
    float4   cam_up;
};

// ---- Vertex Output ----

struct CPUParticleVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

// ---- Vertex Shader ----
// Reads interleaved vertex data: pos3 + uv2 + color4 = 9 floats per vertex

vertex CPUParticleVertexOut cpu_particle_vertex(
    uint vid [[vertex_id]],
    const device float* vertices [[buffer(0)]],
    constant CPUParticleUniforms& uniforms [[buffer(1)]]
) {
    CPUParticleVertexOut out;

    uint base = vid * 9;
    float3 pos = float3(vertices[base], vertices[base + 1], vertices[base + 2]);
    out.texCoord = float2(vertices[base + 3], vertices[base + 4]);
    out.color = float4(vertices[base + 5], vertices[base + 6], vertices[base + 7], vertices[base + 8]);

    out.position = uniforms.view_proj * float4(pos, 1.0);

    return out;
}

// ---- Fragment Shader ----

fragment float4 cpu_particle_fragment(CPUParticleVertexOut in [[stage_in]]) {
    // Soft circular falloff
    float2 center_offset = in.texCoord * 2.0 - 1.0;
    float dist = length(center_offset);
    float alpha = 1.0 - smoothstep(0.0, 1.0, dist);

    float4 color = in.color;
    color.a *= alpha;

    // Discard fully transparent fragments
    if (color.a < 0.001) {
        discard_fragment();
    }

    return color;
}
