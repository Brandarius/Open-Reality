# Terrain rendering: heightmap generation, chunk mesh generation, LOD

"""
    TerrainChunk

One piece of terrain. Each chunk has pre-generated meshes at multiple LOD levels.
"""
mutable struct TerrainChunk
    grid_x::Int
    grid_z::Int
    world_origin::Vec3f       # World-space corner of chunk
    lod_meshes::Vector{MeshComponent}   # LOD 0 = full detail
    current_lod::Int
    aabb_min::Vec3f
    aabb_max::Vec3f
end

"""
    TerrainData

Runtime terrain data — generated from a TerrainComponent.
"""
mutable struct TerrainData
    entity_id::EntityID
    heightmap::Matrix{Float32}         # (resolution+1) x (resolution+1)
    normal_map::Matrix{Vec3f}          # Per-vertex normals
    chunks::Matrix{TerrainChunk}       # Grid of chunks
    num_chunks_x::Int
    num_chunks_z::Int
    initialized::Bool
end

# Global terrain cache (entity_id → TerrainData)
const _TERRAIN_CACHE = Dict{EntityID, TerrainData}()

function reset_terrain_cache!()
    empty!(_TERRAIN_CACHE)
end

# ---- Perlin Noise ----

"""
    perlin_noise_2d(x, y, seed) -> Float64

Classic 2D Perlin noise using hash-based gradient table.
"""
function perlin_noise_2d(x::Float64, y::Float64, seed::Int=42)
    # Grid cell coordinates
    xi = floor(Int, x)
    yi = floor(Int, y)
    xf = x - xi
    yf = y - yi

    # Fade curves (6t^5 - 15t^4 + 10t^3)
    u = xf * xf * xf * (xf * (xf * 6.0 - 15.0) + 10.0)
    v = yf * yf * yf * (yf * (yf * 6.0 - 15.0) + 10.0)

    # Hash function for gradient selection
    h(ix, iy) = ((ix * 374761393 + iy * 668265263 + seed) * 1274126177) & 0xFF

    # Gradient dot product
    function grad_dot(hash, dx, dy)
        case = hash & 3
        if case == 0
            return dx + dy
        elseif case == 1
            return -dx + dy
        elseif case == 2
            return dx - dy
        else
            return -dx - dy
        end
    end

    # Four corners
    n00 = grad_dot(h(xi, yi), xf, yf)
    n10 = grad_dot(h(xi + 1, yi), xf - 1.0, yf)
    n01 = grad_dot(h(xi, yi + 1), xf, yf - 1.0)
    n11 = grad_dot(h(xi + 1, yi + 1), xf - 1.0, yf - 1.0)

    # Bilinear interpolation
    nx0 = n00 + u * (n10 - n00)
    nx1 = n01 + u * (n11 - n01)
    return nx0 + v * (nx1 - nx0)
end

"""
    fbm_noise_2d(x, y; octaves, frequency, persistence, seed) -> Float64

Fractal Brownian Motion: layered Perlin noise for natural-looking terrain.
"""
function fbm_noise_2d(x::Float64, y::Float64;
                       octaves::Int=6,
                       frequency::Float64=0.01,
                       persistence::Float64=0.5,
                       seed::Int=42)
    value = 0.0
    amplitude = 1.0
    freq = frequency
    max_value = 0.0

    for _ in 1:octaves
        value += perlin_noise_2d(x * freq, y * freq, seed) * amplitude
        max_value += amplitude
        amplitude *= persistence
        freq *= 2.0
    end

    return value / max_value
end

# ---- Heightmap Generation ----

