# Metal backend concrete types
# Each type holds UInt64 handles to Swift-side Metal objects.

# ---- Metal pixel format constants (must match MetalPixelFormat in Swift) ----
const MTL_PIXEL_FORMAT_RGBA8_UNORM   = UInt32(0)
const MTL_PIXEL_FORMAT_RGBA16_FLOAT  = UInt32(1)
const MTL_PIXEL_FORMAT_R8_UNORM      = UInt32(2)
const MTL_PIXEL_FORMAT_R16_FLOAT     = UInt32(3)
const MTL_PIXEL_FORMAT_DEPTH32_FLOAT = UInt32(4)
const MTL_PIXEL_FORMAT_BGRA8_UNORM   = UInt32(5)

# ---- Metal load/store action constants ----
const MTL_LOAD_DONT_CARE = UInt32(0)
const MTL_LOAD_LOAD      = UInt32(1)
const MTL_LOAD_CLEAR     = UInt32(2)

const MTL_STORE_DONT_CARE = UInt32(0)
const MTL_STORE_STORE     = UInt32(1)

# ---- Metal compare function constants ----
const MTL_COMPARE_NEVER          = UInt32(0)
const MTL_COMPARE_LESS           = UInt32(1)
const MTL_COMPARE_EQUAL          = UInt32(2)
const MTL_COMPARE_LESS_EQUAL     = UInt32(3)
const MTL_COMPARE_GREATER        = UInt32(4)
const MTL_COMPARE_NOT_EQUAL      = UInt32(5)
const MTL_COMPARE_GREATER_EQUAL  = UInt32(6)
const MTL_COMPARE_ALWAYS         = UInt32(7)

# ---- Metal cull mode constants ----
const MTL_CULL_NONE  = UInt32(0)
const MTL_CULL_FRONT = UInt32(1)
const MTL_CULL_BACK  = UInt32(2)

# ---- Metal primitive type constants ----
const MTL_PRIMITIVE_TRIANGLE       = UInt32(0)
const MTL_PRIMITIVE_TRIANGLE_STRIP = UInt32(1)
const MTL_PRIMITIVE_LINE           = UInt32(2)
const MTL_PRIMITIVE_POINT          = UInt32(3)

# ---- Texture usage bit flags ----
const MTL_USAGE_SHADER_READ   = Int32(1)   # bit 0
const MTL_USAGE_SHADER_WRITE  = Int32(2)   # bit 1
const MTL_USAGE_RENDER_TARGET = Int32(4)   # bit 2

# ==================================================================
# Concrete types
# ==================================================================

"""
    MetalShaderProgram <: AbstractShaderProgram

Metal render pipeline state, referenced by a handle to the Swift side.
"""
mutable struct MetalShaderProgram <: AbstractShaderProgram
    pipeline_handle::UInt64
    vertex_function::String
    fragment_function::String

    MetalShaderProgram(handle::UInt64, vert::String, frag::String) =
        new(handle, vert, frag)
end

"""
    MetalGPUMesh <: AbstractGPUMesh

Metal GPU-resident mesh with separate vertex attribute buffers and an index buffer.
"""
mutable struct MetalGPUMesh <: AbstractGPUMesh
    vertex_buffer::UInt64    # positions
    normal_buffer::UInt64    # normals
    uv_buffer::UInt64        # tex coords
    index_buffer::UInt64     # indices
    index_count::Int32

    MetalGPUMesh() = new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), Int32(0))
end

get_index_count(mesh::MetalGPUMesh) = mesh.index_count

"""
    MetalGPUTexture <: AbstractGPUTexture

Metal GPU texture handle with metadata.
"""
mutable struct MetalGPUTexture <: AbstractGPUTexture
    handle::UInt64
    width::Int
    height::Int
    channels::Int

    MetalGPUTexture() = new(UInt64(0), 0, 0, 0)
end

