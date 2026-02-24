#include <metal_stdlib>
using namespace metal;

// Feature flags (defined by shader permutation system)
// #define FEATURE_ALBEDO_MAP
// #define FEATURE_NORMAL_MAP
// #define FEATURE_METALLIC_ROUGHNESS_MAP
// #define FEATURE_AO_MAP
// #define FEATURE_EMISSIVE_MAP
// #define FEATURE_ALPHA_CUTOFF
// #define FEATURE_CLEARCOAT
// #define FEATURE_PARALLAX_MAPPING
// #define FEATURE_SUBSURFACE

struct PerFrameUniforms {
    float4x4 view;
    float4x4 projection;
    float4x4 inv_view_proj;
    float4   camera_pos;
    float    time;
    float    _pad1, _pad2, _pad3;
};

struct PerObjectUniforms {
    float4x4 model;
    float4   normal_matrix_col0;
    float4   normal_matrix_col1;
    float4   normal_matrix_col2;
};

struct MaterialUniforms {
    float4 albedo;
    float  metallic;
    float  roughness;
    float  ao;
    float  alpha_cutoff;
    float4 emissive_factor;
    float  clearcoat;
    float  clearcoat_roughness;
    float  subsurface;
    float  parallax_scale;
    int    has_albedo_map;
    int    has_normal_map;
    int    has_metallic_roughness_map;
    int    has_ao_map;
    int    has_emissive_map;
    int    has_height_map;
    int    _pad1, _pad2;
};

// Per-instance data: model matrix + normal matrix columns (packed as float4)
struct InstanceData {
    float4x4 model;
    float4   normal_col0;
    float4   normal_col1;
    float4   normal_col2;
};

struct GBufferVertexOut {
    float4 position [[position]];
    float3 world_pos;
    float3 normal;
    float2 texCoord;
};

struct GBufferOut {
    half4 albedo_metallic    [[color(0)]];
    half4 normal_roughness   [[color(1)]];
    half4 emissive_ao        [[color(2)]];
    half4 advanced_material  [[color(3)]];
};

// ---- Instanced Vertex Shader ----

