# Inverse Kinematics solver system
# Runs after animation updates, before skinning (bone matrix upload).

"""
    _slerp_ik(qa, qb, t) -> Quaterniond

Spherical linear interpolation for IK blending.
"""
function _slerp_ik(qa::Quaterniond, qb::Quaterniond, t::Float64)
    t <= 0.0 && return qa
    t >= 1.0 && return qb

    cos_theta = qa[1]*qb[1] + qa[2]*qb[2] + qa[3]*qb[3] + qa[4]*qb[4]
    b = qb
    if cos_theta < 0.0
        b = Quaterniond(-qb[1], -qb[2], -qb[3], -qb[4])
        cos_theta = -cos_theta
    end

    if cos_theta > 0.9999
        # Linear interpolation for nearly identical quaternions
        result = Quaterniond(
            qa[1] + t * (b[1] - qa[1]),
            qa[2] + t * (b[2] - qa[2]),
            qa[3] + t * (b[3] - qa[3]),
            qa[4] + t * (b[4] - qa[4])
        )
        n = sqrt(result[1]^2 + result[2]^2 + result[3]^2 + result[4]^2)
        return Quaterniond(result[1]/n, result[2]/n, result[3]/n, result[4]/n)
    end

    theta = acos(clamp(cos_theta, -1.0, 1.0))
    sin_theta = sin(theta)
    wa = sin((1.0 - t) * theta) / sin_theta
    wb = sin(t * theta) / sin_theta
    result = Quaterniond(
        wa * qa[1] + wb * b[1],
        wa * qa[2] + wb * b[2],
        wa * qa[3] + wb * b[3],
        wa * qa[4] + wb * b[4]
    )
    n = sqrt(result[1]^2 + result[2]^2 + result[3]^2 + result[4]^2)
    return Quaterniond(result[1]/n, result[2]/n, result[3]/n, result[4]/n)
end

"""
    _solve_two_bone_ik!(constraint::TwoBoneIKConstraint)

Analytic two-bone IK solver using the cosine rule.
Adjusts bone rotations so that the end effector reaches the target.
"""
function _solve_two_bone_ik!(constraint::TwoBoneIKConstraint)
    !constraint.enabled && return
    constraint.weight <= 0.0f0 && return

    root_tc = get_component(constraint.root_bone, TransformComponent)
    mid_tc = get_component(constraint.mid_bone, TransformComponent)
    end_tc = get_component(constraint.end_bone, TransformComponent)
    (root_tc === nothing || mid_tc === nothing || end_tc === nothing) && return

    # Get world positions
    root_world = get_world_transform(constraint.root_bone)
    mid_world = get_world_transform(constraint.mid_bone)
    end_world = get_world_transform(constraint.end_bone)

    root_pos = Vec3d(root_world[1,4], root_world[2,4], root_world[3,4])
    mid_pos = Vec3d(mid_world[1,4], mid_world[2,4], mid_world[3,4])
    end_pos = Vec3d(end_world[1,4], end_world[2,4], end_world[3,4])

    target = constraint.target_position[]
    pole = constraint.pole_target[]

    # Bone lengths
    len_a = norm(mid_pos - root_pos)  # Root to mid
    len_b = norm(end_pos - mid_pos)   # Mid to end
    len_a < 1e-6 && return
    len_b < 1e-6 && return

    # Direction and distance to target
    to_target = target - root_pos
    dist_to_target = norm(to_target)
    dist_to_target < 1e-6 && return

    # Clamp target distance to reachable range
    max_reach = len_a + len_b - 1e-4
    min_reach = abs(len_a - len_b) + 1e-4
    dist_to_target = clamp(dist_to_target, min_reach, max_reach)

    # Cosine rule: angle at root joint
    cos_angle_a = clamp((len_a^2 + dist_to_target^2 - len_b^2) / (2.0 * len_a * dist_to_target), -1.0, 1.0)
    angle_a = acos(cos_angle_a)

    # Cosine rule: angle at mid joint
    cos_angle_b = clamp((len_a^2 + len_b^2 - dist_to_target^2) / (2.0 * len_a * len_b), -1.0, 1.0)
    angle_b = acos(cos_angle_b)

    # Build coordinate frame from root towards target using pole target
    forward = normalize(to_target)
    to_pole = pole - root_pos
    # Remove component along forward
    to_pole = to_pole - dot(to_pole, forward) * forward
    pole_len = norm(to_pole)
    if pole_len < 1e-6
        # Fallback: use world up
        to_pole = Vec3d(0, 1, 0) - dot(Vec3d(0, 1, 0), forward) * forward
        pole_len = norm(to_pole)
    end
    up = normalize(to_pole)
    right = cross(forward, up)

    # Mid joint position (from root, rotating angle_a toward the target in the pole plane)
    mid_target = root_pos + (forward * cos(angle_a) + up * sin(angle_a)) * len_a

    # Apply to bone transforms with weight blending
    weight = Float64(constraint.weight)

    # Save FK positions for blending
    fk_mid = mid_pos
    fk_end = end_pos

    # Blend mid joint position
    final_mid = fk_mid .+ weight .* (mid_target .- fk_mid)
    mid_tc.position[] = final_mid

    # End effector tracks the target
    final_end = fk_end .+ weight .* (target .- fk_end)
    end_tc.position[] = final_end
end

"""
    _solve_look_at_ik!(constraint::LookAtIKConstraint)

Single-bone look-at solver. Rotates the bone to face the target position.
"""
function _solve_look_at_ik!(constraint::LookAtIKConstraint)
    !constraint.enabled && return
    constraint.weight <= 0.0f0 && return

    tc = get_component(constraint.bone, TransformComponent)
    tc === nothing && return

    bone_world = get_world_transform(constraint.bone)
    bone_pos = Vec3d(bone_world[1,4], bone_world[2,4], bone_world[3,4])
    target = constraint.target_position[]

    to_target = target - bone_pos
    dist = norm(to_target)
    dist < 1e-6 && return

    desired_dir = normalize(to_target)
    forward = normalize(constraint.forward_axis)

    # Compute rotation from forward to desired direction
    cos_angle = clamp(dot(forward, desired_dir), -1.0, 1.0)
    angle = acos(cos_angle)

    # Clamp to max angle
    angle = min(angle, Float64(constraint.max_angle))

    if angle < 1e-6
        return  # Already facing target
    end

    axis = cross(forward, desired_dir)
    axis_len = norm(axis)
    if axis_len < 1e-6
        return  # Parallel vectors
    end
    axis = normalize(axis)

    # Create quaternion from axis-angle
    half_angle = angle * 0.5
    s = sin(half_angle)
    ik_rotation = Quaterniond(cos(half_angle), s * axis[1], s * axis[2], s * axis[3])

    # Blend with current rotation
    current_rot = tc.rotation[]
    final_rot = _slerp_ik(current_rot, ik_rotation * current_rot, Float64(constraint.weight))
    tc.rotation[] = final_rot
end

"""
    update_ik!()

Apply all IK constraints. Call after update_animations! / update_blend_tree!
and before update_skinned_meshes!.
"""
function update_ik!()
    iterate_components(IKConstraintComponent) do eid, ik
        # Solve two-bone constraints first (legs, arms)
        for constraint in ik.two_bone
            _solve_two_bone_ik!(constraint)
        end

        # Then solve look-at constraints (head tracking)
        for constraint in ik.look_at
            _solve_look_at_ik!(constraint)
        end
    end
end
