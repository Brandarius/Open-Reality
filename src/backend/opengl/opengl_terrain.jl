# OpenGL terrain renderer: G-Buffer rendering with splatmap blending

"""
    TerrainGPUCache

Per-entity cache of terrain GPU resources (chunk meshes + layer textures).
"""
mutable struct TerrainGPUCache
    chunk_meshes::Dict{Tuple{Int,Int,Int}, GPUMesh}  # (cx, cz, lod) -> GPUMesh
    layer_textures::Vector{GLuint}    # Albedo textures for each layer
    splatmap_texture::GLuint
    shader::Union{ShaderProgram, Nothing}

    TerrainGPUCache() = new(Dict(), GLuint[], GLuint(0), nothing)
end

const _TERRAIN_GPU_CACHES = Dict{EntityID, TerrainGPUCache}()

function reset_terrain_gpu_caches!()
    for (_, cache) in _TERRAIN_GPU_CACHES
        _destroy_terrain_gpu_cache!(cache)
    end
    empty!(_TERRAIN_GPU_CACHES)
end

function _destroy_terrain_gpu_cache!(cache::TerrainGPUCache)
    for (_, gm) in cache.chunk_meshes
        if gm.vao != GLuint(0)
            glDeleteVertexArrays(1, Ref(gm.vao))
        end
        for buf in (gm.vbo, gm.nbo, gm.ubo, gm.ebo)
            if buf != GLuint(0)
                glDeleteBuffers(1, Ref(buf))
            end
        end
    end
    empty!(cache.chunk_meshes)
    for tex in cache.layer_textures
        if tex != GLuint(0)
            glDeleteTextures(1, Ref(tex))
        end
    end
    empty!(cache.layer_textures)
    if cache.splatmap_texture != GLuint(0)
        glDeleteTextures(1, Ref(cache.splatmap_texture))
        cache.splatmap_texture = GLuint(0)
    end
    if cache.shader !== nothing
        destroy_shader_program!(cache.shader)
        cache.shader = nothing
    end
end

# ---- Terrain G-Buffer shader ----

const TERRAIN_GBUFFER_VERTEX = """
#version 330 core

layout(location = 0) in vec3 a_Position;
layout(location = 1) in vec3 a_Normal;
layout(location = 2) in vec2 a_TexCoord;

uniform mat4 u_View;
uniform mat4 u_Projection;

out vec3 v_WorldPos;
out vec3 v_Normal;
out vec2 v_TexCoord;

void main()
{
    v_WorldPos = a_Position;  // Terrain vertices are already in world space
    v_Normal = a_Normal;
    v_TexCoord = a_TexCoord;
    gl_Position = u_Projection * u_View * vec4(a_Position, 1.0);
}
"""

