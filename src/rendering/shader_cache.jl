# =============================================================================
# Shader Cache — persistent disk-based caching for compiled shader programs
# =============================================================================
#
# Supports OpenGL (glGetProgramBinary blobs) and Vulkan (SPIR-V bytecode).
# Cache keys are hashed from shader source + driver fingerprint so entries
# auto-invalidate when source changes or drivers update.

import TOML

# =============================================================================
# Types
# =============================================================================

struct ShaderCacheEntry
    key::String            # hex hash string
    backend::String        # "opengl" or "vulkan"
    source_hash::UInt64    # hash of shader source(s)
    driver_hash::UInt64    # hash of driver info (GL vendor+renderer+version; 0 for Vulkan)
    file_path::String      # relative path within cache dir (e.g. "opengl/abc123.bin")
    created_at::Float64    # time() when cached
    size_bytes::Int64      # file size in bytes
end

mutable struct ShaderCache
    cache_dir::String
    manifest::Dict{String, ShaderCacheEntry}
    enabled::Bool
    dirty::Bool

    ShaderCache() = new("", Dict{String, ShaderCacheEntry}(), false, false)
end

# Global singleton
const _SHADER_CACHE = Ref{ShaderCache}(ShaderCache())

# =============================================================================
# Cache key computation
# =============================================================================

"""
    shader_cache_key(sources...; driver_info="") -> String

Compute a hex hash key from one or more shader source strings, optionally
including a driver fingerprint string for backend-specific invalidation.
"""
function shader_cache_key(sources::String...; driver_info::String = "")::String
    h = UInt64(0)
    for src in sources
        h = hash(src, h)
    end
    if !isempty(driver_info)
        h = hash(driver_info, h)
    end
    return string(h, base=16)
end

# =============================================================================
# Initialization
# =============================================================================

"""
    init_shader_cache!(project_root::String)

Initialize the global shader cache. Creates the cache directory structure
and loads the manifest from disk. Set `OPENREALITY_NO_SHADER_CACHE=1` to disable.
"""
function init_shader_cache!(project_root::String)
    cache = _SHADER_CACHE[]
    cache.cache_dir = joinpath(project_root, ".openreality", "shader_cache")

    # Respect env var to disable
    if get(ENV, "OPENREALITY_NO_SHADER_CACHE", "") == "1"
        cache.enabled = false
        @info "Shader cache disabled via OPENREALITY_NO_SHADER_CACHE"
        return nothing
    end

    # Create directory structure
    mkpath(joinpath(cache.cache_dir, "opengl"))
    mkpath(joinpath(cache.cache_dir, "vulkan"))

    # Load manifest
    manifest_path = joinpath(cache.cache_dir, "cache_manifest.toml")
    if isfile(manifest_path)
        _load_manifest!(cache, manifest_path)
    end

    cache.enabled = true
    @info "Shader cache initialized" dir=cache.cache_dir entries=length(cache.manifest)
    return nothing
end

# =============================================================================
# Lookup / Store / Clear
# =============================================================================

"""
    get_shader_cache() -> ShaderCache

Return the global shader cache singleton.
"""
function get_shader_cache()::ShaderCache
    return _SHADER_CACHE[]
end

"""
    cache_lookup(key::String) -> Union{Vector{UInt8}, Nothing}

Look up a cached shader binary by key. Returns the raw bytes or `nothing`.
"""
function cache_lookup(key::String)::Union{Vector{UInt8}, Nothing}
    cache = _SHADER_CACHE[]
    !cache.enabled && return nothing

    entry = get(cache.manifest, key, nothing)
    entry === nothing && return nothing

    file_path = joinpath(cache.cache_dir, entry.file_path)
    if !isfile(file_path)
        # Stale manifest entry — remove it
        delete!(cache.manifest, key)
        cache.dirty = true
        return nothing
    end

    return read(file_path)
end

"""
    cache_store!(key::String, data::Vector{UInt8}, backend::String;
                 source_hash::UInt64=UInt64(0), driver_hash::UInt64=UInt64(0))

Store shader binary data on disk and update the manifest.
"""
function cache_store!(key::String, data::Vector{UInt8}, backend::String;
                      source_hash::UInt64 = UInt64(0), driver_hash::UInt64 = UInt64(0))
    cache = _SHADER_CACHE[]
    !cache.enabled && return nothing

    ext = backend == "vulkan" ? "spv" : "bin"
    rel_path = joinpath(backend, "$(key).$(ext)")
    abs_path = joinpath(cache.cache_dir, rel_path)

    # Write binary — use temp file + rename for atomicity
    tmp_path = abs_path * ".tmp"
    try
        write(tmp_path, data)
        mv(tmp_path, abs_path; force=true)
    catch e
        isfile(tmp_path) && rm(tmp_path; force=true)
        @warn "Failed to write shader cache entry" key=key exception=e
        return nothing
    end

    cache.manifest[key] = ShaderCacheEntry(
        key, backend, source_hash, driver_hash, rel_path,
        time(), Int64(length(data))
    )
    cache.dirty = true
    _flush_manifest!(cache)
    return nothing
