# =============================================================================
# Frame Profiler — lightweight per-scope timing with ring buffer history
# =============================================================================

"""
    ProfileScope

A single named timing scope within a frame.
"""
struct ProfileScope
    name::String
    duration_ms::Float64
end

"""
    FrameProfile

All timing data for a single frame.
"""
struct FrameProfile
    scopes::Vector{ProfileScope}
    total_ms::Float64
    entity_count::Int
end

"""
    Profiler

Collects frame timing data into a ring buffer for display and analysis.
"""
mutable struct Profiler
    enabled::Bool
    history::Vector{FrameProfile}
    history_size::Int
    _write_idx::Int
    _frame_count::Int
    # Current frame accumulator
    _current_scopes::Vector{ProfileScope}
    _frame_start_ns::UInt64

    function Profiler(; history_size::Int=120)
        new(false,
            Vector{FrameProfile}(undef, history_size),
            history_size,
            0, 0,
            ProfileScope[],
            UInt64(0))
    end
end

# Global profiler instance
const _PROFILER = Ref{Profiler}(Profiler())

"""
    get_profiler() -> Profiler

Get the global profiler instance.
"""
get_profiler() = _PROFILER[]

"""
    profiler_enable!(enabled::Bool=true)

Enable or disable the profiler.
"""
function profiler_enable!(enabled::Bool=true)
    _PROFILER[].enabled = enabled
    return nothing
end

"""
    profiler_enabled() -> Bool

Check if the profiler is currently enabled.
"""
profiler_enabled() = _PROFILER[].enabled

"""
    profiler_begin_frame!()

Start timing a new frame. Call at the beginning of each frame.
"""
function profiler_begin_frame!()
    p = _PROFILER[]
    p.enabled || return nothing
    empty!(p._current_scopes)
    p._frame_start_ns = time_ns()
    return nothing
end

"""
    profiler_scope!(name::String, f::Function)

Time a named scope within the current frame. Usage:
```julia
profiler_scope!("Physics") do
    update_physics!(dt)
end
```
"""
function profiler_scope!(f::Function, name::String)
    p = _PROFILER[]
    if !p.enabled
        f()
        return nothing
    end
    t0 = time_ns()
    f()
    t1 = time_ns()
    push!(p._current_scopes, ProfileScope(name, (t1 - t0) / 1_000_000.0))
    return nothing
end

"""
    profiler_end_frame!()

Finish timing the current frame and push results to the history ring buffer.
"""
function profiler_end_frame!()
    p = _PROFILER[]
    p.enabled || return nothing

    total = (time_ns() - p._frame_start_ns) / 1_000_000.0
    entity_count = try
        component_count(TransformComponent)
    catch
        0
    end

    profile = FrameProfile(copy(p._current_scopes), total, entity_count)

    p._write_idx = (p._write_idx % p.history_size) + 1
    p.history[p._write_idx] = profile
    p._frame_count = min(p._frame_count + 1, p.history_size)

    return nothing
end

"""
    profiler_get_latest() -> Union{FrameProfile, Nothing}

Get the most recent frame profile.
"""
function profiler_get_latest()::Union{FrameProfile, Nothing}
    p = _PROFILER[]
    p._frame_count == 0 && return nothing
    return p.history[p._write_idx]
end

"""
    profiler_get_average(n::Int=60) -> Union{FrameProfile, Nothing}

Get averaged timing over the last `n` frames.
"""
function profiler_get_average(n::Int=60)::Union{FrameProfile, Nothing}
    p = _PROFILER[]
    p._frame_count == 0 && return nothing

    count = min(n, p._frame_count)
    scope_totals = Dict{String, Float64}()
    total_sum = 0.0
    entity_sum = 0

    for i in 1:count
        idx = ((p._write_idx - i + p.history_size) % p.history_size) + 1
        frame = p.history[idx]
        total_sum += frame.total_ms
        entity_sum += frame.entity_count
        for scope in frame.scopes
            scope_totals[scope.name] = get(scope_totals, scope.name, 0.0) + scope.duration_ms
        end
    end

    avg_scopes = [ProfileScope(name, total / count) for (name, total) in scope_totals]
    sort!(avg_scopes, by=s -> -s.duration_ms)

    return FrameProfile(avg_scopes, total_sum / count, entity_sum ÷ count)
end

"""
    profiler_fps() -> Float64

Get the current FPS based on the latest frame time.
"""
function profiler_fps()::Float64
    latest = profiler_get_latest()
    latest === nothing && return 0.0
    latest.total_ms <= 0 && return 0.0
    return 1000.0 / latest.total_ms
end

"""
    reset_profiler!()

Reset the profiler, clearing all history.
"""
function reset_profiler!()
    _PROFILER[] = Profiler()
    return nothing
end
