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

// ---- Separable Gaussian Blur weighted by CoC ----
// 9-tap Gaussian kernel. The blur direction is controlled by uniforms.horizontal.
// Each sample's contribution is weighted by max(center_coc, sample_coc) to ensure
// out-of-focus regions bleed correctly into neighboring pixels.

fragment float4 dof_blur_fragment(
    VertexOut in [[stage_in]],
    constant DOFUniforms& uniforms [[buffer(1)]],
    texture2d<float> sceneTexture [[texture(0)]],
    texture2d<float> cocTexture   [[texture(1)]],
    sampler samp [[sampler(0)]]
) {
    // 9-tap Gaussian weights (sigma ~= 2.0)
    const float weights[9] = {
        0.0162162162, 0.0540540541, 0.1216216216, 0.1945945946,
        0.2270270270,
        0.1945945946, 0.1216216216, 0.0540540541, 0.0162162162
    };
    const float offsets[9] = {
        -4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0
    };

    float2 texelSize = 1.0 / float2(sceneTexture.get_width(), sceneTexture.get_height());

    // Blur direction based on horizontal flag
    float2 direction;
    if (uniforms.horizontal != 0) {
        direction = float2(texelSize.x, 0.0);
    } else {
        direction = float2(0.0, texelSize.y);
    }

    // Scale blur radius by bokeh_radius and center CoC
    float centerCoC = cocTexture.sample(samp, in.texCoord).r;
    float2 scaledDir = direction * uniforms.bokeh_radius;

    float4 color = float4(0.0);
    float totalWeight = 0.0;

    for (int i = 0; i < 9; i++) {
        float2 sampleUV = in.texCoord + scaledDir * offsets[i];
        float4 sampleColor = sceneTexture.sample(samp, sampleUV);
        float sampleCoC = cocTexture.sample(samp, sampleUV).r;

        // Weight by max of center and sample CoC to allow out-of-focus bleed
        float cocWeight = max(centerCoC, sampleCoC);
        float w = weights[i] * cocWeight;

        color += sampleColor * w;
        totalWeight += w;
    }

    // Avoid division by zero when everything is perfectly in focus
    if (totalWeight > 0.001) {
        color /= totalWeight;
    } else {
        color = sceneTexture.sample(samp, in.texCoord);
    }

    return color;
}