const TERRAIN_GBUFFER_FRAGMENT = """
#version 330 core

layout(location = 0) out vec4 gAlbedoMetallic;
layout(location = 1) out vec4 gNormalRoughness;
layout(location = 2) out vec4 gEmissiveAO;

in vec3 v_WorldPos;
in vec3 v_Normal;
in vec2 v_TexCoord;

uniform sampler2D u_Splatmap;
uniform sampler2D u_Layer0Albedo;
uniform sampler2D u_Layer1Albedo;
uniform sampler2D u_Layer2Albedo;
uniform sampler2D u_Layer3Albedo;
uniform float u_Layer0UVScale;
uniform float u_Layer1UVScale;
uniform float u_Layer2UVScale;
uniform float u_Layer3UVScale;
uniform int u_NumLayers;

void main()
{
    // Sample splatmap weights (RGBA = 4 layers)
    vec4 splat = texture(u_Splatmap, v_TexCoord);

    // World-space XZ for tiling (prevents stretching on slopes)
    vec2 world_uv = v_WorldPos.xz;

    // Blend albedo from layers using splatmap weights
    vec3 albedo = vec3(0.3, 0.6, 0.2);  // Default green if no layers

    if (u_NumLayers >= 1) {
        vec3 c0 = texture(u_Layer0Albedo, world_uv * u_Layer0UVScale).rgb;
        albedo = c0 * splat.r;
    }
    if (u_NumLayers >= 2) {
        vec3 c1 = texture(u_Layer1Albedo, world_uv * u_Layer1UVScale).rgb;
        albedo += c1 * splat.g;
    }
    if (u_NumLayers >= 3) {
        vec3 c2 = texture(u_Layer2Albedo, world_uv * u_Layer2UVScale).rgb;
        albedo += c2 * splat.b;
    }
    if (u_NumLayers >= 4) {
        vec3 c3 = texture(u_Layer3Albedo, world_uv * u_Layer3UVScale).rgb;
        albedo += c3 * splat.a;
    }

    // Normalize if total weight < 1 (avoid darkening)
    float total_weight = splat.r;
    if (u_NumLayers >= 2) total_weight += splat.g;
    if (u_NumLayers >= 3) total_weight += splat.b;
    if (u_NumLayers >= 4) total_weight += splat.a;
    if (total_weight > 0.001)
        albedo /= total_weight;

    // G-Buffer output
    gAlbedoMetallic = vec4(albedo, 0.0);   // Metallic = 0 for terrain
    gNormalRoughness = vec4(normalize(v_Normal) * 0.5 + 0.5, 0.85);  // Roughness = 0.85
    gEmissiveAO = vec4(0.0, 0.0, 0.0, 1.0);  // No emissive, full AO
}
"""

# ---- Terrain rendering ----

"""
    get_or_create_terrain_gpu_cache!(entity_id, td, comp, texture_cache) -> TerrainGPUCache

Get or create the GPU cache for a terrain entity.
"""
function get_or_create_terrain_gpu_cache!(entity_id::EntityID, td::TerrainData,
                                           comp::TerrainComponent, texture_cache::TextureCache)
    if haskey(_TERRAIN_GPU_CACHES, entity_id)
        return _TERRAIN_GPU_CACHES[entity_id]
    end

    cache = TerrainGPUCache()

    # Compile terrain shader
    cache.shader = create_shader_program(TERRAIN_GBUFFER_VERTEX, TERRAIN_GBUFFER_FRAGMENT)

    # Load layer textures
    for layer in comp.layers
        if !isempty(layer.albedo_path) && isfile(layer.albedo_path)
            tex = load_texture(texture_cache, layer.albedo_path)
            push!(cache.layer_textures, tex.id)
        else
            push!(cache.layer_textures, GLuint(0))
        end
    end

    # Load splatmap
    if !isempty(comp.splatmap_path) && isfile(comp.splatmap_path)
        splat_tex = load_texture(texture_cache, comp.splatmap_path)
        cache.splatmap_texture = splat_tex.id
    else
        # Generate a default splatmap (all weight on layer 0)
        cache.splatmap_texture = _create_default_splatmap(td)
    end

    _TERRAIN_GPU_CACHES[entity_id] = cache
    return cache
end

"""
    _create_default_splatmap(td) -> GLuint

Create a default splatmap texture based on height (grass low, rock mid, snow high).
"""
function _create_default_splatmap(td::TerrainData)
    rows, cols = size(td.heightmap)
    pixels = Vector{UInt8}(undef, rows * cols * 4)

    # Find height range
    min_h = minimum(td.heightmap)
    max_h = maximum(td.heightmap)
    range_h = max_h - min_h
    if range_h < 0.001f0
        range_h = 1.0f0
    end

    idx = 1
    for iz in 1:cols, ix in 1:rows
        h = td.heightmap[ix, iz]
        t = (h - min_h) / range_h  # 0..1 normalized height

        # Altitude-based splatting:
        # Layer 0 (R): grass (low), Layer 1 (G): rock (mid), Layer 2 (B): sand, Layer 3 (A): snow (high)
        r = clamp(1.0f0 - abs(t - 0.2f0) * 4.0f0, 0.0f0, 1.0f0)  # Grass peaks at 0.2
        g = clamp(1.0f0 - abs(t - 0.5f0) * 3.0f0, 0.0f0, 1.0f0)  # Rock peaks at 0.5
        b = clamp(1.0f0 - abs(t - 0.0f0) * 5.0f0, 0.0f0, 1.0f0)  # Sand at 0.0
        a = clamp((t - 0.7f0) * 3.3f0, 0.0f0, 1.0f0)               # Snow above 0.7

        total = r + g + b + a
        if total > 0.001f0
            r /= total; g /= total; b /= total; a /= total
        end

        pixels[idx]     = UInt8(clamp(round(Int, r * 255), 0, 255))
        pixels[idx + 1] = UInt8(clamp(round(Int, g * 255), 0, 255))
        pixels[idx + 2] = UInt8(clamp(round(Int, b * 255), 0, 255))
        pixels[idx + 3] = UInt8(clamp(round(Int, a * 255), 0, 255))
        idx += 4
    end

    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    tex = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, rows, cols, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glBindTexture(GL_TEXTURE_2D, GLuint(0))

    return tex
