# Visual regression test runner — orchestrates story execution and comparison

"""
    VisualStory

Definition of a visual regression test scene ("story").
Each story builds a deterministic scene, renders it, and compares against a reference image.
"""
struct VisualStory
    name::String
    scene_builder::Function                             # () -> Scene
    width::Int
    height::Int
    n_frames::Int                                       # Frames to render before capture
    post_process::Union{PostProcessConfig, Nothing}
    per_channel_threshold::Int                          # Max per-channel diff (0-255)
    max_diff_fraction::Float64                          # Max fraction of differing pixels
end

"""
    VisualTestResult

Result of running a single visual story.
"""
struct VisualTestResult
    story_name::String
    passed::Bool
    diff::Union{ImageDiffResult, Nothing}
    reference_path::String
    error_message::Union{String, Nothing}
end

# Global story registry
const _VISUAL_STORIES = VisualStory[]

"""
    @visual_story name [kwargs...] body

Register a visual regression test story. The body should return a `Scene`.

# Example
```julia
@visual_story "pbr_red_cube" begin
    scene([
        entity([CameraComponent(fov=60.0f0, aspect=1.0f0), transform(position=Vec3d(0, 2, 5))]),
        entity([DirectionalLightComponent(intensity=2.0f0)]),
        entity([cube_mesh(), MaterialComponent(color=RGB{Float32}(0.9, 0.1, 0.1)), transform()])
    ])
end
```
"""
macro visual_story(name, body)
    quote
        push!(_VISUAL_STORIES, VisualStory(
            $(esc(name)),
            () -> $(esc(body)),
            256, 256, 3,
            nothing,
            2, 0.005
        ))
    end
end

"""
    visual_story(name::String, scene_fn::Function;
                 width=256, height=256, n_frames=3,
                 post_process=nothing,
                 per_channel_threshold=2, max_diff_fraction=0.005)

Programmatically register a visual regression test story.
"""
function visual_story(name::String, scene_fn::Function;
                      width::Int=256, height::Int=256, n_frames::Int=3,
                      post_process::Union{PostProcessConfig, Nothing}=nothing,
                      per_channel_threshold::Int=2, max_diff_fraction::Float64=0.005)
    push!(_VISUAL_STORIES, VisualStory(
        name, scene_fn, width, height, n_frames,
        post_process, per_channel_threshold, max_diff_fraction
    ))
end

"""
    clear_visual_stories!()

Clear all registered visual stories. Useful between test runs.
"""
function clear_visual_stories!()
    empty!(_VISUAL_STORIES)
    return nothing
end

"""
    run_visual_tests(;
        stories=_VISUAL_STORIES,
        reference_dir="test/visual/references",
        diff_dir="test/visual/diffs",
        update_references=false
    ) -> Vector{VisualTestResult}

Execute all registered visual stories, compare against reference images.

Creates a hidden GLFW window once, reuses the OpenGL context for all stories.
Each story gets a clean ECS/GPU state via `reset_engine_state!()` and
`cleanup_all_gpu_resources!()`.

Set `update_references=true` (or env `OPENREALITY_UPDATE_REFERENCES=true`)
to save captured frames as new reference images instead of comparing.
"""
function run_visual_tests(;
        stories::Vector{VisualStory}=_VISUAL_STORIES,
        reference_dir::String=joinpath(@__DIR__, "..", "..", "test", "visual", "references"),
        diff_dir::String=joinpath(@__DIR__, "..", "..", "test", "visual", "diffs"),
        update_references::Bool=false)

    isempty(stories) && return VisualTestResult[]

    # Determine max resolution needed across all stories
    max_w = maximum(s.width for s in stories)
    max_h = maximum(s.height for s in stories)

    # Initialize backend ONCE with hidden window
    backend = OpenGLBackend()
    ensure_glfw_init!()
    GLFW.WindowHint(GLFW.VISIBLE, false)
    initialize!(backend, width=max_w, height=max_h, title="VisualTestRunner")
    GLFW.WindowHint(GLFW.VISIBLE, true)  # Reset hint for any future windows
    GLFW.SwapInterval(0)                  # Disable vsync for speed

    results = VisualTestResult[]

    try
        for story in stories
            result = _run_single_story(backend, story, reference_dir, diff_dir, update_references)
            push!(results, result)
        end
    finally
        cleanup_all_gpu_resources!(backend)
        shutdown!(backend)
    end

    return results
