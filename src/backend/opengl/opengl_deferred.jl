# OpenGL deferred rendering implementation

# =============================================================================
# G-Buffer Geometry Pass Shaders
# =============================================================================

const GBUFFER_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec3 a_Normal;
layout(location = 2) in vec2 a_TexCoord;
layout(location = 3) in vec4 a_BoneWeights;
layout(location = 4) in uvec4 a_BoneIndices;

// Instanced rendering: per-instance model and normal matrices
#ifdef FEATURE_INSTANCED
layout(location = 5) in vec4 a_InstanceModelCol0;
layout(location = 6) in vec4 a_InstanceModelCol1;
layout(location = 7) in vec4 a_InstanceModelCol2;
layout(location = 8) in vec4 a_InstanceModelCol3;
layout(location = 9) in vec3 a_InstanceNormalCol0;
layout(location = 10) in vec3 a_InstanceNormalCol1;
layout(location = 11) in vec3 a_InstanceNormalCol2;
#endif

#define MAX_BONES 128
uniform mat4 u_BoneMatrices[MAX_BONES];
uniform int u_HasSkinning;

uniform mat4 u_Model;
uniform mat4 u_View;
uniform mat4 u_Projection;
uniform mat3 u_NormalMatrix;
uniform vec3 u_CameraPos;

out vec3 v_WorldPos;
out vec3 v_Normal;
out vec2 v_TexCoord;

void main()
{
    // Select model/normal matrix: instanced or uniform
#ifdef FEATURE_INSTANCED
    mat4 modelMatrix = mat4(a_InstanceModelCol0, a_InstanceModelCol1, a_InstanceModelCol2, a_InstanceModelCol3);
    mat3 normalMatrix = mat3(a_InstanceNormalCol0, a_InstanceNormalCol1, a_InstanceNormalCol2);
#else
    mat4 modelMatrix = u_Model;
    mat3 normalMatrix = u_NormalMatrix;
#endif

    vec3 localPos = a_Position;
    vec3 localNormal = a_Normal;

    if (u_HasSkinning == 1) {
        mat4 skin = u_BoneMatrices[a_BoneIndices.x] * a_BoneWeights.x
                  + u_BoneMatrices[a_BoneIndices.y] * a_BoneWeights.y
                  + u_BoneMatrices[a_BoneIndices.z] * a_BoneWeights.z
                  + u_BoneMatrices[a_BoneIndices.w] * a_BoneWeights.w;
        localPos = (skin * vec4(a_Position, 1.0)).xyz;
        localNormal = mat3(skin) * a_Normal;
    }

    vec4 worldPos = modelMatrix * vec4(localPos, 1.0);
    v_WorldPos = worldPos.xyz;
    v_Normal = normalize(normalMatrix * localNormal);
    v_TexCoord = a_TexCoord;
    gl_Position = u_Projection * u_View * worldPos;
}
"""

const GBUFFER_FRAGMENT_SHADER = """
#version 330 core

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
// #define FEATURE_LOD_DITHER

in vec3 v_WorldPos;
in vec3 v_Normal;
in vec2 v_TexCoord;

// G-Buffer outputs (MRT)
layout(location = 0) out vec4 gAlbedoMetallic;
layout(location = 1) out vec4 gNormalRoughness;
layout(location = 2) out vec4 gEmissiveAO;
layout(location = 3) out vec4 gAdvancedMaterial;

// Material uniforms
uniform vec3 u_Albedo;
uniform float u_Metallic;
uniform float u_Roughness;
uniform float u_AO;
uniform vec3 u_EmissiveFactor;
uniform float u_Opacity;
uniform float u_AlphaCutoff;
uniform vec3 u_CameraPos;

// Texture maps
#ifdef FEATURE_ALBEDO_MAP
uniform sampler2D u_AlbedoMap;
#endif

#ifdef FEATURE_NORMAL_MAP
uniform sampler2D u_NormalMap;
#endif

#ifdef FEATURE_METALLIC_ROUGHNESS_MAP
uniform sampler2D u_MetallicRoughnessMap;
#endif

#ifdef FEATURE_AO_MAP
uniform sampler2D u_AOMap;
#endif

#ifdef FEATURE_EMISSIVE_MAP
uniform sampler2D u_EmissiveMap;
#endif

// Advanced material uniforms
#ifdef FEATURE_CLEARCOAT
uniform float u_Clearcoat;
uniform float u_ClearcoatRoughness;
#endif

#ifdef FEATURE_PARALLAX_MAPPING
uniform sampler2D u_HeightMap;
uniform float u_ParallaxScale;
#endif

#ifdef FEATURE_SUBSURFACE
uniform float u_Subsurface;
#endif

#ifdef FEATURE_LOD_DITHER
uniform float u_LODAlpha;
#endif