end

"""
    _get_or_upload_terrain_chunk!(cache, td, cx, cz, lod) -> GPUMesh

Get or upload a terrain chunk mesh to the GPU.
"""
function _get_or_upload_terrain_chunk!(cache::TerrainGPUCache, td::TerrainData,
                                        cx::Int, cz::Int, lod::Int)
    key = (cx, cz, lod)
    if haskey(cache.chunk_meshes, key)
        return cache.chunk_meshes[key]
    end

    chunk = td.chunks[cx, cz]
    mesh = chunk.lod_meshes[lod]

    gpu_mesh = upload_mesh_raw(mesh)
    cache.chunk_meshes[key] = gpu_mesh
    return gpu_mesh
end

"""
    upload_mesh_raw(mesh::MeshComponent) -> GPUMesh

Upload a mesh to GPU (standalone, not tied to entity cache).
"""
function upload_mesh_raw(mesh::MeshComponent)
    vao_ref = Ref(GLuint(0))
    glGenVertexArrays(1, vao_ref)
    vao = vao_ref[]
    glBindVertexArray(vao)

    # Position VBO
    vbo_ref = Ref(GLuint(0))
    glGenBuffers(1, vbo_ref)
    vbo = vbo_ref[]
    pos_data = reinterpret(Float32, mesh.vertices)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(pos_data), pos_data, GL_STATIC_DRAW)
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, C_NULL)
    glEnableVertexAttribArray(0)

    # Normal VBO
    nbo = GLuint(0)
    if !isempty(mesh.normals)
        nbo_ref = Ref(GLuint(0))
        glGenBuffers(1, nbo_ref)
        nbo = nbo_ref[]
        norm_data = reinterpret(Float32, mesh.normals)
        glBindBuffer(GL_ARRAY_BUFFER, nbo)
        glBufferData(GL_ARRAY_BUFFER, sizeof(norm_data), norm_data, GL_STATIC_DRAW)
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 0, C_NULL)
        glEnableVertexAttribArray(1)
    end

    # UV VBO
    ubo = GLuint(0)
    if !isempty(mesh.uvs)
        ubo_ref = Ref(GLuint(0))
        glGenBuffers(1, ubo_ref)
        ubo = ubo_ref[]
        uv_data = reinterpret(Float32, mesh.uvs)
        glBindBuffer(GL_ARRAY_BUFFER, ubo)
        glBufferData(GL_ARRAY_BUFFER, sizeof(uv_data), uv_data, GL_STATIC_DRAW)
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0, C_NULL)
        glEnableVertexAttribArray(2)
    end

    # Index buffer
    ebo_ref = Ref(GLuint(0))
    glGenBuffers(1, ebo_ref)
    ebo = ebo_ref[]
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ebo)
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(mesh.indices), mesh.indices, GL_STATIC_DRAW)

    glBindVertexArray(GLuint(0))

    gpu = GPUMesh()
    gpu.vao = vao
    gpu.vbo = vbo
    gpu.nbo = nbo
    gpu.ubo = ubo
    gpu.ebo = ebo
    gpu.index_count = Int32(length(mesh.indices))
    return gpu
end