vertex GBufferVertexOut gbuffer_vertex_instanced(
    const device packed_float3* positions  [[buffer(0)]],
    const device packed_float3* normals    [[buffer(1)]],
    const device packed_float2* uvs        [[buffer(2)]],
    constant PerFrameUniforms&  frame      [[buffer(3)]],
    constant PerObjectUniforms& object     [[buffer(4)]],
    const device InstanceData*  instances  [[buffer(5)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    GBufferVertexOut out;
    float3 pos = positions[vid];

    // Use per-instance model matrix instead of per-object
    float4x4 instanceModel = instances[iid].model;
    float4 worldPos = instanceModel * float4(pos, 1.0);
    out.position  = frame.projection * frame.view * worldPos;
    out.world_pos = worldPos.xyz;

    // Build normal matrix from per-instance columns
    float3 n = normals[vid];
    float3x3 normalMatrix = float3x3(
        instances[iid].normal_col0.xyz,
        instances[iid].normal_col1.xyz,
        instances[iid].normal_col2.xyz
    );
    out.normal = normalize(normalMatrix * n);
    out.texCoord = uvs[vid];
    return out;
}

// ---- Parallax Occlusion Mapping ----

#ifdef FEATURE_PARALLAX_MAPPING
float2 parallaxOcclusionMapping(float2 texCoords, float3 viewDirTangent, float parallaxScale,
                                 texture2d<float> heightMap, sampler samp) {
    const float minLayers = 8.0;
    const float maxLayers = 32.0;
    float numLayers = mix(maxLayers, minLayers, abs(dot(float3(0.0, 0.0, 1.0), viewDirTangent)));

    float layerDepth = 1.0 / numLayers;
    float currentLayerDepth = 0.0;
    float2 P = viewDirTangent.xy / viewDirTangent.z * parallaxScale;
    float2 deltaTexCoords = P / numLayers;

    float2 currentTexCoords = texCoords;
    float currentDepthMapValue = heightMap.sample(samp, currentTexCoords).r;

    for (int i = 0; i < 32; ++i) {
        if (currentLayerDepth >= currentDepthMapValue) break;
        currentTexCoords -= deltaTexCoords;
        currentDepthMapValue = heightMap.sample(samp, currentTexCoords).r;
        currentLayerDepth += layerDepth;
    }

    float2 prevTexCoords = currentTexCoords + deltaTexCoords;
    float afterDepth = currentDepthMapValue - currentLayerDepth;
    float beforeDepth = heightMap.sample(samp, prevTexCoords).r - currentLayerDepth + layerDepth;
    float weight = afterDepth / (afterDepth - beforeDepth);

    return mix(currentTexCoords, prevTexCoords, weight);
}
#endif

// ---- Fragment Shader (identical to gbuffer.metal) ----

fragment GBufferOut gbuffer_fragment_instanced(
    GBufferVertexOut in [[stage_in]],
    constant PerFrameUniforms&  frame    [[buffer(3)]],
    constant MaterialUniforms&  material [[buffer(5)]],
    texture2d<float> albedoMap           [[texture(0)]],
    texture2d<float> normalMap           [[texture(1)]],
    texture2d<float> metallicRoughMap    [[texture(2)]],
    texture2d<float> aoMap               [[texture(3)]],
    texture2d<float> emissiveMap         [[texture(4)]],
    texture2d<float> heightMap           [[texture(5)]],
    sampler texSampler                   [[sampler(0)]]
) {
    GBufferOut out;

    float2 texCoord = in.texCoord;

    // Parallax Occlusion Mapping
#ifdef FEATURE_PARALLAX_MAPPING
    if (material.has_height_map) {
        float3 dp1 = dfdx(in.world_pos);
        float3 dp2 = dfdy(in.world_pos);
        float2 duv1 = dfdx(in.texCoord);
        float2 duv2 = dfdy(in.texCoord);

        float3 N = normalize(in.normal);
        float3 T = normalize(dp1 * duv2.y - dp2 * duv1.y);
        float3 B = -normalize(cross(N, T));
        float3x3 TBN = float3x3(T, B, N);

        float3 viewDir = normalize(frame.camera_pos.xyz - in.world_pos);
        float3 viewDirTangent = normalize(transpose(TBN) * viewDir);

        texCoord = parallaxOcclusionMapping(in.texCoord, viewDirTangent, material.parallax_scale, heightMap, texSampler);

        if (texCoord.x > 1.0 || texCoord.y > 1.0 || texCoord.x < 0.0 || texCoord.y < 0.0)
            discard_fragment();
    }
#endif

    // Albedo
    float3 albedo = material.albedo.rgb;
    float alpha = material.albedo.a;

#ifdef FEATURE_ALBEDO_MAP
    if (material.has_albedo_map) {
        float4 albedoSample = albedoMap.sample(texSampler, texCoord);
        albedo = pow(albedoSample.rgb, float3(2.2));  // sRGB to linear
        alpha = material.albedo.a * albedoSample.a;
    }
#endif

#ifdef FEATURE_ALPHA_CUTOFF
    if (alpha < material.alpha_cutoff)
        discard_fragment();
#endif

    // Metallic / Roughness
    float metallic = material.metallic;
    float roughness = material.roughness;

#ifdef FEATURE_METALLIC_ROUGHNESS_MAP
    if (material.has_metallic_roughness_map) {
        float4 mr = metallicRoughMap.sample(texSampler, texCoord);
        metallic = mr.b;
        roughness = mr.g;
    }
#endif

    // AO
    float ao = material.ao;

#ifdef FEATURE_AO_MAP
    if (material.has_ao_map) {
        ao = aoMap.sample(texSampler, texCoord).r;
    }
#endif

    // Emissive
    float3 emissive = material.emissive_factor.rgb;

#ifdef FEATURE_EMISSIVE_MAP
    if (material.has_emissive_map) {
        emissive *= emissiveMap.sample(texSampler, texCoord).rgb;
    }
#endif

    // Normal
    float3 N = normalize(in.normal);

#ifdef FEATURE_NORMAL_MAP
    if (material.has_normal_map) {
        float3 tangentNormal = normalMap.sample(texSampler, texCoord).xyz * 2.0 - 1.0;
        float3 dp1 = dfdx(in.world_pos);
        float3 dp2 = dfdy(in.world_pos);
        float2 duv1 = dfdx(in.texCoord);
        float2 duv2 = dfdy(in.texCoord);
        float3 T = normalize(dp1 * duv2.y - dp2 * duv1.y);
        float3 B = -normalize(cross(N, T));
        float3x3 TBN = float3x3(T, B, N);
        N = normalize(TBN * tangentNormal);
    }
#endif

    // Advanced material
    float cc = 0.0;
    float ccRough = 0.0;
    float sss = 0.0;

#ifdef FEATURE_CLEARCOAT
    cc = material.clearcoat;
    ccRough = material.clearcoat_roughness;
#endif

#ifdef FEATURE_SUBSURFACE
    sss = material.subsurface;
#endif

    // Pack G-Buffer outputs
    out.albedo_metallic   = half4(half3(albedo), half(metallic));
    out.normal_roughness  = half4(half3(N * 0.5 + 0.5), half(roughness));
    out.emissive_ao       = half4(half3(emissive), half(ao));
    out.advanced_material = half4(half(cc), half(ccRough), half(sss), half(0.0));

    return out;
}
