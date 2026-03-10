# =============================================================================
# Stats Overlay — on-screen performance display using the UI system
# =============================================================================

"""
    render_stats_overlay!(ui_ctx::UIContext)

Render a performance stats overlay in the top-left corner showing:
- FPS and frame time
- Per-scope timing breakdown
- Entity count

Only renders when the profiler is enabled.
"""
function render_stats_overlay!(ui_ctx::UIContext)
    profiler_enabled() || return nothing

    avg = profiler_get_average(60)
    avg === nothing && return nothing

    x = 10.0f0
    y = 10.0f0
    line_h = 18.0f0
    font_size = 14
    text_color = RGB{Float32}(0.0, 1.0, 0.0)
    warn_color = RGB{Float32}(1.0, 1.0, 0.0)

    fps = avg.total_ms > 0 ? 1000.0 / avg.total_ms : 0.0
    fps_color = fps >= 55 ? text_color : warn_color

    # Background panel
    panel_h = (3 + length(avg.scopes)) * line_h + 8.0f0
    ui_rect(ui_ctx, x=x-4, y=y-4, width=200.0f0, height=panel_h,
            color=RGB{Float32}(0.0, 0.0, 0.0), alpha=0.7f0)

    # FPS line
    ui_text(ui_ctx, "FPS: $(round(fps, digits=1))", x=x, y=y, size=font_size, color=fps_color)
    y += line_h

    # Frame time
    ui_text(ui_ctx, "Frame: $(round(avg.total_ms, digits=2)) ms", x=x, y=y, size=font_size, color=text_color)
    y += line_h

    # Scope breakdown
    for scope in avg.scopes
        ui_text(ui_ctx, "  $(scope.name): $(round(scope.duration_ms, digits=2)) ms",
                x=x, y=y, size=font_size, color=text_color)
        y += line_h
    end

    # Entity count
    ui_text(ui_ctx, "Entities: $(avg.entity_count)", x=x, y=y, size=font_size, color=text_color)

    return nothing
end
