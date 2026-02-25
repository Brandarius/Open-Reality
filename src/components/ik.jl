# Inverse Kinematics components

"""
    TwoBoneIKConstraint

Two-bone IK constraint for arms and legs. Uses an analytic solver
based on the cosine rule for the triangle formed by root→mid→end.
"""
struct TwoBoneIKConstraint
    root_bone::EntityID       # e.g., upper leg / upper arm
    mid_bone::EntityID        # e.g., knee / elbow
    end_bone::EntityID        # e.g., foot / hand
    target_position::Observable{Vec3d}   # World-space target position
    pole_target::Observable{Vec3d}       # Controls bend direction (e.g., knee direction)
    weight::Float32           # 0.0 = full FK, 1.0 = full IK
    enabled::Bool

    TwoBoneIKConstraint(;
        root_bone::EntityID,
        mid_bone::EntityID,
        end_bone::EntityID,
        target_position::Observable{Vec3d} = Observable(Vec3d(0, 0, 0)),
        pole_target::Observable{Vec3d} = Observable(Vec3d(0, 0, 1)),
        weight::Float32 = 1.0f0,
        enabled::Bool = true
    ) = new(root_bone, mid_bone, end_bone, target_position, pole_target, weight, enabled)
end

"""
    LookAtIKConstraint

Single-bone look-at IK constraint. Rotates a bone to face a target,
typically used for head tracking.
"""
struct LookAtIKConstraint
    bone::EntityID
    target_position::Observable{Vec3d}
    weight::Float32
    max_angle::Float32        # Maximum rotation in radians (prevents unnatural twisting)
    forward_axis::Vec3d       # Local forward direction of the bone (default: +Z)
    enabled::Bool

    LookAtIKConstraint(;
        bone::EntityID,
        target_position::Observable{Vec3d} = Observable(Vec3d(0, 0, 0)),
        weight::Float32 = 1.0f0,
        max_angle::Float32 = Float32(π/3),  # 60 degrees
        forward_axis::Vec3d = Vec3d(0, 0, 1),
        enabled::Bool = true
    ) = new(bone, target_position, weight, max_angle, forward_axis, enabled)
end

"""
    IKConstraintComponent <: Component

Holds a list of IK constraints to be applied after animation and before
bone matrix upload. Constraints are evaluated in order.
"""
mutable struct IKConstraintComponent <: Component
    two_bone::Vector{TwoBoneIKConstraint}
    look_at::Vector{LookAtIKConstraint}

    IKConstraintComponent(;
        two_bone::Vector{TwoBoneIKConstraint} = TwoBoneIKConstraint[],
        look_at::Vector{LookAtIKConstraint} = LookAtIKConstraint[]
    ) = new(two_bone, look_at)
end