// Parallax Occlusion Mapping
#ifdef FEATURE_PARALLAX_MAPPING
vec2 parallaxOcclusionMapping(vec2 texCoords, vec3 viewDirTangent)
{
    // Adaptive layer count based on viewing angle
    const float minLayers = 8.0;
    const float maxLayers = 32.0;
    float numLayers = mix(maxLayers, minLayers, abs(dot(vec3(0.0, 0.0, 1.0), viewDirTangent)));

    float layerDepth = 1.0 / numLayers;
    float currentLayerDepth = 0.0;
    vec2 P = viewDirTangent.xy / viewDirTangent.z * u_ParallaxScale;
    vec2 deltaTexCoords = P / numLayers;

    vec2 currentTexCoords = texCoords;
    float currentDepthMapValue = texture(u_HeightMap, currentTexCoords).r;

    // Ray march through height map
    for (int i = 0; i < 32; ++i)
    {
        if (currentLayerDepth >= currentDepthMapValue) break;
        currentTexCoords -= deltaTexCoords;
        currentDepthMapValue = texture(u_HeightMap, currentTexCoords).r;
        currentLayerDepth += layerDepth;
    }

    // Relief mapping interpolation for smoother result
    vec2 prevTexCoords = currentTexCoords + deltaTexCoords;
    float afterDepth = currentDepthMapValue - currentLayerDepth;
    float beforeDepth = texture(u_HeightMap, prevTexCoords).r - currentLayerDepth + layerDepth;
    float weight = afterDepth / (afterDepth - beforeDepth);

    return mix(currentTexCoords, prevTexCoords, weight);
}
#endif

// Normal mapping via screen-space derivatives (uses texCoord parameter)
vec3 getNormalFromMap(vec2 texCoord)
{
#ifdef FEATURE_NORMAL_MAP
    vec3 tangentNormal = texture(u_NormalMap, texCoord).xyz * 2.0 - 1.0;

    vec3 Q1  = dFdx(v_WorldPos);
    vec3 Q2  = dFdy(v_WorldPos);
    vec2 st1 = dFdx(v_TexCoord);
    vec2 st2 = dFdy(v_TexCoord);

    vec3 N   = normalize(v_Normal);
    vec3 T   = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B   = -normalize(cross(N, T));
    mat3 TBN = mat3(T, B, N);

    return normalize(TBN * tangentNormal);
#else
    return normalize(v_Normal);
#endif
}

void main()
{
    // Compute texture coordinates (may be displaced by POM)
    vec2 texCoord = v_TexCoord;

#ifdef FEATURE_PARALLAX_MAPPING
    // Compute TBN from screen-space derivatives for POM view direction
    vec3 Q1  = dFdx(v_WorldPos);
    vec3 Q2  = dFdy(v_WorldPos);
    vec2 st1 = dFdx(v_TexCoord);
    vec2 st2 = dFdy(v_TexCoord);

    vec3 N   = normalize(v_Normal);
    vec3 T   = normalize(Q1 * st2.t - Q2 * st1.t);
    vec3 B   = -normalize(cross(N, T));
    mat3 TBN = mat3(T, B, N);

    vec3 viewDir = normalize(u_CameraPos - v_WorldPos);
    vec3 viewDirTangent = normalize(transpose(TBN) * viewDir);

    texCoord = parallaxOcclusionMapping(v_TexCoord, viewDirTangent);

    // Discard if UV goes out of range (prevents edge artifacts)
    if (texCoord.x > 1.0 || texCoord.y > 1.0 || texCoord.x < 0.0 || texCoord.y < 0.0)
        discard;
#endif

    // Sample albedo
    vec3 albedo = u_Albedo;
    float alpha = u_Opacity;

#ifdef FEATURE_ALBEDO_MAP
    vec4 albedoSample = texture(u_AlbedoMap, texCoord);
    albedo = pow(albedoSample.rgb, vec3(2.2)); // sRGB to linear
    alpha = u_Opacity * albedoSample.a;
#endif

#ifdef FEATURE_ALPHA_CUTOFF
    if (alpha < u_AlphaCutoff)
        discard;
#endif

#ifdef FEATURE_LOD_DITHER
    // LOD dither crossfade: Bayer 4x4 ordered dithering
    // u_LODAlpha = 1.0 means fully opaque for this LOD level,
    // values < 1.0 progressively discard more fragments via dither pattern
    {
        const float bayerMatrix[16] = float[16](
             0.0/16.0,  8.0/16.0,  2.0/16.0, 10.0/16.0,
            12.0/16.0,  4.0/16.0, 14.0/16.0,  6.0/16.0,
             3.0/16.0, 11.0/16.0,  1.0/16.0,  9.0/16.0,
            15.0/16.0,  7.0/16.0, 13.0/16.0,  5.0/16.0
        );
        int bx = int(mod(gl_FragCoord.x, 4.0));
        int by = int(mod(gl_FragCoord.y, 4.0));
        float threshold = bayerMatrix[by * 4 + bx];
        if (u_LODAlpha < threshold)
            discard;
    }
#endif

    // Sample metallic and roughness
    float metallic = u_Metallic;
    float roughness = u_Roughness;

#ifdef FEATURE_METALLIC_ROUGHNESS_MAP
    vec4 mr = texture(u_MetallicRoughnessMap, texCoord);
    metallic = mr.b;  // Blue channel = metallic
    roughness = mr.g; // Green channel = roughness
#endif

    // Sample AO
    float ao = u_AO;

#ifdef FEATURE_AO_MAP
    ao = texture(u_AOMap, texCoord).r;
#endif

    // Sample emissive
    vec3 emissive = u_EmissiveFactor;

#ifdef FEATURE_EMISSIVE_MAP
    emissive = texture(u_EmissiveMap, texCoord).rgb * u_EmissiveFactor;
#endif

    // Get world-space normal (with normal mapping if available)
    vec3 normal = getNormalFromMap(texCoord);

    // Write to G-Buffer
    // Pack normal from [-1, 1] to [0, 1] for storage
    gAlbedoMetallic = vec4(albedo, metallic);
    gNormalRoughness = vec4(normal * 0.5 + 0.5, roughness);
    gEmissiveAO = vec4(emissive, ao);

    // Write advanced material data to MRT 3
    // R = clearcoat, G = clearcoat_roughness, B = subsurface, A = reserved
    float cc = 0.0;
    float ccRough = 0.0;
    float sss = 0.0;

#ifdef FEATURE_CLEARCOAT
    cc = u_Clearcoat;
    ccRough = u_ClearcoatRoughness;
#endif

#ifdef FEATURE_SUBSURFACE
    sss = u_Subsurface;
#endif

    gAdvancedMaterial = vec4(cc, ccRough, sss, 0.0);
}
"""

# =============================================================================
# Deferred Lighting Pass Shaders
# =============================================================================

const DEFERRED_LIGHTING_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec2 a_Position;
layout(location = 1) in vec2 a_TexCoord;

out vec2 v_TexCoord;

void main()
{
    v_TexCoord = a_TexCoord;
    gl_Position = vec4(a_Position, 0.0, 1.0);
}
"""