"""
    generate_heightmap(source::HeightmapSource, res_x::Int, res_z::Int, max_height::Float32) -> Matrix{Float32}

Generate a heightmap grid. Returns a (res_x+1) x (res_z+1) matrix of heights.
"""
function generate_heightmap(source::HeightmapSource, res_x::Int, res_z::Int, max_height::Float32)
    hm = Matrix{Float32}(undef, res_x + 1, res_z + 1)

    # Resolve seed: prefer world_seed if set, otherwise use perlin_seed
    _effective_seed_int = source.perlin_seed
    _effective_seed_uint = UInt64(source.perlin_seed)
    if source.world_seed !== nothing
        _effective_seed_uint = derive_seed(source.world_seed, "heightmap")
        _effective_seed_int = seed_to_int(_effective_seed_uint)
    end

    if source.source_type == HEIGHTMAP_FLAT
        fill!(hm, 0.0f0)
    elseif source.source_type == HEIGHTMAP_PERLIN
        for iz in 0:res_z, ix in 0:res_x
            n = fbm_noise_2d(Float64(ix), Float64(iz);
                             octaves=source.perlin_octaves,
                             frequency=Float64(source.perlin_frequency),
                             persistence=Float64(source.perlin_persistence),
                             seed=_effective_seed_int)
            hm[ix + 1, iz + 1] = Float32(n * 0.5 + 0.5) * max_height
        end
    elseif source.source_type == HEIGHTMAP_SIMPLEX
        for iz in 0:res_z, ix in 0:res_x
            n = simplex_fbm_2d(Float64(ix), Float64(iz);
                               octaves=source.perlin_octaves,
                               frequency=Float64(source.perlin_frequency),
                               persistence=Float64(source.perlin_persistence),
                               seed=_effective_seed_uint)
            hm[ix + 1, iz + 1] = Float32(n * 0.5 + 0.5) * max_height
        end
    elseif source.source_type == HEIGHTMAP_RIDGED
        for iz in 0:res_z, ix in 0:res_x
            n = ridge_fbm_2d(Float64(ix), Float64(iz);
                             octaves=source.perlin_octaves,
                             frequency=Float64(source.perlin_frequency),
                             persistence=Float64(source.perlin_persistence),
                             seed=_effective_seed_uint)
            hm[ix + 1, iz + 1] = Float32(n) * max_height
        end
    elseif source.source_type == HEIGHTMAP_IMAGE
        # Load heightmap image if available
        if !isempty(source.image_path) && isfile(source.image_path)
            img = FileIO.load(source.image_path)
            img_h, img_w = size(img)
            for iz in 0:res_z, ix in 0:res_x
                # Bilinear sample from image
                u = Float64(ix) / Float64(res_x) * (img_w - 1)
                v = Float64(iz) / Float64(res_z) * (img_h - 1)
                px = clamp(round(Int, u) + 1, 1, img_w)
                pz = clamp(round(Int, v) + 1, 1, img_h)
                pixel = img[pz, px]
                hm[ix + 1, iz + 1] = Float32(red(pixel)) * max_height
            end
        else
            fill!(hm, 0.0f0)
        end
    end

    return hm
end

# ---- Normal Computation ----

"""
    compute_terrain_normals(hm::Matrix{Float32}, cell_size_x::Float32, cell_size_z::Float32) -> Matrix{Vec3f}

Compute per-vertex normals from heightmap using central finite differences.
"""
function compute_terrain_normals(hm::Matrix{Float32}, cell_size_x::Float32, cell_size_z::Float32)
    rows, cols = size(hm)
    normals = Matrix{Vec3f}(undef, rows, cols)

    for iz in 1:cols, ix in 1:rows
        # Central differences with clamped borders
        hL = hm[max(1, ix - 1), iz]
        hR = hm[min(rows, ix + 1), iz]
        hD = hm[ix, max(1, iz - 1)]
        hU = hm[ix, min(cols, iz + 1)]

        nx = (hL - hR) / (2.0f0 * cell_size_x)
        nz = (hD - hU) / (2.0f0 * cell_size_z)
        n = Vec3f(nx, 1.0f0, nz)
        len = sqrt(n[1]^2 + n[2]^2 + n[3]^2)
        normals[ix, iz] = len > 1.0f-10 ? n / len : Vec3f(0.0f0, 1.0f0, 0.0f0)
    end

    return normals
end

# ---- Chunk Mesh Generation ----

