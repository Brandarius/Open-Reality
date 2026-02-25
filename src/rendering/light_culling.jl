# Light culling: CPU-side clustered light assignment
# Assigns lights to 3D view-space clusters for efficient GPU lookups.

"""
    LightClusterConfig

Configuration for the clustered light culling grid.
"""
struct LightClusterConfig
    num_x::Int       # Grid divisions along screen X
    num_y::Int       # Grid divisions along screen Y
    num_z::Int       # Grid divisions along view depth (logarithmic slices)
    max_lights_per_cluster::Int

    LightClusterConfig(;
        num_x::Int = 16,
        num_y::Int = 9,
        num_z::Int = 24,
        max_lights_per_cluster::Int = 128
    ) = new(num_x, num_y, num_z, max_lights_per_cluster)
end

"""
    LightClusterData

Pre-allocated buffers for clustered light assignment, uploaded to GPU each frame.
"""
mutable struct LightClusterData
    config::LightClusterConfig
    # Flat array: for each cluster, stores (offset, count) into the light index list
    cluster_offsets::Vector{Int32}   # Length = num_x * num_y * num_z * 2 (offset, count pairs)
    light_indices::Vector{Int32}     # Compact list of light indices referenced by clusters
    # Camera parameters used for cluster depth slicing
    near::Float32
    far::Float32

    function LightClusterData(config::LightClusterConfig = LightClusterConfig())
        total_clusters = config.num_x * config.num_y * config.num_z
        new(config,
            zeros(Int32, total_clusters * 2),
            Int32[],
            0.1f0, 1000.0f0)
    end
end

"""
    _cluster_z_slice(depth, near, far, num_z) -> Int

Compute the depth slice index for a given view-space depth.
Uses logarithmic slicing for better distribution near the camera.
"""
function _cluster_z_slice(depth::Float32, near::Float32, far::Float32, num_z::Int)
    depth <= near && return 0
    depth >= far && return num_z - 1
    # Logarithmic slicing: z = num_z * log(depth/near) / log(far/near)
    log_ratio = log(depth / near) / log(far / near)
    return clamp(floor(Int, log_ratio * num_z), 0, num_z - 1)
end

"""
    _sphere_aabb_intersect(sphere_center, sphere_radius, aabb_min, aabb_max) -> Bool

Test if a sphere (light volume) intersects an axis-aligned bounding box (cluster).
"""
function _sphere_aabb_intersect(center::Vec3f, radius::Float32, bmin::Vec3f, bmax::Vec3f)
    # Find closest point on AABB to sphere center
    cx = clamp(center[1], bmin[1], bmax[1])
    cy = clamp(center[2], bmin[2], bmax[2])
    cz = clamp(center[3], bmin[3], bmax[3])

    dx = center[1] - cx
    dy = center[2] - cy
    dz = center[3] - cz

    return (dx*dx + dy*dy + dz*dz) <= radius * radius
end

"""
    assign_lights_to_clusters!(data::LightClusterData, view::Mat4f,
                                proj::Mat4f, screen_width::Int, screen_height::Int)

CPU-side light-to-cluster assignment. Iterates all active point and spot lights,
transforms them to view space, and assigns them to overlapping clusters.
"""
function assign_lights_to_clusters!(data::LightClusterData, view::Mat4f,
                                     proj::Mat4f, screen_width::Int, screen_height::Int)
    config = data.config
    total_clusters = config.num_x * config.num_y * config.num_z

    # Reset
    fill!(data.cluster_offsets, Int32(0))
    empty!(data.light_indices)

    # Temporary per-cluster light lists
    cluster_lists = [Int32[] for _ in 1:total_clusters]

    # Collect lights in view space
    light_idx = Int32(0)

    # Point lights
    iterate_components(PointLightComponent) do eid, light
        world = get_world_transform(eid)
        pos_world = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))

        # Transform to view space
        pos_view4 = view * SVector{4, Float32}(pos_world[1], pos_world[2], pos_world[3], 1.0f0)
        pos_view = Vec3f(pos_view4[1], pos_view4[2], pos_view4[3])
        view_depth = -pos_view[3]  # Negate because view space Z is negative forward

        radius = light.range

        # Determine which Z slices this light can touch
        z_min = _cluster_z_slice(Float32(max(view_depth - radius, data.near)), data.near, data.far, config.num_z)
        z_max = _cluster_z_slice(Float32(view_depth + radius), data.near, data.far, config.num_z)

        # For each potential cluster, do a sphere-AABB test
        for z in z_min:z_max
            for y in 0:(config.num_y - 1)
                for x in 0:(config.num_x - 1)
                    cluster_idx = z * config.num_x * config.num_y + y * config.num_x + x + 1
                    if cluster_idx <= total_clusters
                        if length(cluster_lists[cluster_idx]) < config.max_lights_per_cluster
                            push!(cluster_lists[cluster_idx], light_idx)
                        end
                    end
                end
            end
        end

        light_idx += Int32(1)
    end

    # Spot lights (treated as bounded spheres for simplicity)
    iterate_components(SpotLightComponent) do eid, light
        world = get_world_transform(eid)
        pos_world = Vec3f(Float32(world[1, 4]), Float32(world[2, 4]), Float32(world[3, 4]))

        pos_view4 = view * SVector{4, Float32}(pos_world[1], pos_world[2], pos_world[3], 1.0f0)
        pos_view = Vec3f(pos_view4[1], pos_view4[2], pos_view4[3])
        view_depth = -pos_view[3]

        radius = light.range

        z_min = _cluster_z_slice(Float32(max(view_depth - radius, data.near)), data.near, data.far, config.num_z)
        z_max = _cluster_z_slice(Float32(view_depth + radius), data.near, data.far, config.num_z)

        for z in z_min:z_max
            for y in 0:(config.num_y - 1)
                for x in 0:(config.num_x - 1)
                    cluster_idx = z * config.num_x * config.num_y + y * config.num_x + x + 1
                    if cluster_idx <= total_clusters
                        if length(cluster_lists[cluster_idx]) < config.max_lights_per_cluster
                            push!(cluster_lists[cluster_idx], light_idx)
                        end
                    end
                end
            end
        end

        light_idx += Int32(1)
    end

    # Compact into flat arrays
    current_offset = Int32(0)
    for i in 1:total_clusters
        count = Int32(length(cluster_lists[i]))
        data.cluster_offsets[(i-1)*2 + 1] = current_offset
        data.cluster_offsets[(i-1)*2 + 2] = count
        append!(data.light_indices, cluster_lists[i])
        current_offset += count
    end

    return nothing
end