"""
    render_terrain_gbuffer!(backend, td, comp, view, proj, cam_pos, frustum, texture_cache)

Render terrain chunks to the currently bound G-Buffer.
"""
function render_terrain_gbuffer!(backend, td::TerrainData, comp::TerrainComponent,
                                  view::Mat4f, proj::Mat4f, cam_pos::Vec3f,
                                  frustum::Frustum, texture_cache::TextureCache)
    cache = get_or_create_terrain_gpu_cache!(td.entity_id, td, comp, texture_cache)
    sp = cache.shader
    sp === nothing && return

    glUseProgram(sp.id)
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_NumLayers", Int32(length(comp.layers)))

    # Bind splatmap
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, cache.splatmap_texture)
    set_uniform!(sp, "u_Splatmap", Int32(0))

    # Bind layer textures
    layer_samplers = ["u_Layer0Albedo", "u_Layer1Albedo", "u_Layer2Albedo", "u_Layer3Albedo"]
    uv_scale_names = ["u_Layer0UVScale", "u_Layer1UVScale", "u_Layer2UVScale", "u_Layer3UVScale"]
    for i in 1:min(4, length(comp.layers))
        glActiveTexture(GL_TEXTURE0 + UInt32(i))
        if i <= length(cache.layer_textures) && cache.layer_textures[i] != GLuint(0)
            glBindTexture(GL_TEXTURE_2D, cache.layer_textures[i])
        end
        set_uniform!(sp, layer_samplers[i], Int32(i))
        set_uniform!(sp, uv_scale_names[i], comp.layers[i].uv_scale)
    end

    # Render visible chunks
    for cz in 1:td.num_chunks_z, cx in 1:td.num_chunks_x
        chunk = td.chunks[cx, cz]

        # Frustum cull by chunk AABB
        if !is_aabb_in_frustum(frustum, chunk.aabb_min, chunk.aabb_max)
            continue
        end

        gpu_mesh = _get_or_upload_terrain_chunk!(cache, td, cx, cz, chunk.current_lod)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
    end

    glBindVertexArray(GLuint(0))
end

# ---- Streaming terrain rendering ----

# GPU cache for streaming chunks (separate from fixed terrain)
const _STREAMING_GPU_CACHES = Dict{EntityID, TerrainGPUCache}()

function reset_streaming_gpu_caches!()
    for (_, cache) in _STREAMING_GPU_CACHES
        _destroy_terrain_gpu_cache!(cache)
    end
    empty!(_STREAMING_GPU_CACHES)
end

"""
    _get_or_upload_streaming_chunk!(cache, chunk, lod) -> GPUMesh

Upload a streaming chunk mesh to GPU.
"""
function _get_or_upload_streaming_chunk!(cache::TerrainGPUCache, chunk::TerrainChunk, lod::Int)
    key = (chunk.grid_x, chunk.grid_z, lod)
    if haskey(cache.chunk_meshes, key)
        return cache.chunk_meshes[key]
    end

    mesh = chunk.lod_meshes[lod]
    gpu_mesh = upload_mesh_raw(mesh)
    cache.chunk_meshes[key] = gpu_mesh
    return gpu_mesh
end

"""
    _cleanup_streaming_gpu_chunks!(cache, active_coords)

Remove GPU resources for chunks that are no longer active.
"""
function _cleanup_streaming_gpu_chunks!(cache::TerrainGPUCache, active_coords::Set{ChunkCoord})
    keys_to_remove = Tuple{Int,Int,Int}[]
    for key in keys(cache.chunk_meshes)
        coord = (key[1], key[2])
        if !(coord in active_coords)
            push!(keys_to_remove, key)
        end
    end
    for key in keys_to_remove
        gm = cache.chunk_meshes[key]
        if gm.vao != GLuint(0)
            glDeleteVertexArrays(1, Ref(gm.vao))
        end
        for buf in (gm.vbo, gm.nbo, gm.ubo, gm.ebo)
            if buf != GLuint(0)
                glDeleteBuffers(1, Ref(buf))
            end
        end
        delete!(cache.chunk_meshes, key)
    end
end

