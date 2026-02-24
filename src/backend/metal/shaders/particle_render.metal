#include <metal_stdlib>
using namespace metal;

// ---- Shared particle types ----

struct Particle {
    float4 pos_lifetime;      // xyz = position, w = current lifetime
    float4 vel_max_lifetime;  // xyz = velocity, w = max lifetime
    float4 size_flags;        // x = start_size, y = end_size, z = flags, w = unused
    float4 color;             // rgba
};

// ---- Render uniforms ----

struct ParticleRenderUniforms {
    float4x4 view_proj;
    float4   cam_right;
    float4   cam_up;
};

// ---- Vertex output ----

struct ParticleVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// ---- Vertex Shader ----
// Generates billboard quad vertices from particle data.
// Each particle produces 6 vertices (2 triangles).
// vertex_id encodes both particle index and corner index.

vertex ParticleVertexOut particle_vertex(
    const device Particle*             particles   [[buffer(0)]],
    const device uint*                 alive_list  [[buffer(1)]],
    constant ParticleRenderUniforms&   uniforms    [[buffer(2)]],
    const device uint*                 counters    [[buffer(3)]],  // [alive_count, dead_count, emit_count]
    uint vid [[vertex_id]]
) {
    ParticleVertexOut out;

    // Determine which particle and which corner vertex
    uint particle_local_idx = vid / 6;
    uint corner = vid % 6;

    // Bounds check
    uint alive_count = counters[0];
    if (particle_local_idx >= alive_count) {
        out.position = float4(0.0, 0.0, 0.0, 1.0);
        out.color = float4(0.0);
        out.uv = float2(0.0);
        return out;
    }

    uint particle_idx = alive_list[particle_local_idx];
    Particle p = particles[particle_idx];

    // Interpolate size based on lifetime
    float t = p.pos_lifetime.w / max(p.vel_max_lifetime.w, 0.001);
    float size = mix(p.size_flags.x, p.size_flags.y, t);
    float half_size = size * 0.5;

    float3 center = p.pos_lifetime.xyz;
    float3 right = uniforms.cam_right.xyz * half_size;
    float3 up    = uniforms.cam_up.xyz * half_size;

    // Billboard quad corners
    // 0: bottom-left, 1: bottom-right, 2: top-right, 3: top-left
    // Triangle 1: 0, 1, 2    Triangle 2: 0, 2, 3
    float3 positions[4] = {
        center - right - up,  // 0: bottom-left
        center + right - up,  // 1: bottom-right
        center + right + up,  // 2: top-right
        center - right + up   // 3: top-left
    };

    float2 uvs[4] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };

    // Map corner index (0-5) to quad vertex index (0-3)
    const uint index_map[6] = {0, 1, 2, 0, 2, 3};
    uint qi = index_map[corner];

    out.position = uniforms.view_proj * float4(positions[qi], 1.0);
    out.color = p.color;
    out.color.a *= (1.0 - t); // Fade out over lifetime
    out.uv = uvs[qi];

    return out;
}

// ---- Fragment Shader ----

fragment float4 particle_fragment(ParticleVertexOut in [[stage_in]]) {
    // Soft circular falloff
    float2 center_offset = in.uv * 2.0 - 1.0;
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