const DEFERRED_LIGHTING_FRAGMENT_SHADER = """
#version 330 core

#define MAX_POINT_LIGHTS 16
#define MAX_DIR_LIGHTS 8
#define MAX_SPOT_LIGHTS 16

in vec2 v_TexCoord;
out vec4 FragColor;

// G-Buffer textures
uniform sampler2D gAlbedoMetallic;
uniform sampler2D gNormalRoughness;
uniform sampler2D gEmissiveAO;
uniform sampler2D gDepth;
uniform sampler2D gAdvancedMaterial;

// Subsurface scattering global parameters
uniform vec3 u_SubsurfaceColor;

// Camera
uniform vec3 u_CameraPos;
uniform mat4 u_InvViewProj;

// Point lights
uniform int u_NumPointLights;
uniform vec3 u_PointLightPositions[MAX_POINT_LIGHTS];
uniform vec3 u_PointLightColors[MAX_POINT_LIGHTS];
uniform float u_PointLightIntensities[MAX_POINT_LIGHTS];
uniform float u_PointLightRanges[MAX_POINT_LIGHTS];

// Directional lights
uniform int u_NumDirLights;
uniform vec3 u_DirLightDirections[MAX_DIR_LIGHTS];
uniform vec3 u_DirLightColors[MAX_DIR_LIGHTS];
uniform float u_DirLightIntensities[MAX_DIR_LIGHTS];

// Spot lights
uniform int u_NumSpotLights;
uniform vec3 u_SpotLightPositions[MAX_SPOT_LIGHTS];
uniform vec3 u_SpotLightDirections[MAX_SPOT_LIGHTS];
uniform vec3 u_SpotLightColors[MAX_SPOT_LIGHTS];
uniform float u_SpotLightIntensities[MAX_SPOT_LIGHTS];
uniform float u_SpotLightRanges[MAX_SPOT_LIGHTS];
uniform float u_SpotLightInnerCos[MAX_SPOT_LIGHTS];  // cos(inner_cone)
uniform float u_SpotLightOuterCos[MAX_SPOT_LIGHTS];  // cos(outer_cone)

// Cascaded Shadow Mapping (CSM)
#define MAX_CASCADES 4
uniform sampler2D u_CascadeShadowMaps[MAX_CASCADES];
uniform mat4 u_CascadeMatrices[MAX_CASCADES];
uniform float u_CascadeSplits[MAX_CASCADES + 1];
uniform int u_NumCascades;
uniform int u_HasShadows;

// Spot light shadow maps (max 4 shadow-casting spot lights)
#define MAX_SPOT_SHADOW_MAPS 4
uniform sampler2D u_SpotShadowMaps[MAX_SPOT_SHADOW_MAPS];
uniform mat4 u_SpotShadowMatrices[MAX_SPOT_SHADOW_MAPS];
uniform int u_SpotShadowIndices[MAX_SPOT_LIGHTS];  // Maps spot light index -> shadow map index (-1 = no shadow)
uniform int u_NumSpotShadowMaps;

// Point light shadow cubemaps (max 4 shadow-casting point lights)
#define MAX_POINT_SHADOW_MAPS 4
uniform samplerCube u_PointShadowMaps[MAX_POINT_SHADOW_MAPS];
uniform float u_PointShadowFarPlanes[MAX_POINT_SHADOW_MAPS];
uniform int u_PointShadowIndices[MAX_POINT_LIGHTS];  // Maps point light index -> shadow map index (-1 = no shadow)
uniform int u_NumPointShadowMaps;

// Fog
uniform int u_FogEnabled;
uniform int u_FogMode;           // 0 = linear, 1 = exponential, 2 = exponential squared
uniform vec3 u_FogColor;
uniform float u_FogDensity;
uniform float u_FogStart;
uniform float u_FogEnd;
uniform int u_FogHeightEnabled;
uniform float u_FogHeightFalloff;
uniform float u_FogHeightOffset;

// Image-Based Lighting (IBL)
uniform samplerCube u_IrradianceMap;
uniform samplerCube u_PrefilterMap;
uniform sampler2D u_BRDFLUT;
uniform float u_IBLIntensity;
uniform int u_HasIBL;

const float PI = 3.14159265359;

// Reconstruct world position from depth
vec3 reconstructWorldPos(vec2 texCoord, float depth)
{
    vec4 clipPos = vec4(texCoord * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 worldPos = u_InvViewProj * clipPos;
    return worldPos.xyz / worldPos.w;
}

// Normal Distribution Function: Trowbridge-Reitz GGX
float DistributionGGX(vec3 N, vec3 H, float roughness)
{
    float a  = roughness * roughness;
    float a2 = a * a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return a2 / max(denom, 0.0000001);
}

// Geometry Function: Schlick-GGX
float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

// Geometry Function: Smith's method
float GeometrySmith(vec3 N, vec3 V, vec3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

// Fresnel: Schlick approximation
vec3 FresnelSchlick(float cosTheta, vec3 F0)
{
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Fresnel-Schlick with roughness (for IBL)
vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness)
{
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

// Compute radiance contribution from a single light direction
vec3 computeRadiance(vec3 N, vec3 V, vec3 L, vec3 radiance,
                     vec3 albedo, float metallic, float roughness, vec3 F0)
{
    vec3 H = normalize(V + L);

    float NDF = DistributionGGX(N, H, roughness);
    float G   = GeometrySmith(N, V, L, roughness);
    vec3  F   = FresnelSchlick(max(dot(H, V), 0.0), F0);

    // Specular (Cook-Torrance)
    vec3 numerator    = NDF * G * F;
    float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0) + 0.0001;
    vec3 specular     = numerator / denominator;

    // Energy conservation
    vec3 kS = F;
    vec3 kD = vec3(1.0) - kS;
    kD *= 1.0 - metallic;

    float NdotL = max(dot(N, L), 0.0);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

// Shadow softness configuration
uniform float u_ShadowSoftness;     // PCF spread multiplier (default 1.0)
uniform int u_ShadowPCSSEnabled;    // 0 = PCF only, 1 = PCSS
uniform float u_ShadowLightSize;    // Light source size for PCSS penumbra (default 0.02)

// 16-sample Poisson disk for high-quality PCF
const vec2 poissonDisk[16] = vec2[16](
    vec2(-0.94201624, -0.39906216),  vec2( 0.94558609, -0.76890725),
    vec2(-0.09418410, -0.92938870),  vec2( 0.34495938,  0.29387760),
    vec2(-0.91588581,  0.45771432),  vec2(-0.81544232, -0.87912464),
    vec2(-0.38277543,  0.27676845),  vec2( 0.97484398,  0.75648379),
    vec2( 0.44323325, -0.97511554),  vec2( 0.53742981, -0.47373420),
    vec2(-0.26496911, -0.41893023),  vec2( 0.79197514,  0.19090188),
    vec2(-0.24188840,  0.99706507),  vec2(-0.81409955,  0.91437590),
    vec2( 0.19984126,  0.78641367),  vec2( 0.14383161, -0.14100790)
);

// PCSS blocker search: find average blocker depth
float findBlockerDepth(sampler2D shadowMap, vec2 uv, float receiverDepth, float bias, float searchRadius)
{
    float blockerSum = 0.0;
    int numBlockers = 0;

    for (int i = 0; i < 16; ++i)
    {
        float sampleDepth = texture(shadowMap, uv + poissonDisk[i] * searchRadius).r;
        if (sampleDepth < receiverDepth - bias)
        {
            blockerSum += sampleDepth;
            numBlockers++;
        }
    }

    if (numBlockers == 0)
        return -1.0;  // No blockers found

    return blockerSum / float(numBlockers);
}

// Helper function to compute shadow for a specific cascade
float computeShadowForCascade(vec3 worldPos, vec3 N, vec3 L, int cascadeIdx, sampler2D shadowMap, mat4 cascadeMatrix)
{
    vec4 fragPosLightSpace = cascadeMatrix * vec4(worldPos, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords = projCoords * 0.5 + 0.5;

    if (projCoords.z > 1.0 || projCoords.x < 0.0 || projCoords.x > 1.0 ||
        projCoords.y < 0.0 || projCoords.y > 1.0)
        return 0.0;

    float bias = max(0.005 * (1.0 - dot(N, L)), 0.001);
    bias *= 1.0 / (float(cascadeIdx + 1) * 0.5 + 1.0);

    vec2 texelSize = 1.0 / textureSize(shadowMap, 0);
    float filterRadius = u_ShadowSoftness * texelSize.x * 3.0;

    // PCSS: variable penumbra based on blocker distance
    if (u_ShadowPCSSEnabled == 1)
    {
        float searchRadius = u_ShadowLightSize * (projCoords.z - 0.01) / projCoords.z;
        float avgBlockerDepth = findBlockerDepth(shadowMap, projCoords.xy, projCoords.z, bias, searchRadius);

        if (avgBlockerDepth < 0.0)
            return 0.0;  // No blockers — fully lit

        // Penumbra size from similar triangles
        float penumbra = u_ShadowLightSize * (projCoords.z - avgBlockerDepth) / avgBlockerDepth;
        filterRadius = max(penumbra, texelSize.x);
    }

    // Poisson-disk PCF sampling
    float shadow = 0.0;
    for (int i = 0; i < 16; ++i)
    {
        float pcfDepth = texture(shadowMap, projCoords.xy + poissonDisk[i] * filterRadius).r;
        shadow += projCoords.z - bias > pcfDepth ? 1.0 : 0.0;
    }
    shadow /= 16.0;
    return shadow;
}

// Spot light shadow computation (helper with constant sampler)
float computeSpotShadowForMap(vec3 worldPos, vec3 N, vec3 L, int shadowIdx, sampler2D shadowMap)
{
    vec4 fragPosLightSpace = u_SpotShadowMatrices[shadowIdx] * vec4(worldPos, 1.0);
    vec3 projCoords = fragPosLightSpace.xyz / fragPosLightSpace.w;
    projCoords = projCoords * 0.5 + 0.5;

    if (projCoords.z > 1.0 || projCoords.x < 0.0 || projCoords.x > 1.0 ||
        projCoords.y < 0.0 || projCoords.y > 1.0)
        return 0.0;

    float bias = max(0.005 * (1.0 - dot(N, L)), 0.002);

    // Poisson-disk PCF for spot light shadows
    float shadow = 0.0;
    vec2 texelSize = 1.0 / textureSize(shadowMap, 0);
    float filterRadius = texelSize.x * 2.0;

    for (int i = 0; i < 16; ++i)
    {
        float d = texture(shadowMap, projCoords.xy + poissonDisk[i] * filterRadius).r;
        shadow += projCoords.z - bias > d ? 1.0 : 0.0;
    }
    shadow /= 16.0;
    return shadow;
}

float computeSpotShadow(vec3 worldPos, vec3 N, vec3 L, int shadowIdx)
{
    switch (shadowIdx)
    {
        case 0: return computeSpotShadowForMap(worldPos, N, L, 0, u_SpotShadowMaps[0]);
        case 1: return computeSpotShadowForMap(worldPos, N, L, 1, u_SpotShadowMaps[1]);
        case 2: return computeSpotShadowForMap(worldPos, N, L, 2, u_SpotShadowMaps[2]);
        case 3: return computeSpotShadowForMap(worldPos, N, L, 3, u_SpotShadowMaps[3]);
        default: return 0.0;
    }
}

// Point light shadow computation (cubemap, helper with constant sampler)
float computePointShadowForMap(vec3 worldPos, vec3 lightPos, int shadowIdx, samplerCube shadowMap)
{
    vec3 fragToLight = worldPos - lightPos;
    float currentDepth = length(fragToLight);
    float farPlane = u_PointShadowFarPlanes[shadowIdx];

    float bias = 0.05;

    // Simple PCF with offset samples for cubemap
    float shadow = 0.0;
    float offset = 0.02;
    int samples = 0;
    for (float x = -offset; x <= offset; x += offset)
    {
        for (float y = -offset; y <= offset; y += offset)
        {
            for (float z = -offset; z <= offset; z += offset)
            {
                float closestDepth = texture(shadowMap, fragToLight + vec3(x, y, z)).r;
                closestDepth *= farPlane;  // Map from [0,1] to [0,farPlane]
                shadow += currentDepth - bias > closestDepth ? 1.0 : 0.0;
                samples++;
            }
        }
    }
    shadow /= float(samples);
    return shadow;
}

float computePointShadow(vec3 worldPos, vec3 lightPos, int shadowIdx)
{
    switch (shadowIdx)
    {
        case 0: return computePointShadowForMap(worldPos, lightPos, 0, u_PointShadowMaps[0]);
        case 1: return computePointShadowForMap(worldPos, lightPos, 1, u_PointShadowMaps[1]);
        case 2: return computePointShadowForMap(worldPos, lightPos, 2, u_PointShadowMaps[2]);
        case 3: return computePointShadowForMap(worldPos, lightPos, 3, u_PointShadowMaps[3]);
        default: return 0.0;
    }
}

// Cascaded Shadow Map computation
float computeShadow(vec3 worldPos, vec3 N, vec3 L, float viewDepth)
{
    if (u_HasShadows == 0 || u_NumCascades == 0)
        return 0.0;

    int cascadeIndex = u_NumCascades - 1;
    for (int i = 0; i < u_NumCascades; ++i)
    {
        if (viewDepth < u_CascadeSplits[i + 1])
        {
            cascadeIndex = i;
            break;
        }
    }

    switch (cascadeIndex)
    {
        case 0: return computeShadowForCascade(worldPos, N, L, 0, u_CascadeShadowMaps[0], u_CascadeMatrices[0]);
        case 1: return computeShadowForCascade(worldPos, N, L, 1, u_CascadeShadowMaps[1], u_CascadeMatrices[1]);
        case 2: return computeShadowForCascade(worldPos, N, L, 2, u_CascadeShadowMaps[2], u_CascadeMatrices[2]);
        case 3: return computeShadowForCascade(worldPos, N, L, 3, u_CascadeShadowMaps[3], u_CascadeMatrices[3]);
        default: return 0.0;
    }
}

void main()
{
    // Sample G-Buffer
    vec4 albedoMetallic = texture(gAlbedoMetallic, v_TexCoord);
    vec4 normalRoughness = texture(gNormalRoughness, v_TexCoord);
    vec4 emissiveAO = texture(gEmissiveAO, v_TexCoord);
    float depth = texture(gDepth, v_TexCoord).r;

    if (depth >= 1.0)
    {
        FragColor = vec4(0.1, 0.1, 0.1, 1.0);
        return;
    }

    vec3 albedo = albedoMetallic.rgb;
    float metallic = albedoMetallic.a;
    vec3 normal = normalize(normalRoughness.rgb * 2.0 - 1.0);
    float roughness = normalRoughness.a;
    vec3 emissive = emissiveAO.rgb;
    float ao = emissiveAO.a;

    vec4 advMat = texture(gAdvancedMaterial, v_TexCoord);
    float clearcoat = advMat.r;
    float clearcoatRoughness = advMat.g;
    float subsurface = advMat.b;

    vec3 worldPos = reconstructWorldPos(v_TexCoord, depth);
    vec3 V = normalize(u_CameraPos - worldPos);

    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo, metallic);

    vec3 Lo = vec3(0.0);
    vec3 ccLo = vec3(0.0);
    vec3 sssLo = vec3(0.0);

    // Point lights
    for (int i = 0; i < u_NumPointLights; ++i)
    {
        vec3 L = u_PointLightPositions[i] - worldPos;
        float dist = length(L);
        L = normalize(L);

        float attenuation = 1.0 / (dist * dist);
        float rangeFactor = clamp(1.0 - pow(dist / u_PointLightRanges[i], 4.0), 0.0, 1.0);
        attenuation *= rangeFactor * rangeFactor;

        // Point light shadow
        float pointShadow = 0.0;
        if (u_PointShadowIndices[i] >= 0)
        {
            pointShadow = computePointShadow(worldPos, u_PointLightPositions[i], u_PointShadowIndices[i]);
        }
        float pointShadowFactor = 1.0 - pointShadow;

        vec3 radiance = u_PointLightColors[i] * u_PointLightIntensities[i] * attenuation;
        Lo += computeRadiance(normal, V, L, radiance, albedo, metallic, roughness, F0) * pointShadowFactor;

        if (clearcoat > 0.0)
        {
            ccLo += computeRadiance(normal, V, L, radiance, vec3(1.0), 0.0, clearcoatRoughness, vec3(0.04)) * pointShadowFactor;
        }

        if (subsurface > 0.0)
        {
            float wrap = 0.5;
            float NdotL_wrap = max(0.0, (dot(normal, L) + wrap) / (1.0 + wrap));
            vec3 H_back = normalize(L + normal * 0.3);
            float VdotH_back = pow(clamp(dot(V, -H_back), 0.0, 1.0), 4.0);
            float thickness = 1.0 - max(dot(normal, V), 0.0);
            sssLo += u_SubsurfaceColor * albedo * (NdotL_wrap + VdotH_back * thickness) * radiance * pointShadowFactor;
        }
    }

    // Spot lights
    for (int i = 0; i < u_NumSpotLights; ++i)
    {
        vec3 L = u_SpotLightPositions[i] - worldPos;
        float dist = length(L);
        L = normalize(L);

        // Distance attenuation (same as point lights)
        float attenuation = 1.0 / (dist * dist);
        float rangeFactor = clamp(1.0 - pow(dist / u_SpotLightRanges[i], 4.0), 0.0, 1.0);
        attenuation *= rangeFactor * rangeFactor;

        // Cone attenuation: smooth falloff between inner and outer cone
        float theta = dot(L, normalize(-u_SpotLightDirections[i]));
        float spotFactor = smoothstep(u_SpotLightOuterCos[i], u_SpotLightInnerCos[i], theta);
        attenuation *= spotFactor;

        // Spot light shadow
        float spotShadow = 0.0;
        if (u_SpotShadowIndices[i] >= 0)
        {
            spotShadow = computeSpotShadow(worldPos, normal, L, u_SpotShadowIndices[i]);
        }
        float spotShadowFactor = 1.0 - spotShadow;

        vec3 radiance = u_SpotLightColors[i] * u_SpotLightIntensities[i] * attenuation;
        Lo += computeRadiance(normal, V, L, radiance, albedo, metallic, roughness, F0) * spotShadowFactor;

        if (clearcoat > 0.0)
        {
            ccLo += computeRadiance(normal, V, L, radiance, vec3(1.0), 0.0, clearcoatRoughness, vec3(0.04)) * spotShadowFactor;
        }

        if (subsurface > 0.0)
        {
            float wrap = 0.5;
            float NdotL_wrap = max(0.0, (dot(normal, L) + wrap) / (1.0 + wrap));
            vec3 H_back = normalize(L + normal * 0.3);
            float VdotH_back = pow(clamp(dot(V, -H_back), 0.0, 1.0), 4.0);
            float thickness = 1.0 - max(dot(normal, V), 0.0);
            sssLo += u_SubsurfaceColor * albedo * (NdotL_wrap + VdotH_back * thickness) * radiance * spotShadowFactor;
        }
    }

    float viewDepth = length(u_CameraPos - worldPos);

    // Directional lights
    for (int i = 0; i < u_NumDirLights; ++i)
    {
        vec3 L = normalize(-u_DirLightDirections[i]);
        vec3 radiance = u_DirLightColors[i] * u_DirLightIntensities[i];

        float shadow = (i == 0) ? computeShadow(worldPos, normal, L, viewDepth) : 0.0;
        float shadowFactor = 1.0 - shadow;

        Lo += computeRadiance(normal, V, L, radiance, albedo, metallic, roughness, F0) * shadowFactor;

        if (clearcoat > 0.0)
        {
            ccLo += computeRadiance(normal, V, L, radiance, vec3(1.0), 0.0, clearcoatRoughness, vec3(0.04)) * shadowFactor;
        }

        if (subsurface > 0.0)
        {
            float wrap = 0.5;
            float NdotL_wrap = max(0.0, (dot(normal, L) + wrap) / (1.0 + wrap));
            vec3 H_back = normalize(L + normal * 0.3);
            float VdotH_back = pow(clamp(dot(V, -H_back), 0.0, 1.0), 4.0);
            float thickness = 1.0 - max(dot(normal, V), 0.0);
            sssLo += u_SubsurfaceColor * albedo * (NdotL_wrap + VdotH_back * thickness) * radiance * shadowFactor;
        }
    }

    if (clearcoat > 0.0)
    {
        vec3 ccFresnel = FresnelSchlick(max(dot(normal, V), 0.0), vec3(0.04));
        Lo = Lo * (1.0 - clearcoat * ccFresnel) + clearcoat * ccLo;
    }

    if (subsurface > 0.0)
    {
        Lo += subsurface * sssLo;
    }

    vec3 ambient = vec3(0.0);

    if (u_HasIBL > 0)
    {
        vec3 F = fresnelSchlickRoughness(max(dot(normal, V), 0.0), F0, roughness);

        vec3 kD = vec3(1.0) - F;
        kD *= 1.0 - metallic;

        vec3 irradiance = texture(u_IrradianceMap, normal).rgb;
        vec3 diffuse = irradiance * albedo;

        vec3 R = reflect(-V, normal);
        const float MAX_REFLECTION_LOD = 4.0;
        vec3 prefilteredColor = textureLod(u_PrefilterMap, R, roughness * MAX_REFLECTION_LOD).rgb;

        vec2 brdf = texture(u_BRDFLUT, vec2(max(dot(normal, V), 0.0), roughness)).rg;
        vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);

        ambient = (kD * diffuse + specular) * u_IBLIntensity * ao;

        if (clearcoat > 0.0)
        {
            vec3 ccR = reflect(-V, normal);
            vec3 ccPrefilteredColor = textureLod(u_PrefilterMap, ccR, clearcoatRoughness * MAX_REFLECTION_LOD).rgb;
            vec3 ccF = FresnelSchlick(max(dot(normal, V), 0.0), vec3(0.04));
            vec2 ccBrdf = texture(u_BRDFLUT, vec2(max(dot(normal, V), 0.0), clearcoatRoughness)).rg;
            vec3 ccSpecular = ccPrefilteredColor * (ccF * ccBrdf.x + ccBrdf.y);
            ambient += clearcoat * ccSpecular * u_IBLIntensity;
        }
    }
    else
    {
        ambient = vec3(0.03) * albedo * ao;
    }

    vec3 color = ambient + Lo + emissive;

    // Apply fog
    if (u_FogEnabled == 1)
    {
        float dist = length(worldPos - u_CameraPos);
        float fogFactor;

        if (u_FogMode == 0) // Linear
        {
            fogFactor = clamp((u_FogEnd - dist) / (u_FogEnd - u_FogStart), 0.0, 1.0);
        }
        else if (u_FogMode == 1) // Exponential
        {
            fogFactor = exp(-u_FogDensity * dist);
        }
        else // Exponential squared
        {
            float f = u_FogDensity * dist;
            fogFactor = exp(-f * f);
        }

        // Height-based fog attenuation
        if (u_FogHeightEnabled == 1)
        {
            float heightAbove = worldPos.y - u_FogHeightOffset;
            float heightFactor = exp(-u_FogHeightFalloff * max(heightAbove, 0.0));
            fogFactor = mix(1.0, fogFactor, heightFactor);
        }

        fogFactor = clamp(fogFactor, 0.0, 1.0);
        color = mix(u_FogColor, color, fogFactor);
    }

    FragColor = vec4(color, 1.0);
}
"""