"""
    MetalRenderTarget <: AbstractFramebuffer

Metal render target (framebuffer equivalent) — owns color + depth textures.
"""
mutable struct MetalRenderTarget <: AbstractFramebuffer
    handle::UInt64           # render target handle in Swift registry
    color_texture_handles::Vector{UInt64}
    depth_texture_handle::UInt64
    width::Int
    height::Int

    MetalRenderTarget(; width::Int=1280, height::Int=720) =
        new(UInt64(0), UInt64[], UInt64(0), width, height)
end

get_width(rt::MetalRenderTarget) = rt.width
get_height(rt::MetalRenderTarget) = rt.height

"""
    MetalGBuffer <: AbstractGBuffer

Metal G-Buffer with 4 color render targets and a depth texture.
"""
mutable struct MetalGBuffer <: AbstractGBuffer
    rt_handle::UInt64        # render target handle
    albedo_metallic::UInt64  # color 0 texture handle
    normal_roughness::UInt64 # color 1 texture handle
    emissive_ao::UInt64      # color 2 texture handle
    advanced_material::UInt64 # color 3 texture handle
    depth::UInt64            # depth texture handle
    width::Int
    height::Int

    MetalGBuffer(; width::Int=1280, height::Int=720) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), width, height)
end

get_width(gb::MetalGBuffer) = gb.width
get_height(gb::MetalGBuffer) = gb.height

"""
    MetalShadowMap <: AbstractShadowMap

Metal depth-only render target for shadow mapping.
"""
mutable struct MetalShadowMap <: AbstractShadowMap
    rt_handle::UInt64
    depth_texture::UInt64
    depth_pipeline::UInt64   # depth-only render pipeline
    width::Int
    height::Int

    MetalShadowMap(; width::Int=2048, height::Int=2048) =
        new(UInt64(0), UInt64(0), UInt64(0), width, height)
end

get_width(sm::MetalShadowMap) = sm.width
get_height(sm::MetalShadowMap) = sm.height

"""
    MetalCascadedShadowMap <: AbstractCascadedShadowMap

Metal cascaded shadow maps with per-cascade render targets.
"""
mutable struct MetalCascadedShadowMap <: AbstractCascadedShadowMap
    num_cascades::Int
    cascade_rt_handles::Vector{UInt64}
    cascade_depth_textures::Vector{UInt64}
    cascade_matrices::Vector{Mat4f}
    split_distances::Vector{Float32}
    resolution::Int
    depth_pipeline::UInt64

    MetalCascadedShadowMap(; num_cascades::Int=4, resolution::Int=2048) =
        new(num_cascades, UInt64[], UInt64[], Mat4f[], Float32[], resolution, UInt64(0))
end

"""
    MetalIBLEnvironment <: AbstractIBLEnvironment

Metal IBL textures: environment cubemap, irradiance, prefilter, BRDF LUT.
"""
mutable struct MetalIBLEnvironment <: AbstractIBLEnvironment
    environment_map::UInt64
    irradiance_map::UInt64
    prefilter_map::UInt64
    brdf_lut::UInt64
    intensity::Float32

    MetalIBLEnvironment(; intensity::Float32=1.0f0) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), intensity)
end

"""
    MetalSSAOPass <: AbstractSSAOPass

Metal SSAO pass with output texture and blur.
"""
mutable struct MetalSSAOPass <: AbstractSSAOPass
    ssao_rt::UInt64
    blur_rt::UInt64
    ssao_texture::UInt64
    blur_texture::UInt64
    noise_texture::UInt64
    ssao_pipeline::UInt64
    blur_pipeline::UInt64
    kernel::Vector{Vec3f}
    kernel_size::Int
    radius::Float32
    bias::Float32
    power::Float32
    width::Int
    height::Int

    MetalSSAOPass(; width::Int=1280, height::Int=720, kernel_size::Int=64,
                   radius::Float32=0.5f0, bias::Float32=0.025f0, power::Float32=1.0f0) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
            Vec3f[], kernel_size, radius, bias, power, width, height)
end

get_width(ssao::MetalSSAOPass) = ssao.width
get_height(ssao::MetalSSAOPass) = ssao.height