end

function _run_single_story(backend::OpenGLBackend, story::VisualStory,
                           reference_dir::String, diff_dir::String,
                           update_references::Bool)
    # Reset all engine state for clean slate
    reset_engine_state!()
    cleanup_all_gpu_resources!(backend)

    # Build the scene
    local s::Scene
    try
        s = story.scene_builder()
    catch e
        return VisualTestResult(story.name, false, nothing, "",
            "Scene builder failed: $(sprint(showerror, e))")
    end

    # Apply post-process config if specified
    if story.post_process !== nothing && backend.post_process !== nothing
        backend.post_process.config = story.post_process
    end

    # Resize viewport if story has different resolution than backend
    w, h = story.width, story.height
    glViewport(0, 0, w, h)

    # Render N frames — capture on the last one
    captured_pixels = nothing
    for frame in 1:story.n_frames
        if frame == story.n_frames
            # Set capture hook for the final frame (called before swap_buffers!)
            _CAPTURE_HOOK[] = (fw, fh) -> begin
                captured_pixels = capture_framebuffer(w, h)
            end
        end

        GLFW.PollEvents()
        clear_world_transform_cache!()
        render_frame!(backend, s)
    end
    _CAPTURE_HOOK[] = nothing

    if captured_pixels === nothing
        return VisualTestResult(story.name, false, nothing, "",
            "Framebuffer capture returned nothing")
    end

    # File paths
    ref_filename = _sanitize_filename(story.name) * "_$(w)x$(h).png"
    ref_path = joinpath(reference_dir, ref_filename)
    diff_path = joinpath(diff_dir, ref_filename)

    if update_references
        save_capture(ref_path, captured_pixels)
        @info "Updated reference" story=story.name path=ref_path
        return VisualTestResult(story.name, true, nothing, ref_path, nothing)
    end

    # Compare against reference
    if !isfile(ref_path)
        # Save actual for manual inspection
        actual_path = joinpath(diff_dir, "actual_" * ref_filename)
        mkpath(diff_dir)
        save_capture(actual_path, captured_pixels)
        return VisualTestResult(story.name, false, nothing, ref_path,
            "Reference image not found: $ref_path (actual saved to $actual_path)")
    end

    reference = load_reference(ref_path)
    diff_result = compare_images(captured_pixels, reference;
        per_channel_threshold=story.per_channel_threshold,
        max_diff_fraction=story.max_diff_fraction)

    if !diff_result.passed
        mkpath(diff_dir)
        # Save diff image
        if diff_result.diff_image !== nothing
            save_capture(diff_path, diff_result.diff_image)
        end
        # Save actual capture for debugging
        actual_path = joinpath(diff_dir, "actual_" * ref_filename)
        save_capture(actual_path, captured_pixels)
        @warn "Visual regression detected" story=story.name psnr=diff_result.psnr diff_pixels="$(round(diff_result.diff_pixel_fraction * 100, digits=2))%"
    end

    return VisualTestResult(story.name, diff_result.passed, diff_result, ref_path,
        diff_result.passed ? nothing : "PSNR=$(round(diff_result.psnr, digits=1))dB, diff=$(round(diff_result.diff_pixel_fraction * 100, digits=2))%")
end

# Sanitize a story name into a valid filename
function _sanitize_filename(name::String)
    s = lowercase(name)
    s = replace(s, r"[^a-z0-9_]" => "_")
    s = replace(s, r"_+" => "_")
    s = strip(s, '_')
    return s
end
