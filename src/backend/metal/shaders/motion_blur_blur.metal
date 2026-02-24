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

// ---- Directional Blur Fragment Shader ----
// Averages N samples along the per-pixel velocity direction.
// The velocity is read from the velocity buffer and scaled by intensity.
// Produces the final motion-blurred image.

fragment float4 mb_blur_fragment(
    VertexOut in [[stage_in]],
    constant MotionBlurUniforms& uniforms [[buffer(1)]],
    texture2d<float> sceneTexture    [[texture(0)]],
    texture2d<float> velocityTexture [[texture(1)]],
    sampler samp [[sampler(0)]]
) {
    float2 velocity = velocityTexture.sample(samp, in.texCoord).rg;

    // Scale velocity by intensity
    velocity *= uniforms.intensity;

    // If velocity is negligible, return the original color
    float velMag = length(velocity);
    if (velMag < 0.0001) {
        return sceneTexture.sample(samp, in.texCoord);
    }

    // Number of samples along the velocity direction
    int numSamples = max(uniforms.num_samples, 1);

    float4 color = float4(0.0);
    for (int i = 0; i < numSamples; i++) {
        // Distribute samples evenly from -0.5 to +0.5 along the velocity vector
        float t = float(i) / float(numSamples - 1) - 0.5;
        float2 sampleUV = in.texCoord + velocity * t;

        // Clamp to [0,1] to avoid sampling outside the texture
        sampleUV = clamp(sampleUV, float2(0.0), float2(1.0));

        color += sceneTexture.sample(samp, sampleUV);
    }

    color /= float(numSamples);
    return color;
}