"""
    generate_chunk_mesh(hm, normals, chunk_ix, chunk_iz, chunk_size,
                        terrain_size, world_origin_x, world_origin_z, lod_level) -> MeshComponent

Generate a mesh for one terrain chunk at the given LOD level.
LOD 0 = full detail, LOD N = every 2^N-th vertex.
"""
function generate_chunk_mesh(hm::Matrix{Float32}, normals::Matrix{Vec3f},
                              chunk_ix::Int, chunk_iz::Int,
                              chunk_size::Int,
                              terrain_size::Vec2f,
                              world_origin_x::Float32, world_origin_z::Float32,
                              lod_level::Int)
    rows, cols = size(hm)
    step = 1 << lod_level   # Power of two simplification
    cell_size_x = terrain_size[1] / Float32(rows - 1)
    cell_size_z = terrain_size[2] / Float32(cols - 1)

    # Start/end indices in heightmap
    start_x = (chunk_ix - 1) * (chunk_size - 1) + 1
    start_z = (chunk_iz - 1) * (chunk_size - 1) + 1
    end_x = min(start_x + chunk_size - 1, rows)
    end_z = min(start_z + chunk_size - 1, cols)

    # Collect vertices at this LOD level
    vertices = Point3f[]
    mesh_normals = Vec3f[]
    uvs = Vec2f[]
    indices = UInt32[]

    # Vertex grid (at LOD step)
    vert_ix = 0
    ix_map = Dict{Tuple{Int,Int}, UInt32}()

    for iz in start_z:step:end_z
        for ix in start_x:step:end_x
            cix = clamp(ix, 1, rows)
            ciz = clamp(iz, 1, cols)
            wx = world_origin_x + Float32(cix - 1) * cell_size_x
            wz = world_origin_z + Float32(ciz - 1) * cell_size_z
            wy = hm[cix, ciz]

            push!(vertices, Point3f(wx, wy, wz))
            push!(mesh_normals, normals[cix, ciz])
            push!(uvs, Vec2f(Float32(cix - 1) / Float32(rows - 1),
                              Float32(ciz - 1) / Float32(cols - 1)))
            ix_map[(ix, iz)] = UInt32(vert_ix)
            vert_ix += 1
        end
    end

    # Generate triangle indices
    xs = collect(start_x:step:end_x)
    zs = collect(start_z:step:end_z)
    for j in 1:(length(zs) - 1)
        for i in 1:(length(xs) - 1)
            v00 = ix_map[(xs[i], zs[j])]
            v10 = ix_map[(xs[i+1], zs[j])]
            v01 = ix_map[(xs[i], zs[j+1])]
            v11 = ix_map[(xs[i+1], zs[j+1])]

            push!(indices, v00, v10, v01)
            push!(indices, v10, v11, v01)
        end
    end

    return MeshComponent(
        vertices=vertices,
        normals=mesh_normals,
        uvs=uvs,
        indices=indices
    )
end

# ---- Terrain Initialization ----

"""
    initialize_terrain!(entity_id::EntityID, comp::TerrainComponent) -> TerrainData

Build heightmap, normals, and chunk meshes for a terrain entity.
"""
function initialize_terrain!(entity_id::EntityID, comp::TerrainComponent)
    # Compute total resolution from chunk grid
    chunks_x = max(1, round(Int, comp.terrain_size[1] / Float32(comp.chunk_size - 1)))
    chunks_z = max(1, round(Int, comp.terrain_size[2] / Float32(comp.chunk_size - 1)))
    res_x = chunks_x * (comp.chunk_size - 1)
    res_z = chunks_z * (comp.chunk_size - 1)

    # Generate heightmap
    hm = generate_heightmap(comp.heightmap, res_x, res_z, comp.max_height)

    cell_size_x = comp.terrain_size[1] / Float32(res_x)
    cell_size_z = comp.terrain_size[2] / Float32(res_z)

    # Compute normals
    normals = compute_terrain_normals(hm, cell_size_x, cell_size_z)

    # World origin (terrain centered at entity position)
    origin_x = -comp.terrain_size[1] / 2.0f0
    origin_z = -comp.terrain_size[2] / 2.0f0

    # Generate chunks with LOD meshes
    chunks = Matrix{TerrainChunk}(undef, chunks_x, chunks_z)
    for cz in 1:chunks_z, cx in 1:chunks_x
        lod_meshes = MeshComponent[]
        for lod in 0:(comp.num_lod_levels - 1)
            push!(lod_meshes, generate_chunk_mesh(hm, normals, cx, cz,
                                                    comp.chunk_size, comp.terrain_size,
                                                    origin_x, origin_z, lod))
        end

        # Compute chunk AABB
        start_x = (cx - 1) * (comp.chunk_size - 1) + 1
        start_z = (cz - 1) * (comp.chunk_size - 1) + 1
        end_x = min(start_x + comp.chunk_size - 1, res_x + 1)
        end_z = min(start_z + comp.chunk_size - 1, res_z + 1)

        min_h = Float32(Inf)
        max_h = Float32(-Inf)
        for iz in start_z:end_z, ix in start_x:end_x
            h = hm[ix, iz]
            min_h = min(min_h, h)
            max_h = max(max_h, h)
        end

        world_x0 = origin_x + Float32(start_x - 1) * cell_size_x
        world_z0 = origin_z + Float32(start_z - 1) * cell_size_z
        world_x1 = origin_x + Float32(end_x - 1) * cell_size_x
        world_z1 = origin_z + Float32(end_z - 1) * cell_size_z

        chunks[cx, cz] = TerrainChunk(
            cx, cz,
            Vec3f(world_x0, 0.0f0, world_z0),
            lod_meshes,
            1,  # Start at LOD 0
            Vec3f(world_x0, min_h, world_z0),
            Vec3f(world_x1, max_h, world_z1)
        )
    end

    td = TerrainData(entity_id, hm, normals, chunks, chunks_x, chunks_z, true)
    _TERRAIN_CACHE[entity_id] = td
    return td
