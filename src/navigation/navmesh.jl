# =============================================================================
# NavMesh Generation — build navigation meshes from geometry
# =============================================================================

"""
    build_navmesh(vertices::Vector{Vec3f}, triangles::Vector{NTuple{3, Int}}) -> NavMesh

Build a NavMesh from a set of vertices and triangle indices.
Computes adjacency (shared-edge neighbors) automatically.

Triangle indices are 1-based and refer into `vertices`.
"""
function build_navmesh(vertices::Vector{Vec3f}, triangles::Vector{NTuple{3, Int}})
    polygons = NavMeshPolygon[]
    # Edge → polygon index map for adjacency detection
    # An edge is stored as (min_idx, max_idx) to ensure canonical ordering
    edge_to_poly = Dict{Tuple{Int, Int}, Vector{Int}}()

    for (poly_idx, tri) in enumerate(triangles)
        i1, i2, i3 = tri
        centroid = (vertices[i1] + vertices[i2] + vertices[i3]) / 3.0f0
        push!(polygons, NavMeshPolygon([i1, i2, i3], centroid, Int[]))

        # Register edges
        for (a, b) in ((i1, i2), (i2, i3), (i3, i1))
            edge = a < b ? (a, b) : (b, a)
            if !haskey(edge_to_poly, edge)
                edge_to_poly[edge] = Int[]
            end
            push!(edge_to_poly[edge], poly_idx)
        end
    end

    # Build adjacency from shared edges
    for (_, poly_indices) in edge_to_poly
        if length(poly_indices) == 2
            a, b = poly_indices[1], poly_indices[2]
            if !(b in polygons[a].neighbors)
                push!(polygons[a].neighbors, b)
            end
            if !(a in polygons[b].neighbors)
                push!(polygons[b].neighbors, a)
            end
        end
    end

    return NavMesh(vertices, polygons)
end

"""
    build_navmesh_from_grid(width::Int, depth::Int; cell_size::Float32=1.0f0,
                            origin::Vec3f=Vec3f(0,0,0),
                            height_fn=nothing,
                            walkable_fn=nothing) -> NavMesh

Generate a grid-based navmesh. Each grid cell produces 2 triangles.

- `height_fn(x, z) -> Float32`: optional function returning Y height at world (x, z)
- `walkable_fn(x, z) -> Bool`: optional function returning whether cell at grid (x, z) is walkable
"""
function build_navmesh_from_grid(width::Int, depth::Int;
                                  cell_size::Float32 = 1.0f0,
                                  origin::Vec3f = Vec3f(0, 0, 0),
                                  height_fn = nothing,
                                  walkable_fn = nothing)
    vertices = Vec3f[]
    triangles = NTuple{3, Int}[]

    # Generate vertex grid (width+1) x (depth+1)
    for iz in 0:depth
        for ix in 0:width
            wx = origin[1] + Float32(ix) * cell_size
            wz = origin[3] + Float32(iz) * cell_size
            wy = height_fn !== nothing ? height_fn(wx, wz) : origin[2]
            push!(vertices, Vec3f(wx, wy, wz))
        end
    end

    cols = width + 1
    for iz in 0:depth-1
        for ix in 0:width-1
            # Check walkability
            if walkable_fn !== nothing && !walkable_fn(ix, iz)
                continue
            end

            # Vertex indices (1-based)
            bl = iz * cols + ix + 1       # bottom-left
            br = bl + 1                   # bottom-right
            tl = (iz + 1) * cols + ix + 1 # top-left
            tr = tl + 1                   # top-right

            # Two triangles per cell
            push!(triangles, (bl, br, tl))
            push!(triangles, (br, tr, tl))
        end
    end

    return build_navmesh(vertices, triangles)
end

"""
    find_containing_polygon(navmesh::NavMesh, point::Vec3f) -> Union{Int, Nothing}

Find which polygon in the navmesh contains the given point (XZ projection).
Returns the polygon index or nothing if the point is outside the navmesh.
"""
function find_containing_polygon(navmesh::NavMesh, point::Vec3f)::Union{Int, Nothing}
    best_idx = nothing
    best_dist_sq = Inf32

    for (idx, poly) in enumerate(navmesh.polygons)
        if _point_in_polygon_xz(navmesh.vertices, poly.vertex_indices, point)
            # If multiple matches (shouldn't happen in a proper navmesh), pick closest centroid
            d = _dist_sq_xz(poly.centroid, point)
            if d < best_dist_sq
                best_dist_sq = d
                best_idx = idx
            end
        end
    end

    # Fallback: find nearest polygon by centroid
    if best_idx === nothing
        for (idx, poly) in enumerate(navmesh.polygons)
            d = _dist_sq_xz(poly.centroid, point)
            if d < best_dist_sq
                best_dist_sq = d
                best_idx = idx
            end
        end
    end

    return best_idx
end

"""Test if a point is inside a convex polygon (XZ projection, 2D cross product test)."""
function _point_in_polygon_xz(vertices::Vector{Vec3f}, indices::Vector{Int}, point::Vec3f)::Bool
    n = length(indices)
    n < 3 && return false

    for i in 1:n
        j = i % n + 1
        vi = vertices[indices[i]]
        vj = vertices[indices[j]]
        # 2D cross product in XZ plane
        cross = (vj[1] - vi[1]) * (point[3] - vi[3]) - (vj[3] - vi[3]) * (point[1] - vi[1])
        if cross < 0
            return false
        end
    end
    return true
end

@inline function _dist_sq_xz(a::Vec3f, b::Vec3f)::Float32
    dx = a[1] - b[1]
    dz = a[3] - b[3]
    return dx * dx + dz * dz
end