end

"""
    cache_clear!()

Delete the entire shader cache directory and reset the manifest.
"""
function cache_clear!()
    cache = _SHADER_CACHE[]
    if !isempty(cache.cache_dir) && isdir(cache.cache_dir)
        rm(cache.cache_dir; recursive=true, force=true)
    end
    empty!(cache.manifest)
    cache.dirty = false
    @info "Shader cache cleared"
    return nothing
end

"""
    flush_shader_cache!()

Write the manifest to disk if it has pending changes.
"""
function flush_shader_cache!()
    cache = _SHADER_CACHE[]
    if cache.dirty
        _flush_manifest!(cache)
    end
end

# =============================================================================
# Manifest serialization
# =============================================================================

function _load_manifest!(cache::ShaderCache, path::String)
    try
        data = TOML.parsefile(path)
        entries = get(data, "entries", Dict())
        for (key, vals) in entries
            cache.manifest[key] = ShaderCacheEntry(
                key,
                get(vals, "backend", ""),
                parse(UInt64, get(vals, "source_hash", "0")),
                parse(UInt64, get(vals, "driver_hash", "0")),
                get(vals, "file_path", ""),
                get(vals, "created_at", 0.0),
                get(vals, "size_bytes", 0),
            )
        end
    catch e
        @warn "Failed to load shader cache manifest, starting fresh" exception=e
        empty!(cache.manifest)
    end
end

function _flush_manifest!(cache::ShaderCache)
    isempty(cache.cache_dir) && return

    manifest_path = joinpath(cache.cache_dir, "cache_manifest.toml")
    entries = Dict{String, Any}()
    for (key, entry) in cache.manifest
        entries[key] = Dict{String, Any}(
            "backend" => entry.backend,
            "source_hash" => string(entry.source_hash),
            "driver_hash" => string(entry.driver_hash),
            "file_path" => entry.file_path,
            "created_at" => entry.created_at,
            "size_bytes" => entry.size_bytes,
        )
    end

    data = Dict{String, Any}("entries" => entries)

    tmp_path = manifest_path * ".tmp"
    try
        open(tmp_path, "w") do io
            TOML.print(io, data)
        end
        mv(tmp_path, manifest_path; force=true)
        cache.dirty = false
    catch e
        isfile(tmp_path) && rm(tmp_path; force=true)
        @warn "Failed to flush shader cache manifest" exception=e
    end
end

# =============================================================================
# Project root detection
# =============================================================================

"""
    _find_project_root() -> String

Walk up from the source directory looking for `Project.toml`.
"""
function _find_project_root()::String
    dir = abspath(joinpath(@__DIR__, "..", ".."))
    while true
        if isfile(joinpath(dir, "Project.toml"))
            return dir
        end
        parent = dirname(dir)
        parent == dir && break
        dir = parent
    end
    return pwd()
end

# =============================================================================
# Shader cache warm-up (called by CLI `orcli cache shaders`)
# =============================================================================