end

# ---- Chunk LOD Update ----

"""
    update_terrain_lod!(td::TerrainData, cam_pos::Vec3f, chunk_lod_distances::Vector{Float32})

Update each chunk's current LOD level based on camera distance.
"""
function update_terrain_lod!(td::TerrainData, cam_pos::Vec3f, chunk_lod_distances::Vector{Float32})
    for cz in 1:td.num_chunks_z, cx in 1:td.num_chunks_x
        chunk = td.chunks[cx, cz]
        # Distance from camera to chunk center
        center = (chunk.aabb_min + chunk.aabb_max) * 0.5f0
        dx = cam_pos[1] - center[1]
        dz = cam_pos[3] - center[3]
        dist = sqrt(dx * dx + dz * dz)

        # Select LOD
        new_lod = length(chunk.lod_meshes)  # Coarsest
        for i in 1:length(chunk_lod_distances)
            if dist < chunk_lod_distances[i]
                new_lod = i
                break
            end
        end
        new_lod = min(new_lod, length(chunk.lod_meshes))
        chunk.current_lod = new_lod
    end
end

# ---- AABB frustum culling for chunks ----

"""
    is_aabb_in_frustum(frustum::Frustum, aabb_min::Vec3f, aabb_max::Vec3f) -> Bool

Test if an AABB is at least partially inside the frustum.
"""
function is_aabb_in_frustum(frustum::Frustum, aabb_min::Vec3f, aabb_max::Vec3f)
    for plane in frustum.planes
        # Find the AABB vertex most in the direction of the plane normal (p-vertex)
        px = plane.a >= 0 ? aabb_max[1] : aabb_min[1]
        py = plane.b >= 0 ? aabb_max[2] : aabb_min[2]
        pz = plane.c >= 0 ? aabb_max[3] : aabb_min[3]

        # If the p-vertex is behind the plane, the AABB is fully outside
        if plane.a * px + plane.b * py + plane.c * pz + plane.d < 0
            return false
        end
    end
    return true
end

# ---- Height query (bilinear interpolation) ----

"""
    heightmap_get_height(td::TerrainData, comp::TerrainComponent, world_x::Float64, world_z::Float64) -> Float64

Query terrain height at a world position using bilinear interpolation.
"""
function heightmap_get_height(td::TerrainData, comp::TerrainComponent, world_x::Float64, world_z::Float64)
    rows, cols = size(td.heightmap)

    # Convert world coords to heightmap coords
    origin_x = -Float64(comp.terrain_size[1]) / 2.0
    origin_z = -Float64(comp.terrain_size[2]) / 2.0
    cell_size_x = Float64(comp.terrain_size[1]) / Float64(rows - 1)
    cell_size_z = Float64(comp.terrain_size[2]) / Float64(cols - 1)

    fx = (world_x - origin_x) / cell_size_x
    fz = (world_z - origin_z) / cell_size_z

    ix = floor(Int, fx)
    iz = floor(Int, fz)
    tx = fx - ix
    tz = fz - iz

    # Clamp to grid bounds
    ix = clamp(ix + 1, 1, rows - 1)
    iz = clamp(iz + 1, 1, cols - 1)
    ix1 = min(ix + 1, rows)
    iz1 = min(iz + 1, cols)

    # Bilinear interpolation
    h00 = Float64(td.heightmap[ix, iz])
    h10 = Float64(td.heightmap[ix1, iz])
    h01 = Float64(td.heightmap[ix, iz1])
    h11 = Float64(td.heightmap[ix1, iz1])

    return h00 * (1.0 - tx) * (1.0 - tz) +
           h10 * tx * (1.0 - tz) +
           h01 * (1.0 - tx) * tz +
           h11 * tx * tz
end
