# =============================================================================
# Navigation System — Types
# =============================================================================

"""
    NavMeshPolygon

A convex polygon in the navigation mesh. Stores vertex indices, the centroid
for A* heuristics, and neighbor polygon indices (adjacency).
"""
struct NavMeshPolygon
    vertex_indices::Vector{Int}
    centroid::Vec3f
    neighbors::Vector{Int}   # indices into NavMesh.polygons
end

"""
    NavMesh

A navigation mesh for pathfinding. Built from walkable triangles/polygons.
Contains vertices and convex polygon faces with precomputed adjacency.
"""
struct NavMesh
    vertices::Vector{Vec3f}
    polygons::Vector{NavMeshPolygon}
end

"""
    NavPath

A computed navigation path: a sequence of 3D waypoints from start to goal.
"""
struct NavPath
    waypoints::Vector{Vec3f}
    total_length::Float32
end

NavPath() = NavPath(Vec3f[], 0.0f0)

"""
    NavAgentComponent <: Component

Attaches a navigation agent to an entity for automatic pathfinding and movement.

- `speed`: movement speed in units/second
- `arrival_distance`: how close to a waypoint before advancing to the next
- `path`: the current computed path (empty if idle)
- `current_waypoint`: index of the next waypoint to reach
- `navmesh`: reference to the navmesh this agent navigates on
"""
mutable struct NavAgentComponent <: Component
    speed::Float64
    arrival_distance::Float64
    path::NavPath
    current_waypoint::Int
    navmesh::Union{NavMesh, Nothing}
    _needs_repath::Bool

    NavAgentComponent(;
        speed::Real = 5.0,
        arrival_distance::Real = 0.3,
        navmesh::Union{NavMesh, Nothing} = nothing
    ) = new(Float64(speed), Float64(arrival_distance), NavPath(), 0, navmesh, false)
end

# Global navmesh registry — maps name → NavMesh for easy lookup
const _NAVMESH_REGISTRY = Dict{String, NavMesh}()

"""
    register_navmesh!(name::String, mesh::NavMesh)

Register a navmesh globally by name for agents to reference.
"""
function register_navmesh!(name::String, mesh::NavMesh)
    _NAVMESH_REGISTRY[name] = mesh
    return nothing
end

"""
    get_navmesh(name::String) -> Union{NavMesh, Nothing}

Retrieve a registered navmesh by name.
"""
function get_navmesh(name::String)::Union{NavMesh, Nothing}
    return get(_NAVMESH_REGISTRY, name, nothing)
end

"""
    reset_navmesh_registry!()

Clear all registered navmeshes.
"""
function reset_navmesh_registry!()
    empty!(_NAVMESH_REGISTRY)
    return nothing
end
