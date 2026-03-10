# =============================================================================
# NavAgent — path following and steering for navigation agents
# =============================================================================

"""
    nav_request_path!(entity_id::EntityID, goal::Vec3f) -> Bool

Request a new path for a NavAgentComponent. Computes the path immediately
from the entity's current position to the goal using the agent's navmesh.
Returns true if a valid path was found.
"""
function nav_request_path!(entity_id::EntityID, goal::Vec3f)::Bool
    agent = get_component(entity_id, NavAgentComponent)
    agent === nothing && return false
    agent.navmesh === nothing && return false

    tc = get_component(entity_id, TransformComponent)
    tc === nothing && return false

    pos = tc.position[]
    start = Vec3f(Float32(pos[1]), Float32(pos[2]), Float32(pos[3]))

    path = find_path(agent.navmesh, start, goal)
    if isempty(path.waypoints)
        agent.path = NavPath()
        agent.current_waypoint = 0
        return false
    end

    agent.path = path
    agent.current_waypoint = length(path.waypoints) > 1 ? 2 : 1  # skip start position
    agent._needs_repath = false
    return true
end

"""
    nav_stop!(entity_id::EntityID)

Stop the navigation agent, clearing its current path.
"""
function nav_stop!(entity_id::EntityID)
    agent = get_component(entity_id, NavAgentComponent)
    agent === nothing && return nothing
    agent.path = NavPath()
    agent.current_waypoint = 0
    return nothing
end

"""
    nav_has_path(entity_id::EntityID) -> Bool

Check if the navigation agent has an active path.
"""
function nav_has_path(entity_id::EntityID)::Bool
    agent = get_component(entity_id, NavAgentComponent)
    agent === nothing && return false
    return agent.current_waypoint > 0 && agent.current_waypoint <= length(agent.path.waypoints)
end

"""
    nav_has_arrived(entity_id::EntityID) -> Bool

Check if the navigation agent has reached the end of its path.
"""
function nav_has_arrived(entity_id::EntityID)::Bool
    agent = get_component(entity_id, NavAgentComponent)
    agent === nothing && return true
    return agent.current_waypoint > length(agent.path.waypoints) || agent.current_waypoint == 0
end

"""
    update_nav_agents!(dt::Float64)

System update: advance all NavAgentComponents along their paths.
Moves entities toward their current waypoint and advances to the next
when within arrival distance.
"""
function update_nav_agents!(dt::Float64)
    iterate_components(NavAgentComponent) do eid, agent
        # Skip if no active path
        agent.current_waypoint <= 0 && return
        agent.current_waypoint > length(agent.path.waypoints) && return

        tc = get_component(eid, TransformComponent)
        tc === nothing && return

        pos = tc.position[]
        target = agent.path.waypoints[agent.current_waypoint]
        target_d = Vec3d(Float64(target[1]), Float64(target[2]), Float64(target[3]))

        # Direction to current waypoint
        dx = target_d[1] - pos[1]
        dy = target_d[2] - pos[2]
        dz = target_d[3] - pos[3]
        dist = sqrt(dx * dx + dy * dy + dz * dz)

        # Check arrival
        if dist < agent.arrival_distance
            agent.current_waypoint += 1
            if agent.current_waypoint > length(agent.path.waypoints)
                # Arrived at final waypoint
                return
            end
            # Recalculate toward next waypoint
            target = agent.path.waypoints[agent.current_waypoint]
            target_d = Vec3d(Float64(target[1]), Float64(target[2]), Float64(target[3]))
            dx = target_d[1] - pos[1]
            dy = target_d[2] - pos[2]
            dz = target_d[3] - pos[3]
            dist = sqrt(dx * dx + dy * dy + dz * dz)
            dist < 1e-6 && return
        end

        # Move toward waypoint
        move_dist = min(agent.speed * dt, dist)
        inv_dist = 1.0 / dist
        move = Vec3d(dx * inv_dist * move_dist, dy * inv_dist * move_dist, dz * inv_dist * move_dist)
        tc.position[] = pos + move
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Behavior Tree integration
# ---------------------------------------------------------------------------

"""
    bt_nav_move_to(target_key::Symbol; speed::Float64=5.0, arrival_distance::Float64=0.5)

Behavior tree action node that moves an entity to a blackboard position using
navmesh pathfinding. The entity must have a NavAgentComponent with a navmesh set.

Returns RUNNING while navigating, SUCCESS on arrival, FAILURE if no path found
or NavAgentComponent is missing.
"""
function bt_nav_move_to(target_key::Symbol; speed::Float64=5.0, arrival_distance::Float64=0.5)
    path_key = Symbol(:_nav_path_set_, target_key)
    return ActionNode((eid, bb, dt) -> begin
        target = bb_get(bb, target_key)
        target === nothing && return BT_FAILURE

        agent = get_component(eid, NavAgentComponent)
        agent === nothing && return BT_FAILURE

        # Set speed from parameter
        agent.speed = speed
        agent.arrival_distance = arrival_distance

        goal = Vec3f(Float32(target[1]), Float32(target[2]), Float32(target[3]))

        # Request path if not yet set for this target
        if !bb_get(bb, path_key, false)
            if !nav_request_path!(eid, goal)
                return BT_FAILURE
            end
            bb_set!(bb, path_key, true)
        end

        # Check if arrived
        if nav_has_arrived(eid)
            bb_delete!(bb, path_key)
            return BT_SUCCESS
        end

        return BT_RUNNING
    end)
end
