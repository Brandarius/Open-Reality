# =============================================================================
# A* Pathfinding on NavMesh with Funnel Algorithm for path smoothing
# =============================================================================

# Simple min-heap for A* open set (avoids DataStructures dependency)
mutable struct _AStarEntry
    node::Int
    f_score::Float32
end

mutable struct _MinHeap
    data::Vector{_AStarEntry}
    _MinHeap() = new(_AStarEntry[])
end

function _heap_push!(h::_MinHeap, node::Int, f::Float32)
    push!(h.data, _AStarEntry(node, f))
    _heap_sift_up!(h, length(h.data))
end

function _heap_pop!(h::_MinHeap)::Int
    top = h.data[1]
    h.data[1] = h.data[end]
    pop!(h.data)
    !isempty(h.data) && _heap_sift_down!(h, 1)
    return top.node
end

Base.isempty(h::_MinHeap) = isempty(h.data)

function _heap_sift_up!(h::_MinHeap, idx::Int)
    while idx > 1
        parent = idx >> 1
        if h.data[idx].f_score < h.data[parent].f_score
            h.data[idx], h.data[parent] = h.data[parent], h.data[idx]
            idx = parent
        else
            break
        end
    end
end

function _heap_sift_down!(h::_MinHeap, idx::Int)
    n = length(h.data)
    while true
        smallest = idx
        left = 2 * idx
        right = 2 * idx + 1
        if left <= n && h.data[left].f_score < h.data[smallest].f_score
            smallest = left
        end
        if right <= n && h.data[right].f_score < h.data[smallest].f_score
            smallest = right
        end
        if smallest != idx
            h.data[idx], h.data[smallest] = h.data[smallest], h.data[idx]
            idx = smallest
        else
            break
        end
    end
end

"""
    find_path(navmesh::NavMesh, start::Vec3f, goal::Vec3f) -> NavPath

Find a path from `start` to `goal` on the navmesh using A* + funnel smoothing.
Returns an empty NavPath if no path exists.
"""
function find_path(navmesh::NavMesh, start::Vec3f, goal::Vec3f)::NavPath
    start_poly = find_containing_polygon(navmesh, start)
    goal_poly = find_containing_polygon(navmesh, goal)

    (start_poly === nothing || goal_poly === nothing) && return NavPath()

    # Same polygon — direct path
    if start_poly == goal_poly
        d = sqrt(_dist_sq_xz(start, goal))
        return NavPath([start, goal], d)
    end

    # A* on polygon graph
    poly_path = _astar_polygon_path(navmesh, start_poly, goal_poly)
    isempty(poly_path) && return NavPath()

    # Build waypoints using funnel algorithm
    waypoints = _funnel_smooth(navmesh, start, goal, poly_path)

    # Compute total path length
    total = 0.0f0
    for i in 1:length(waypoints)-1
        dx = waypoints[i+1][1] - waypoints[i][1]
        dy = waypoints[i+1][2] - waypoints[i][2]
        dz = waypoints[i+1][3] - waypoints[i][3]
        total += sqrt(dx*dx + dy*dy + dz*dz)
    end

    return NavPath(waypoints, total)
end

