# =============================================================================
# Hot-Reload System — watch script files and reload on change
# =============================================================================

"""
    HotReloadEntry

Tracks a single file being watched for hot-reload.
"""
mutable struct HotReloadEntry
    file_path::String
    module_expr::Union{Expr, Nothing}
    last_mtime::Float64
    on_reload::Union{Function, Nothing}  # called after successful reload
end

"""
    HotReloadManager

Manages file watching and module reloading for game scripts.
Files are polled each frame (via `check_hot_reload!`) for modification time changes.
"""
mutable struct HotReloadManager
    entries::Dict{String, HotReloadEntry}
    enabled::Bool

    HotReloadManager() = new(Dict{String, HotReloadEntry}(), true)
end

const _HOT_RELOAD_MANAGER = Ref{HotReloadManager}(HotReloadManager())

"""
    get_hot_reload_manager() -> HotReloadManager

Get the global hot-reload manager.
"""
get_hot_reload_manager() = _HOT_RELOAD_MANAGER[]

"""
    reset_hot_reload_manager!()

Reset the hot-reload manager, clearing all watched files.
"""
function reset_hot_reload_manager!()
    _HOT_RELOAD_MANAGER[] = HotReloadManager()
    return nothing
end

"""
    hot_reload_enable!(enabled::Bool=true)

Enable or disable file watching for hot-reload.
"""
function hot_reload_enable!(enabled::Bool=true)
    _HOT_RELOAD_MANAGER[].enabled = enabled
    return nothing
end

"""
    hot_reload_enabled() -> Bool

Check if hot-reloading is enabled.
"""
hot_reload_enabled() = _HOT_RELOAD_MANAGER[].enabled

"""
    watch_file!(file_path::String; on_reload::Union{Function, Nothing}=nothing)

Register a file for hot-reload monitoring.
When the file's modification time changes, it will be re-included.

`on_reload` is an optional callback `() -> nothing` invoked after successful reload.
"""
function watch_file!(file_path::String; on_reload::Union{Function, Nothing}=nothing)
    abs_path = abspath(file_path)
    if !isfile(abs_path)
        @warn "watch_file!: file not found" path=abs_path
        return nothing
    end

    mgr = _HOT_RELOAD_MANAGER[]
    mgr.entries[abs_path] = HotReloadEntry(abs_path, nothing, mtime(abs_path), on_reload)
    return nothing
end

"""
    unwatch_file!(file_path::String)

Stop watching a file for hot-reload.
"""
function unwatch_file!(file_path::String)
    abs_path = abspath(file_path)
    delete!(_HOT_RELOAD_MANAGER[].entries, abs_path)
    return nothing
end

"""
    check_hot_reload!() -> Int

Check all watched files for modifications and reload any that changed.
Returns the number of files that were reloaded.

Each file is `include`d in `Main` so that top-level function definitions
update globally. Errors during reload are caught and logged without
crashing the game loop.
"""
function check_hot_reload!()::Int
    mgr = _HOT_RELOAD_MANAGER[]
    mgr.enabled || return 0

    reloaded = 0
    for (path, entry) in mgr.entries
        !isfile(path) && continue
        current_mtime = mtime(path)
        if current_mtime > entry.last_mtime
            entry.last_mtime = current_mtime
            try
                Base.include(Main, path)
                reloaded += 1
                @info "Hot-reloaded" file=basename(path)
                if entry.on_reload !== nothing
                    entry.on_reload()
                end
            catch e
                @warn "Hot-reload failed" file=basename(path) exception=(e, catch_backtrace())
            end
        end
    end

    return reloaded
end

"""
    load_script_file(file_path::String; on_reload::Union{Function, Nothing}=nothing) -> Module

Load a Julia script file and register it for hot-reload monitoring.
The file is `include`d in `Main`. Returns `Main`.

This is the primary API for loading gameplay scripts that should
auto-update during development.
"""
function load_script_file(file_path::String; on_reload::Union{Function, Nothing}=nothing)
    abs_path = abspath(file_path)
    if !isfile(abs_path)
        error("Script file not found: $abs_path")
    end

    # Initial load
    Base.include(Main, abs_path)

    # Register for watching
    watch_file!(abs_path; on_reload=on_reload)

    return Main
end

"""
    watched_files() -> Vector{String}

Get the list of currently watched file paths.
"""
function watched_files()::Vector{String}
    return collect(keys(_HOT_RELOAD_MANAGER[].entries))
end