# =============================================================================
# Deferred Pipeline Type
# =============================================================================

"""
    DeferredPipeline <: AbstractDeferredPipeline

Deferred rendering pipeline with G-Buffer and lighting pass.
"""
mutable struct DeferredPipeline <: AbstractDeferredPipeline
    gbuffer::GBuffer
    lighting_fbo::Framebuffer
    gbuffer_shader_library::Union{ShaderLibrary{ShaderProgram}, Nothing}
    lighting_shader::Union{ShaderProgram, Nothing}
    ibl_env::Union{IBLEnvironment, Nothing}
    ssr_pass::Union{SSRPass, Nothing}
    ssao_pass::Union{SSAOPass, Nothing}
    taa_pass::Union{TAAPass, Nothing}
    quad_vao::GLuint
    quad_vbo::GLuint
    placeholder_cubemap::GLuint   # 1x1 black cubemap for unused samplerCube uniforms
    placeholder_2d::GLuint        # 1x1 black texture for unused sampler2D uniforms

    DeferredPipeline() = new(
        GBuffer(),
        Framebuffer(),
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        GLuint(0),
        GLuint(0),
        GLuint(0),
        GLuint(0)
    )
end

# =============================================================================
# Deferred Pipeline Functions
# =============================================================================

"""
    create_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)

Initialize the deferred rendering pipeline.
"""
function create_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)
    # Create G-Buffer
    create_gbuffer!(pipeline.gbuffer, width, height)

    # Create lighting accumulation framebuffer (HDR)
    create_framebuffer!(pipeline.lighting_fbo, width, height)

    # Create shader library for G-Buffer pass (with permutations)
    pipeline.gbuffer_shader_library = ShaderLibrary{ShaderProgram}(
        "GBuffer",
        GBUFFER_VERTEX_SHADER,
        GBUFFER_FRAGMENT_SHADER,
        create_shader_program
    )

    # Create deferred lighting shader
    pipeline.lighting_shader = create_shader_program(
        DEFERRED_LIGHTING_VERTEX_SHADER,
        DEFERRED_LIGHTING_FRAGMENT_SHADER
    )

    # Create fullscreen quad for lighting pass
    quad_vertices = Float32[
        # Position    TexCoord
        -1.0, -1.0,   0.0, 0.0,
         1.0, -1.0,   1.0, 0.0,
         1.0,  1.0,   1.0, 1.0,
        -1.0, -1.0,   0.0, 0.0,
         1.0,  1.0,   1.0, 1.0,
        -1.0,  1.0,   0.0, 1.0
    ]

    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    pipeline.quad_vao = vao_ref[]

    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    pipeline.quad_vbo = vbo_ref[]

    glBindVertexArray(pipeline.quad_vao)
    glBindBuffer(GL_ARRAY_BUFFER, pipeline.quad_vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW)

    # Position attribute
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(0))
    glEnableVertexAttribArray(0)

    # TexCoord attribute
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(Float32), Ptr{Cvoid}(2 * sizeof(Float32)))
    glEnableVertexAttribArray(1)

    glBindVertexArray(GLuint(0))

    # Create placeholder textures for unused samplers (prevents GL_INVALID_OPERATION
    # when samplerCube uniforms default to texture units with GL_TEXTURE_2D bound)
    black_pixel = Float32[0.0, 0.0, 0.0, 1.0]

    cube_ref = Ref(GLuint(0))
    glGenTextures(1, cube_ref)
    pipeline.placeholder_cubemap = cube_ref[]
    glBindTexture(GL_TEXTURE_CUBE_MAP, pipeline.placeholder_cubemap)
    for face in 0:5
        glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + UInt32(face), 0, GL_RGBA16F, 1, 1, 0, GL_RGBA, GL_FLOAT, black_pixel)
    end
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)

    tex2d_ref = Ref(GLuint(0))
    glGenTextures(1, tex2d_ref)
    pipeline.placeholder_2d = tex2d_ref[]
    glBindTexture(GL_TEXTURE_2D, pipeline.placeholder_2d)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RG16F, 1, 1, 0, GL_RG, GL_FLOAT, Float32[0.0, 0.0])
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)

    # Create SSR pass (optional, can be enabled/disabled)
    pipeline.ssr_pass = SSRPass(width=width, height=height)
    create_ssr_pass!(pipeline.ssr_pass, width, height)

    # Create SSAO pass (optional, can be enabled/disabled)
    pipeline.ssao_pass = SSAOPass(width=width, height=height)
    create_ssao_pass!(pipeline.ssao_pass, width, height)

    # Create TAA pass (optional, can be enabled/disabled)
    pipeline.taa_pass = create_taa_pass!(width, height)

    @info "Created deferred pipeline" width=width height=height

    return nothing
