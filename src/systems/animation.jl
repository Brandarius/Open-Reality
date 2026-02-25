# Animation system: advance time, interpolate keyframes, update transforms

"""
    AnimationEventFired

Event emitted on the event bus when an animation event triggers.
"""
struct AnimationEventFired
    entity_id::EntityID
    clip_name::String
    event_name::String
end

"""
    _time_crossed(prev_t, curr_t, event_t, duration, looping) -> Bool

Check if playback time crossed an event time between prev_t and curr_t,
correctly handling looping wrap-around.
"""
function _time_crossed(prev_t::Float64, curr_t::Float64, event_t::Float32, duration::Float32, looping::Bool)
    et = Float64(event_t)
    dur = Float64(duration)

    if curr_t >= prev_t
        # Normal forward progression (no wrap)
        return prev_t <= et && et < curr_t
    elseif looping
        # Wrapped around: check [prev_t, duration) and [0, curr_t)
        return (prev_t <= et && et < dur) || (0.0 <= et && et < curr_t)
    end
    return false
end

"""
    update_animations!(dt::Float64)

Advance all playing AnimationComponents and apply interpolated keyframe
values to target entity transforms.
"""
function update_animations!(dt::Float64)
    iterate_components(AnimationComponent) do eid, anim
        has_component(eid, AnimationBlendTreeComponent) && return
        !anim.playing && return
        anim.active_clip < 1 && return
        anim.active_clip > length(anim.clips) && return

        clip = anim.clips[anim.active_clip]

        # Save previous time for event detection
        prev_time = anim.current_time

        # Advance time
        anim.current_time += dt * Float64(anim.speed)

        if anim.current_time >= Float64(clip.duration)
            if anim.looping
                anim.current_time = mod(anim.current_time, Float64(clip.duration))
            else
                anim.current_time = Float64(clip.duration)
                anim.playing = false
            end
        end

        t = Float32(anim.current_time)

        # Fire animation events that were crossed this frame
        for event in clip.events
            if _time_crossed(prev_time, anim.current_time, event.time, clip.duration, anim.looping)
                # Direct callback
                if event.callback !== nothing
                    try
                        event.callback(eid, event)
                    catch e
                        @warn "Animation event callback error" entity=eid event=event.name exception=e
                    end
                end
                # Emit on event bus (if available)
                try
                    bus = get_event_bus()
                    emit!(bus, AnimationEventFired(eid, clip.name, event.name))
                catch
                    # Event bus may not be initialized
                end
            end
        end

        # Evaluate each channel
        for channel in clip.channels
            _apply_channel!(channel, t)
        end
    end
end

# ---- Channel application ----

function _apply_channel!(channel::AnimationChannel, t::Float32)
    isempty(channel.times) && return

    tc = get_component(channel.target_entity, TransformComponent)
    tc === nothing && return

    idx_a, idx_b, lerp_t = _find_keyframe_pair(channel.times, t)

    if channel.target_property == :position
        va = channel.values[idx_a]::Vec3d
        vb = channel.values[idx_b]::Vec3d
        if channel.interpolation == INTERP_STEP
            tc.position[] = va
        else
            tc.position[] = _lerp_vec3d(va, vb, lerp_t)
        end
    elseif channel.target_property == :rotation
        qa = channel.values[idx_a]::Quaterniond
        qb = channel.values[idx_b]::Quaterniond
        if channel.interpolation == INTERP_STEP
            tc.rotation[] = qa
        else
            tc.rotation[] = _slerp(qa, qb, lerp_t)
        end
    elseif channel.target_property == :scale
        va = channel.values[idx_a]::Vec3d
        vb = channel.values[idx_b]::Vec3d
        if channel.interpolation == INTERP_STEP
            tc.scale[] = va
        else
            tc.scale[] = _lerp_vec3d(va, vb, lerp_t)
        end
    end
end