"""A* search over polygon adjacency graph. Returns polygon index path."""
function _astar_polygon_path(navmesh::NavMesh, start_idx::Int, goal_idx::Int)::Vector{Int}
    goal_centroid = navmesh.polygons[goal_idx].centroid

    g_score = Dict{Int, Float32}(start_idx => 0.0f0)
    came_from = Dict{Int, Int}()
    closed = Set{Int}()

    open_set = _MinHeap()
    _heap_push!(open_set, start_idx, sqrt(_dist_sq_xz(navmesh.polygons[start_idx].centroid, goal_centroid)))

    while !isempty(open_set)
        current = _heap_pop!(open_set)

        # Skip if already processed (heap may contain duplicates)
        current in closed && continue
        push!(closed, current)

        if current == goal_idx
            path = Int[current]
            while haskey(came_from, current)
                current = came_from[current]
                pushfirst!(path, current)
            end
            return path
        end

        current_g = g_score[current]

        for neighbor_idx in navmesh.polygons[current].neighbors
            neighbor_idx in closed && continue

            tentative_g = current_g + sqrt(_dist_sq_xz(
                navmesh.polygons[current].centroid,
                navmesh.polygons[neighbor_idx].centroid
            ))

            if tentative_g < get(g_score, neighbor_idx, Inf32)
                came_from[neighbor_idx] = current
                g_score[neighbor_idx] = tentative_g
                f = tentative_g + sqrt(_dist_sq_xz(navmesh.polygons[neighbor_idx].centroid, goal_centroid))
                _heap_push!(open_set, neighbor_idx, f)
            end
        end
    end

    return Int[]  # No path found
end

"""
Find the shared edge (portal) between two adjacent polygons.
Returns the two vertex positions forming the portal.
"""
function _find_portal(navmesh::NavMesh, poly_a_idx::Int, poly_b_idx::Int)::Tuple{Vec3f, Vec3f}
    poly_a = navmesh.polygons[poly_a_idx]
    poly_b = navmesh.polygons[poly_b_idx]

    shared = Int[]
    for vi in poly_a.vertex_indices
        if vi in poly_b.vertex_indices
            push!(shared, vi)
        end
    end

    if length(shared) >= 2
        return (navmesh.vertices[shared[1]], navmesh.vertices[shared[2]])
    end

    # Fallback: use centroids (shouldn't happen with valid navmesh)
    return (poly_a.centroid, poly_b.centroid)
end

"""
Simple Funnel Algorithm (SSF) for string-pulling a polygon path into smooth waypoints.
"""
function _funnel_smooth(navmesh::NavMesh, start::Vec3f, goal::Vec3f, poly_path::Vector{Int})::Vector{Vec3f}
    if length(poly_path) <= 1
        return [start, goal]
    end

    # Collect portals
    portals_left = Vec3f[]
    portals_right = Vec3f[]

    push!(portals_left, start)
    push!(portals_right, start)

    for i in 1:length(poly_path)-1
        left, right = _find_portal(navmesh, poly_path[i], poly_path[i+1])
        push!(portals_left, left)
        push!(portals_right, right)
    end

    push!(portals_left, goal)
    push!(portals_right, goal)

    # Simple funnel: walk through portals, narrowing the funnel
    waypoints = Vec3f[start]
    apex = start
    left_idx = 1
    right_idx = 1

    n = length(portals_left)

    for i in 2:n
        # Update right
        new_right = portals_right[i]
        if _cross_2d(apex, portals_right[right_idx], new_right) <= 0
            if _cross_2d(apex, portals_left[left_idx], new_right) >= 0
                right_idx = i
            else
                push!(waypoints, portals_left[left_idx])
                apex = portals_left[left_idx]
                left_idx = left_idx
                right_idx = left_idx
                continue
            end
        end

        # Update left
        new_left = portals_left[i]
        if _cross_2d(apex, portals_left[left_idx], new_left) >= 0
            if _cross_2d(apex, portals_right[right_idx], new_left) <= 0
                left_idx = i
            else
                push!(waypoints, portals_right[right_idx])
                apex = portals_right[right_idx]
                left_idx = right_idx
                right_idx = right_idx
                continue
            end
        end
    end

    if isempty(waypoints) || waypoints[end] != goal
        push!(waypoints, goal)
    end

    return waypoints
end

"""2D cross product in XZ plane: (b-a) × (c-a)"""
@inline function _cross_2d(a::Vec3f, b::Vec3f, c::Vec3f)::Float32
    return (b[1] - a[1]) * (c[3] - a[3]) - (b[3] - a[3]) * (c[1] - a[1])
end