"""
    render_streaming_terrain_gbuffer!(backend, entity_id, streaming_sys, comp,
                                       view, proj, cam_pos, frustum, texture_cache)

Render streaming terrain chunks to the G-Buffer.
"""
function render_streaming_terrain_gbuffer!(backend, entity_id::EntityID,
                                            streaming_sys::ChunkStreamingSystem,
                                            comp::TerrainComponent,
                                            view::Mat4f, proj::Mat4f, cam_pos::Vec3f,
                                            frustum::Frustum, texture_cache::TextureCache)
    # Get or create GPU cache
    if !haskey(_STREAMING_GPU_CACHES, entity_id)
        cache = TerrainGPUCache()
        cache.shader = create_shader_program(TERRAIN_GBUFFER_VERTEX, TERRAIN_GBUFFER_FRAGMENT)
        # Generate a simple default splatmap for streaming
        cache.splatmap_texture = _create_default_streaming_splatmap()
        _STREAMING_GPU_CACHES[entity_id] = cache
    end
    cache = _STREAMING_GPU_CACHES[entity_id]
    sp = cache.shader
    sp === nothing && return

    # Cleanup GPU resources for unloaded chunks
    active_coords = Set{ChunkCoord}()
    for (coord, sc) in streaming_sys.active_chunks
        if sc.state == CHUNK_GENERATED || sc.state == CHUNK_UPLOADED
            push!(active_coords, coord)
        end
    end
    _cleanup_streaming_gpu_chunks!(cache, active_coords)

    glUseProgram(sp.id)
    set_uniform!(sp, "u_View", view)
    set_uniform!(sp, "u_Projection", proj)
    set_uniform!(sp, "u_NumLayers", Int32(length(comp.layers)))

    # Bind splatmap
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, cache.splatmap_texture)
    set_uniform!(sp, "u_Splatmap", Int32(0))

    # Bind layer textures
    layer_samplers = ["u_Layer0Albedo", "u_Layer1Albedo", "u_Layer2Albedo", "u_Layer3Albedo"]
    uv_scale_names = ["u_Layer0UVScale", "u_Layer1UVScale", "u_Layer2UVScale", "u_Layer3UVScale"]
    for i in 1:min(4, length(comp.layers))
        glActiveTexture(GL_TEXTURE0 + UInt32(i))
        if i <= length(cache.layer_textures) && cache.layer_textures[i] != GLuint(0)
            glBindTexture(GL_TEXTURE_2D, cache.layer_textures[i])
        end
        set_uniform!(sp, layer_samplers[i], Int32(i))
        set_uniform!(sp, uv_scale_names[i], comp.layers[i].uv_scale)
    end

    # Render visible streaming chunks
    for (coord, sc) in streaming_sys.active_chunks
        if sc.data === nothing
            continue
        end
        chunk = sc.data.terrain_chunk

        # Frustum cull
        if !is_aabb_in_frustum(frustum, chunk.aabb_min, chunk.aabb_max)
            continue
        end

        # LOD selection based on distance
        center = (chunk.aabb_min + chunk.aabb_max) * 0.5f0
        dx = cam_pos[1] - center[1]
        dz = cam_pos[3] - center[3]
        dist = sqrt(dx * dx + dz * dz)

        lod = length(chunk.lod_meshes)
        for i in 1:length(DEFAULT_CHUNK_LOD_DISTANCES)
            if dist < DEFAULT_CHUNK_LOD_DISTANCES[i]
                lod = i
                break
            end
        end
        lod = min(lod, length(chunk.lod_meshes))

        gpu_mesh = _get_or_upload_streaming_chunk!(cache, chunk, lod)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
    end

    glBindVertexArray(GLuint(0))
end

"""
    _create_default_streaming_splatmap() -> GLuint

Create a simple green splatmap for streaming terrain (all weight on layer 0).
"""
function _create_default_streaming_splatmap()::GLuint
    # 1x1 pixel: all weight on layer 0 (grass)
    pixels = UInt8[255, 0, 0, 0]
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    tex = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, tex)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glBindTexture(GL_TEXTURE_2D, GLuint(0))
    return tex
end
