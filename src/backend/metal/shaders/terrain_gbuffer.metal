#include <metal_stdlib>
using namespace metal;

// ---- Terrain Uniforms ----

struct TerrainUniforms {
    float4x4 view_proj;
    float4   camera_pos;
    float4   chunk_offset;      // world offset (x, 0, z, 0)
    float4   terrain_size;      // width, height, depth, tile_scale
    int      num_layers;
    float    _pad1, _pad2, _pad3;
};

// ---- G-Buffer Output ----

struct GBufferOut {
    half4 albedo_metallic    [[color(0)]];
    half4 normal_roughness   [[color(1)]];
    half4 emissive_ao        [[color(2)]];
    half4 advanced_material  [[color(3)]];
};

// ---- Vertex Output ----

struct TerrainVertexOut {
    float4 position [[position]];
    float3 world_pos;
    float3 normal;
    float2 texCoord;
};

// ---- Vertex Shader ----

vertex TerrainVertexOut terrain_vertex(
    const device packed_float3* positions [[buffer(0)]],
    const device packed_float3* normals   [[buffer(1)]],
    const device packed_float2* uvs       [[buffer(2)]],
    constant TerrainUniforms&   uniforms  [[buffer(3)]],
    uint vid [[vertex_id]]
) {
    TerrainVertexOut out;

    float3 pos = positions[vid];
    float3 world_pos = pos + uniforms.chunk_offset.xyz;
    out.position  = uniforms.view_proj * float4(world_pos, 1.0);
    out.world_pos = world_pos;
    out.normal    = normalize(float3(normals[vid]));
    out.texCoord  = float2(uvs[vid]);

    return out;
}

// ---- Fragment Shader ----

fragment GBufferOut terrain_fragment(
    TerrainVertexOut in [[stage_in]],
    constant TerrainUniforms& uniforms [[buffer(3)]],
    texture2d<float> splatmap          [[texture(0)]],
    texture2d<float> layer0_albedo     [[texture(1)]],
    texture2d<float> layer1_albedo     [[texture(2)]],
    texture2d<float> layer2_albedo     [[texture(3)]],
    texture2d<float> layer3_albedo     [[texture(4)]],
    sampler texSampler                 [[sampler(0)]]
) {
    GBufferOut out;

    // Sample splatmap blend weights (RGBA = 4 layer weights)
    float4 weights = splatmap.sample(texSampler, in.texCoord);

    // Tiled UVs for detail textures based on world XZ position
    float tile_scale = uniforms.terrain_size.w;
    float2 tiled_uv = in.world_pos.xz * tile_scale;

    // Sample each layer albedo texture with tiled coordinates
    float3 color0 = layer0_albedo.sample(texSampler, tiled_uv).rgb;
    float3 color1 = layer1_albedo.sample(texSampler, tiled_uv).rgb;
    float3 color2 = layer2_albedo.sample(texSampler, tiled_uv).rgb;
    float3 color3 = layer3_albedo.sample(texSampler, tiled_uv).rgb;

    // Blend layers using splatmap weights
    float3 albedo = float3(0.0);
    float total_weight = weights.r + weights.g + weights.b + weights.a;

    if (total_weight > 0.001) {
        albedo = (color0 * weights.r + color1 * weights.g +
                  color2 * weights.b + color3 * weights.a) / total_weight;
    } else {
        albedo = color0; // fallback to first layer
    }

    // Terrain normal (from vertex interpolation)
    float3 N = normalize(in.normal);

    // Pack G-Buffer outputs
    // Terrain: metallic=0, roughness=0.9, ao=1.0, no emissive, no clearcoat/subsurface
    out.albedo_metallic   = half4(half3(albedo), half(0.0));
    out.normal_roughness  = half4(half3(N * 0.5 + 0.5), half(0.9));
    out.emissive_ao       = half4(half3(0.0), half(1.0));
    out.advanced_material = half4(half(0.0), half(0.0), half(0.0), half(0.0));

    return out;
}