"""
    _warm_shader_cache!(backend::String = "opengl")

Pre-compile all known shaders and store them in the persistent cache.
For OpenGL, creates a hidden window for a GL context. For Vulkan, compiles
GLSL to SPIR-V (no GPU context needed).
"""
function _warm_shader_cache!(backend::String = "opengl")
    project_root = _find_project_root()

    if backend == "opengl"
        # Create a hidden OpenGL context (needed for shader compilation)
        ensure_glfw_init!()
        GLFW.WindowHint(GLFW.VISIBLE, false)
        window = GLFW.CreateWindow(1, 1, "ShaderCacheWarm")
        GLFW.MakeContextCurrent(window)

        _capture_gl_driver_info!()
        init_shader_cache!(project_root)

        @info "Warming OpenGL shader cache..."
        cached_count = 0

        # --- Fixed (non-variant) shader programs ---
        fixed_shader_pairs = [
            # Deferred pipeline
            (DEFERRED_LIGHTING_VERTEX_SHADER, DEFERRED_LIGHTING_FRAGMENT_SHADER),
            # Forward PBR (transparent objects)
            (PBR_VERTEX_SHADER, PBR_FRAGMENT_SHADER),
            # Post-processing
            (PP_QUAD_VERTEX, PP_BRIGHT_EXTRACT_FRAGMENT),
            (PP_QUAD_VERTEX, PP_BLUR_FRAGMENT),
            (PP_QUAD_VERTEX, PP_COMPOSITE_FRAGMENT),
            (PP_QUAD_VERTEX, PP_FXAA_FRAGMENT),
            # Shadows
            (SHADOW_VERTEX_SHADER, SHADOW_FRAGMENT_SHADER),
            # SSAO
            (SSAO_VERTEX_SHADER, SSAO_FRAGMENT_SHADER),
            (SSAO_VERTEX_SHADER, SSAO_BLUR_FRAGMENT_SHADER),
            # SSR
            (SSR_VERTEX_SHADER, SSR_FRAGMENT_SHADER),
            # DoF
            (PP_QUAD_VERTEX, DOF_COC_FRAGMENT),
            (PP_QUAD_VERTEX, DOF_BLUR_FRAGMENT),
            (PP_QUAD_VERTEX, DOF_COMPOSITE_FRAGMENT),
            # Motion blur
            (PP_QUAD_VERTEX, MBLUR_VELOCITY_FRAGMENT),
            (PP_QUAD_VERTEX, MBLUR_BLUR_FRAGMENT),
            # IBL
            (EQUIRECT_TO_CUBEMAP_VERTEX, EQUIRECT_TO_CUBEMAP_FRAGMENT),
            (EQUIRECT_TO_CUBEMAP_VERTEX, IRRADIANCE_CONVOLUTION_FRAGMENT),
            (EQUIRECT_TO_CUBEMAP_VERTEX, PREFILTER_CONVOLUTION_FRAGMENT),
            (BRDF_LUT_VERTEX, BRDF_LUT_FRAGMENT),
            # UI
            (_UI_VERTEX_SHADER, _UI_FRAGMENT_SHADER),
            # CPU particles
            (PARTICLE_VERTEX_SHADER, PARTICLE_FRAGMENT_SHADER),
        ]

        for (vert, frag) in fixed_shader_pairs
            try
                sp = create_shader_program(vert, frag)
                destroy_shader_program!(sp)
                cached_count += 1
            catch e
                @warn "Failed to warm shader pair" exception=e
            end
        end

        # --- Compute shaders (if supported) ---
        if _has_compute_shader_support()
            compute_shaders = [
                GPU_PARTICLE_EMISSION_SHADER,
                GPU_PARTICLE_SIMULATION_SHADER,
                GPU_PARTICLE_COMPACT_SHADER,
                GPU_PARTICLE_INDIRECT_UPDATE_SHADER,
            ]
            for src in compute_shaders
                try
                    sp = create_compute_shader_program(src)
                    destroy_shader_program!(sp)
                    cached_count += 1
                catch e
                    @warn "Failed to warm compute shader" exception=e
                end
            end

            # GPU particle render shader
            try
                sp = create_shader_program(GPU_PARTICLE_RENDER_VS, GPU_PARTICLE_RENDER_FS)
                destroy_shader_program!(sp)
                cached_count += 1
            catch e
                @warn "Failed to warm GPU particle render shader" exception=e
            end
        end

        # --- Common GBuffer shader variants ---
        common_variants = [
            ShaderVariantKey(Set{ShaderFeature}()),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_METALLIC_ROUGHNESS_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_METALLIC_ROUGHNESS_MAP, FEATURE_AO_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_METALLIC_ROUGHNESS_MAP, FEATURE_EMISSIVE_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_METALLIC_ROUGHNESS_MAP, FEATURE_AO_MAP, FEATURE_EMISSIVE_MAP])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_ALPHA_CUTOFF])),
            ShaderVariantKey(Set([FEATURE_LOD_DITHER])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_LOD_DITHER])),
            ShaderVariantKey(Set([FEATURE_INSTANCED])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_INSTANCED])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_INSTANCED])),
            ShaderVariantKey(Set([FEATURE_SKINNING])),
            ShaderVariantKey(Set([FEATURE_ALBEDO_MAP, FEATURE_NORMAL_MAP, FEATURE_SKINNING])),
            ShaderVariantKey(Set([FEATURE_TERRAIN_SPLATMAP])),
        ]

        lib = ShaderLibrary{ShaderProgram}(
            "WarmCache", GBUFFER_VERTEX_SHADER, GBUFFER_FRAGMENT_SHADER,
            create_shader_program
        )

        for variant in common_variants
            try
                get_or_compile_variant!(lib, variant)
                cached_count += 1
            catch e
                @warn "Failed to warm GBuffer variant" features=variant.features exception=e
            end
        end

        # Terrain GBuffer variants
        terrain_lib = ShaderLibrary{ShaderProgram}(
            "WarmCacheTerrain", TERRAIN_GBUFFER_VERTEX, TERRAIN_GBUFFER_FRAGMENT,
            create_shader_program
        )
        try
            get_or_compile_variant!(terrain_lib, ShaderVariantKey(Set([FEATURE_TERRAIN_SPLATMAP])))
            cached_count += 1
        catch e
            @warn "Failed to warm terrain variant" exception=e
        end

        destroy_shader_library!(lib)
        destroy_shader_library!(terrain_lib)

        flush_shader_cache!()
        GLFW.DestroyWindow(window)
        @info "Shader cache warming complete" cached_count=cached_count

    elseif backend == "vulkan"
        init_shader_cache!(project_root)
        @info "Warming Vulkan SPIR-V cache..."
        @info "Vulkan SPIR-V cache warming is handled automatically on first use."
        @info "Run a scene with VulkanBackend to populate the cache."
    else
        @error "Unknown backend: $backend. Supported: opengl, vulkan"
    end
end
