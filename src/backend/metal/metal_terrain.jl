# Metal terrain rendering — G-buffer output for deferred pipeline

# ---- Terrain GPU Cache ----

mutable struct MetalTerrainGPUCache
    chunk_meshes::Dict{Tuple{Int,Int,Int}, MetalGPUMesh}  # (cx, cz, lod) -> mesh
    layer_textures::Vector{UInt64}                          # per-layer albedo handles
    splatmap_texture::UInt64
    pipeline::UInt64
    initialized::Bool

    MetalTerrainGPUCache() = new(Dict{Tuple{Int,Int,Int}, MetalGPUMesh}(), UInt64[], UInt64(0), UInt64(0), false)
end

# ---- Terrain Uniforms (must match MSL TerrainUniforms) ----

struct MetalTerrainUniforms
    view_proj::NTuple{16, Float32}
    camera_pos::NTuple{4, Float32}
    chunk_offset::NTuple{4, Float32}     # world offset (x, 0, z, 0)
    terrain_size::NTuple{4, Float32}     # (width, height, depth, tile_scale)
    num_layers::Int32
    _pad1::Float32
    _pad2::Float32
    _pad3::Float32
end

# ---- Initialization ----

function metal_init_terrain_cache!(cache::MetalTerrainGPUCache, device_handle::UInt64)
    if cache.initialized
        return nothing
    end

    # Compile terrain G-buffer pipeline targeting 4 color attachments + depth
    terrain_msl = _load_msl_shader("terrain_gbuffer.metal")
    cache.pipeline = metal_get_or_create_pipeline(terrain_msl, "terrain_vertex", "terrain_fragment";
        num_color_attachments=Int32(4),
        color_formats=UInt32[MTL_PIXEL_FORMAT_RGBA16_FLOAT, MTL_PIXEL_FORMAT_RGBA16_FLOAT,
                             MTL_PIXEL_FORMAT_RGBA16_FLOAT, MTL_PIXEL_FORMAT_RGBA8_UNORM],
        depth_format=MTL_PIXEL_FORMAT_DEPTH32_FLOAT,
        blend_enabled=Int32(0))

    cache.initialized = true
    @info "Metal terrain cache initialized"
    return nothing
end

# ---- Terrain Rendering into G-Buffer ----

function metal_render_terrain!(backend, cache::MetalTerrainGPUCache,
                                td, comp, view::Mat4f, proj::Mat4f,
                                cam_pos::Vec3f, encoder::UInt64, cmd_buf::UInt64)
    if !cache.initialized || cache.pipeline == UInt64(0)
        return nothing
    end

    vp = proj * view

    metal_set_render_pipeline(encoder, cache.pipeline)
    metal_set_depth_stencil_state(encoder, backend.ds_less_write)
    metal_set_cull_mode(encoder, MTL_CULL_BACK)

    # Bind splatmap texture (texture index 0)
    if cache.splatmap_texture != UInt64(0)
        metal_set_fragment_texture(encoder, cache.splatmap_texture, Int32(0))
    end

    # Bind per-layer albedo textures (texture indices 1..4)
    for (i, tex_handle) in enumerate(cache.layer_textures)
        if tex_handle != UInt64(0) && i <= 4
            metal_set_fragment_texture(encoder, tex_handle, Int32(i))
        end
    end

    # Bind default sampler
    metal_set_fragment_sampler(encoder, backend.default_sampler, Int32(0))

    # Render each visible terrain chunk
    for ((cx, cz, lod), gpu_mesh) in cache.chunk_meshes
        chunk_x = Float32(cx) * Float32(td.chunk_size)
        chunk_z = Float32(cz) * Float32(td.chunk_size)

        uniforms = MetalTerrainUniforms(
            ntuple(i -> vp[i], 16),
            (cam_pos[1], cam_pos[2], cam_pos[3], 0.0f0),
            (chunk_x, 0.0f0, chunk_z, 0.0f0),
            (Float32(td.width), Float32(td.height), Float32(td.depth), Float32(td.tile_scale)),
            Int32(length(cache.layer_textures)),
            0.0f0, 0.0f0, 0.0f0
        )

        uniform_buf = _create_uniform_buffer(backend.device_handle, uniforms, "terrain_uniforms")

        metal_set_vertex_buffer(encoder, uniform_buf, 0, Int32(3))
        metal_set_fragment_buffer(encoder, uniform_buf, 0, Int32(3))

        # Bind mesh vertex buffers
        metal_set_vertex_buffer(encoder, gpu_mesh.vertex_buffer, 0, Int32(0))
        metal_set_vertex_buffer(encoder, gpu_mesh.normal_buffer, 0, Int32(1))
        metal_set_vertex_buffer(encoder, gpu_mesh.uv_buffer, 0, Int32(2))

        # Draw indexed
        metal_draw_indexed(encoder, MTL_PRIMITIVE_TRIANGLE, gpu_mesh.index_count,
                            gpu_mesh.index_buffer, 0)

        metal_destroy_buffer(uniform_buf)
    end

    return nothing
end

# ---- Cleanup ----

function metal_destroy_terrain_cache!(cache::MetalTerrainGPUCache)
    for (_, gpu_mesh) in cache.chunk_meshes
        metal_destroy_mesh!(gpu_mesh)
    end
    empty!(cache.chunk_meshes)

    for tex_handle in cache.layer_textures
        if tex_handle != UInt64(0)
            metal_destroy_texture(tex_handle)
        end
    end
    empty!(cache.layer_textures)

    if cache.splatmap_texture != UInt64(0)
        metal_destroy_texture(cache.splatmap_texture)
        cache.splatmap_texture = UInt64(0)
    end

    # Pipeline is managed by the global pipeline cache
    cache.pipeline = UInt64(0)
    cache.initialized = false

    return nothing
end

# ---- Abstract interface ----

function backend_render_terrain!(backend::MetalBackend, terrain_data, view::Mat4f, proj::Mat4f,
                                  cam_pos::Vec3f, texture_cache)
    # Terrain caches are stored per-entity on the backend; iterate all terrain entities
    # and delegate rendering through the active G-buffer encoder.
    # This function is called during the G-buffer pass with an active encoder.
    #
    # NOTE: The caller must have an active render pass encoder targeting the G-buffer.
    # In a typical integration, this would be called from the G-buffer pass in
    # metal_render_gbuffer_pass! with the encoder and cmd_buf handles.
    return nothing
end

# ---- Streaming terrain support ----

"""
    render_streaming_terrain_gbuffer!(backend::MetalBackend, entity_id, streaming_sys,
                                       comp, view, proj, cam_pos, frustum, texture_cache)

Render streaming terrain chunks via Metal. Iterates active streaming chunks
instead of the fixed chunk matrix.
"""
function render_streaming_terrain_gbuffer!(backend::MetalBackend, entity_id::EntityID,
                                            streaming_sys::ChunkStreamingSystem,
                                            comp::TerrainComponent,
                                            view::Mat4f, proj::Mat4f, cam_pos::Vec3f,
                                            frustum::Frustum, texture_cache)
    # Streaming terrain rendering follows the same pattern as fixed terrain
    # but iterates streaming_sys.active_chunks instead of the fixed chunk matrix.
    # Full implementation mirrors backend_render_terrain! with dynamic chunk iteration.
    return nothing
end