"""
    MetalSSRPass <: AbstractSSRPass

Metal screen-space reflections pass.
"""
mutable struct MetalSSRPass <: AbstractSSRPass
    ssr_rt::UInt64
    ssr_texture::UInt64
    ssr_pipeline::UInt64
    width::Int
    height::Int
    max_steps::Int
    max_distance::Float32
    thickness::Float32

    MetalSSRPass(; width::Int=1280, height::Int=720, max_steps::Int=64,
                  max_distance::Float32=50.0f0, thickness::Float32=0.5f0) =
        new(UInt64(0), UInt64(0), UInt64(0), width, height, max_steps, max_distance, thickness)
end

get_width(ssr::MetalSSRPass) = ssr.width
get_height(ssr::MetalSSRPass) = ssr.height

"""
    MetalTAAPass <: AbstractTAAPass

Metal temporal anti-aliasing pass.
"""
mutable struct MetalTAAPass <: AbstractTAAPass
    history_rt::UInt64
    current_rt::UInt64
    history_texture::UInt64
    current_texture::UInt64
    taa_pipeline::UInt64
    feedback::Float32
    jitter_index::Int
    prev_view_proj::Mat4f
    first_frame::Bool
    width::Int
    height::Int

    MetalTAAPass(; width::Int=1280, height::Int=720, feedback::Float32=0.9f0) =
        new(UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0),
            feedback, 0, Mat4f(I), true, width, height)
end

get_width(taa::MetalTAAPass) = taa.width
get_height(taa::MetalTAAPass) = taa.height

"""
    MetalPostProcessPipeline <: AbstractPostProcessPipeline

Metal post-processing pipeline (bloom, tone mapping, FXAA).
"""
mutable struct MetalPostProcessPipeline <: AbstractPostProcessPipeline
    config::PostProcessConfig
    scene_rt::UInt64
    bright_rt::UInt64
    bloom_rts::Vector{UInt64}
    composite_pipeline::UInt64
    bright_extract_pipeline::UInt64
    blur_pipeline::UInt64
    fxaa_pipeline::UInt64
    quad_vertex_buffer::UInt64

    MetalPostProcessPipeline(; config::PostProcessConfig=PostProcessConfig()) =
        new(config, UInt64(0), UInt64(0), UInt64[], UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
end

"""
    MetalDeferredPipeline <: AbstractDeferredPipeline

Metal deferred rendering pipeline.
"""
mutable struct MetalDeferredPipeline <: AbstractDeferredPipeline
    gbuffer::Union{MetalGBuffer, Nothing}
    lighting_rt::Union{MetalRenderTarget, Nothing}
    lighting_pipeline::UInt64
    gbuffer_shader_library::Union{ShaderLibrary{MetalShaderProgram}, Nothing}
    ssao_pass::Union{MetalSSAOPass, Nothing}
    ssr_pass::Union{MetalSSRPass, Nothing}
    taa_pass::Union{MetalTAAPass, Nothing}
    ibl_env::Union{MetalIBLEnvironment, Nothing}
    quad_vertex_buffer::UInt64

    # New: DOF and Motion Blur passes (operate between TAA and post-processing)
    dof_pass::Union{MetalDOFPass, Nothing}
    motion_blur_pass::Union{MetalMotionBlurPass, Nothing}

    MetalDeferredPipeline() =
        new(nothing, nothing, UInt64(0), nothing, nothing, nothing, nothing, nothing, UInt64(0),
            nothing, nothing)
end

"""
    MetalGPUResourceCache <: AbstractGPUResourceCache

Maps EntityIDs to MetalGPUMesh handles.
"""
mutable struct MetalGPUResourceCache <: AbstractGPUResourceCache
    meshes::Dict{EntityID, MetalGPUMesh}

    MetalGPUResourceCache() = new(Dict{EntityID, MetalGPUMesh}())
end

"""
    MetalTextureCache <: AbstractTextureCache

Maps file paths to MetalGPUTexture handles.
"""
mutable struct MetalTextureCache <: AbstractTextureCache
    textures::Dict{String, MetalGPUTexture}

    MetalTextureCache() = new(Dict{String, MetalGPUTexture}())
end