end

"""
    destroy_deferred_pipeline!(pipeline::DeferredPipeline)

Release GPU resources for the deferred pipeline.
"""
function destroy_deferred_pipeline!(pipeline::DeferredPipeline)
    destroy_gbuffer!(pipeline.gbuffer)
    destroy_framebuffer!(pipeline.lighting_fbo)

    if pipeline.gbuffer_shader_library !== nothing
        destroy_shader_library!(pipeline.gbuffer_shader_library)
        pipeline.gbuffer_shader_library = nothing
    end

    if pipeline.lighting_shader !== nothing
        destroy_shader_program!(pipeline.lighting_shader)
        pipeline.lighting_shader = nothing
    end

    if pipeline.quad_vao != GLuint(0)
        glDeleteVertexArrays(1, Ref(pipeline.quad_vao))
        pipeline.quad_vao = GLuint(0)
    end

    if pipeline.quad_vbo != GLuint(0)
        glDeleteBuffers(1, Ref(pipeline.quad_vbo))
        pipeline.quad_vbo = GLuint(0)
    end

    if pipeline.placeholder_cubemap != GLuint(0)
        glDeleteTextures(1, Ref(pipeline.placeholder_cubemap))
        pipeline.placeholder_cubemap = GLuint(0)
    end
    if pipeline.placeholder_2d != GLuint(0)
        glDeleteTextures(1, Ref(pipeline.placeholder_2d))
        pipeline.placeholder_2d = GLuint(0)
    end

    if pipeline.ssr_pass !== nothing
        destroy_ssr_pass!(pipeline.ssr_pass)
        pipeline.ssr_pass = nothing
    end

    if pipeline.ssao_pass !== nothing
        destroy_ssao_pass!(pipeline.ssao_pass)
        pipeline.ssao_pass = nothing
    end

    if pipeline.taa_pass !== nothing
        destroy_taa_pass!(pipeline.taa_pass)
        pipeline.taa_pass = nothing
    end

    return nothing
end

"""
    resize_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)

Resize the deferred pipeline framebuffers.
"""
function resize_deferred_pipeline!(pipeline::DeferredPipeline, width::Int, height::Int)
    resize_gbuffer!(pipeline.gbuffer, width, height)
    resize_framebuffer!(pipeline.lighting_fbo, width, height)

    if pipeline.ssr_pass !== nothing
        resize_ssr_pass!(pipeline.ssr_pass, width, height)
    end

    if pipeline.ssao_pass !== nothing
        resize_ssao_pass!(pipeline.ssao_pass, width, height)
    end

    if pipeline.taa_pass !== nothing
        resize_taa_pass!(pipeline.taa_pass, width, height)
    end
end
