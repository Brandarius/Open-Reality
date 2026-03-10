# Navigation & Profiling Demo
# Demonstrates the 3 new engine systems in one playable scene:
#
#   1. Navigation / NavMesh   — grid-based navmesh, A* pathfinding, NavAgentComponent
#   2. Frame Profiler         — per-scope timing, stats overlay (FPS, frame time)
#   3. Hot-Reload             — live script reloading during gameplay
#
# The scene spawns AI agents that patrol between random waypoints on a navmesh.
# A companion script file (`navigation_demo_script.jl`) is watched for hot-reload —
# edit it while the demo runs to see changes take effect immediately.
#
# Run with:
#   julia --project=. examples/navigation_demo.jl

using OpenReality

# =============================================================================
# Constants
# =============================================================================

const GRID_W         = 20      # navmesh grid cells (X)
const GRID_D         = 20      # navmesh grid cells (Z)
const CELL_SIZE      = 1.5f0   # world units per grid cell
const AGENT_COUNT    = 6
const AGENT_SPEED    = 3.0
const ARENA_W        = Float64(GRID_W) * CELL_SIZE
const ARENA_D        = Float64(GRID_D) * CELL_SIZE

# =============================================================================
# Obstacle layout — blocked cells form walls in the arena
# =============================================================================

# Obstacle cells (grid coords) — forms a simple maze-like pattern
const OBSTACLE_CELLS = Set{Tuple{Int,Int}}([
    # Vertical wall in center-left
    (5,4), (5,5), (5,6), (5,7), (5,8), (5,9), (5,10),
    # Horizontal wall in center
    (8,10), (9,10), (10,10), (11,10), (12,10),
    # Vertical wall center-right
    (14,5), (14,6), (14,7), (14,8), (14,9), (14,10), (14,11), (14,12),
    # Small block bottom
    (9,4), (10,4), (9,5), (10,5),
    # Top wall
    (3,15), (4,15), (5,15), (6,15), (7,15),
    # Bottom-right corner
    (16,3), (17,3), (16,4), (17,4),
])

function is_walkable(ix, iz)
    return !((ix, iz) in OBSTACLE_CELLS)
end

# =============================================================================
# NavMesh setup
# =============================================================================

function build_arena_navmesh()
    origin = Vec3f(0, 0, 0)
    mesh = build_navmesh_from_grid(GRID_W, GRID_D;
        cell_size=CELL_SIZE,
        origin=origin,
        walkable_fn=is_walkable
    )
    register_navmesh!("arena", mesh)
    return mesh
end

# =============================================================================
# Hot-Reload companion script
# =============================================================================

const SCRIPT_PATH = joinpath(@__DIR__, "navigation_demo_script.jl")

function ensure_companion_script!()
    if !isfile(SCRIPT_PATH)
        open(SCRIPT_PATH, "w") do io
            write(io, """
# Navigation Demo — Hot-Reload Script
# Edit this file while the demo is running to see changes live!
#
# This function is called every frame for each agent's bobbing animation.
# Try changing the speed or amplitude and save the file.

function agent_bob_offset(time::Float64)::Float64
    return 0.15 * sin(time * 2.0)
end
""")
        end
    end
end

# =============================================================================
# Agent AI — patrol between random navmesh waypoints
# =============================================================================

function random_walkable_pos(navmesh::NavMesh)
    # Pick a random polygon centroid as a goal
    idx = rand(1:length(navmesh.polygons))
    c = navmesh.polygons[idx].centroid
    return Vec3f(c[1], 0.0f0, c[3])
end

function make_patrol_script(navmesh::NavMesh, agent_id::Int)
    time_acc = Ref(0.0)
    base_y = Ref(0.5)
    goal_timer = Ref(0.0)

    ScriptComponent(
        on_start = (eid, ctx) -> begin
            # Request initial path
            goal = random_walkable_pos(navmesh)
            nav_request_path!(eid, goal)
            println("  [Agent $agent_id] Spawned, patrolling to $(round.(goal, digits=1))")
        end,
        on_update = (eid, dt, ctx) -> begin
            time_acc[] += dt
            goal_timer[] += dt

            # Pick a new goal when arrived or after timeout
            if nav_has_arrived(eid) || goal_timer[] > 8.0
                goal = random_walkable_pos(navmesh)
                nav_request_path!(eid, goal)
                goal_timer[] = 0.0
            end

            # Bobbing animation (uses hot-reloadable function)
            tc = get_component(eid, TransformComponent)
            tc === nothing && return
            pos = tc.position[]
            bob = try
                Main.agent_bob_offset(time_acc[])
            catch
                0.15 * sin(time_acc[] * 2.0)
            end
            tc.position[] = Vec3d(pos[1], base_y[] + bob, pos[3])
        end
    )
end

# =============================================================================
# Scene builder
# =============================================================================

function build_demo_scene(navmesh::NavMesh)
    defs = Any[]

    # --- Player ---
    push!(defs, create_player(position=Vec3d(ARENA_W / 2, 2.0, ARENA_D - 3)))

    # --- Lighting ---
    push!(defs, entity([
        DirectionalLightComponent(
            direction=Vec3f(0.3, -1.0, -0.4),
            intensity=3.0f0,
            color=RGB{Float32}(1.0, 0.95, 0.9)
        )
    ]))
    push!(defs, entity([
        PointLightComponent(
            color=RGB{Float32}(0.4, 0.6, 1.0),
            intensity=30.0f0,
            range=40.0f0
        ),
        transform(position=Vec3d(ARENA_W / 2, 8, ARENA_D / 2))
    ]))

    # --- Ground plane ---
    push!(defs, entity([
        plane_mesh(width=Float32(ARENA_W + 4), depth=Float32(ARENA_D + 4)),
        MaterialComponent(
            color=RGB{Float32}(0.3, 0.35, 0.3),
            metallic=0.0f0,
            roughness=0.9f0
        ),
        transform(position=Vec3d(ARENA_W / 2 - 2, 0, ARENA_D / 2 - 2)),
        ColliderComponent(shape=AABBShape(Vec3f(ARENA_W / 2 + 2, 0.01, ARENA_D / 2 + 2))),
        RigidBodyComponent(body_type=BODY_STATIC)
    ]))

    # --- Obstacle blocks (walls) ---
    for (ix, iz) in OBSTACLE_CELLS
        wx = Float64(ix) * CELL_SIZE + CELL_SIZE / 2
        wz = Float64(iz) * CELL_SIZE + CELL_SIZE / 2
        push!(defs, entity([
            cube_mesh(size=Float32(CELL_SIZE * 0.9)),
            MaterialComponent(
                color=RGB{Float32}(0.5, 0.35, 0.25),
                metallic=0.1f0,
                roughness=0.8f0
            ),
            transform(position=Vec3d(wx, CELL_SIZE / 2, wz)),
            ColliderComponent(shape=AABBShape(Vec3f(CELL_SIZE / 2, CELL_SIZE / 2, CELL_SIZE / 2))),
            RigidBodyComponent(body_type=BODY_STATIC)
        ]))
    end

    # --- Navigation agents ---
    agent_colors = [
        RGB{Float32}(0.2, 0.8, 0.3),   # green
        RGB{Float32}(0.8, 0.2, 0.2),   # red
        RGB{Float32}(0.2, 0.4, 0.9),   # blue
        RGB{Float32}(0.9, 0.7, 0.1),   # yellow
        RGB{Float32}(0.7, 0.2, 0.8),   # purple
        RGB{Float32}(0.1, 0.8, 0.8),   # cyan
    ]

    for i in 1:AGENT_COUNT
        # Start near center, offset per agent
        angle = 2π * (i - 1) / AGENT_COUNT
        sx = ARENA_W / 2 + 3.0 * cos(angle)
        sz = ARENA_D / 2 + 3.0 * sin(angle)
        color = agent_colors[((i - 1) % length(agent_colors)) + 1]

        push!(defs, entity([
            sphere_mesh(radius=0.4f0),
            MaterialComponent(
                color=color,
                metallic=0.3f0,
                roughness=0.4f0,
                emissive_factor=Vec3f(color.r * 0.2f0, color.g * 0.2f0, color.b * 0.2f0)
            ),
            transform(position=Vec3d(sx, 0.5, sz)),
            NavAgentComponent(speed=AGENT_SPEED + rand() * 2.0, navmesh=navmesh),
            make_patrol_script(navmesh, i),
        ]))
    end

    return defs
end

# =============================================================================
# Game State
# =============================================================================

mutable struct NavigationDemoState <: GameState end

function OpenReality.on_enter!(state::NavigationDemoState, sc::Scene)
    println("  [FSM] Navigation demo started")
end

function OpenReality.on_update!(state::NavigationDemoState, sc::Scene, dt::Float64, ctx::GameContext)
    return nothing
end

function OpenReality.on_exit!(state::NavigationDemoState, sc::Scene)
    println("  [FSM] Navigation demo exiting")
end

# =============================================================================
# UI Overlay
# =============================================================================

const profiler_toggle = Ref(true)

ui_callback = function(ctx::UIContext)
    # ── Title bar ─────────────────────────────────────────────────────────
    ui_rect(ctx, x=0, y=0, width=ctx.width, height=48,
            color=RGB{Float32}(0.05, 0.05, 0.12), alpha=0.85f0)
    ui_text(ctx, "OpenReality -- Navigation & Profiling Demo",
            x=12, y=12, size=26, color=RGB{Float32}(1.0, 1.0, 1.0))

    # ── Features panel (left) ─────────────────────────────────────────────
    panel_x = 10
    panel_y = 60
    panel_w = 320
    panel_h = 200

    ui_rect(ctx, x=panel_x, y=panel_y, width=panel_w, height=panel_h,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
    ui_text(ctx, "New Features", x=panel_x + 10, y=panel_y + 8, size=22,
            color=RGB{Float32}(0.9, 0.8, 0.3))

    features = [
        ("NavMesh (grid + A*)",        RGB{Float32}(0.3, 1.0, 0.4)),
        ("NavAgentComponent",          RGB{Float32}(0.3, 0.9, 0.5)),
        ("Patrol AI (pathfinding)",    RGB{Float32}(0.4, 0.7, 1.0)),
        ("Frame Profiler + Overlay",   RGB{Float32}(1.0, 0.5, 0.3)),
        ("Hot-Reload (edit script!)",  RGB{Float32}(0.8, 0.6, 1.0)),
    ]
    for (i, (name, color)) in enumerate(features)
        ui_text(ctx, "* $name", x=panel_x + 15, y=panel_y + 22 + i * 28, size=17, color=color)
    end

    # ── Info panel (bottom-left) ──────────────────────────────────────────
    info_y = panel_y + panel_h + 10
    info_h = 110
    ui_rect(ctx, x=panel_x, y=info_y, width=panel_w, height=info_h,
            color=RGB{Float32}(0.05, 0.05, 0.1), alpha=0.8f0)
    ui_text(ctx, "How to test Hot-Reload:", x=panel_x + 10, y=info_y + 8, size=18,
            color=RGB{Float32}(0.3, 0.8, 1.0))
    ui_text(ctx, "1. Open navigation_demo_script.jl", x=panel_x + 15, y=info_y + 34, size=14,
            color=RGB{Float32}(0.7, 0.7, 0.7))
    ui_text(ctx, "2. Change bob speed/amplitude", x=panel_x + 15, y=info_y + 52, size=14,
            color=RGB{Float32}(0.7, 0.7, 0.7))
    ui_text(ctx, "3. Save -- agents update live!", x=panel_x + 15, y=info_y + 70, size=14,
            color=RGB{Float32}(0.7, 0.7, 0.7))

    watched = watched_files()
    ui_text(ctx, "Watched files: $(length(watched))", x=panel_x + 15, y=info_y + 90, size=13,
            color=RGB{Float32}(0.5, 0.5, 0.5))

    # ── Profiler stats overlay (top-right) ────────────────────────────────
    if profiler_toggle[]
        render_stats_overlay!(ctx)
    end

    # ── Profiler toggle button ────────────────────────────────────────────
    btn_w = 180
    btn_x = ctx.width - btn_w - 10
    btn_y = ctx.height - 50
    label = profiler_toggle[] ? "Hide Profiler" : "Show Profiler"
    if ui_button(ctx, label, x=btn_x, y=btn_y, width=btn_w, height=36,
                 color=RGB{Float32}(0.2, 0.5, 0.3),
                 hover_color=RGB{Float32}(0.3, 0.6, 0.4),
                 text_size=16)
        profiler_toggle[] = !profiler_toggle[]
    end

    # ── Controls hint ─────────────────────────────────────────────────────
    ui_text(ctx, "WASD: Move  |  Mouse: Look  |  Shift: Sprint  |  Esc: Release cursor",
            x=ctx.width - 530, y=ctx.height - 15, size=13,
            color=RGB{Float32}(0.5, 0.5, 0.5))
end

# =============================================================================
# Main
# =============================================================================

function main()
    println("=" ^ 70)
    println("  OpenReality -- Navigation & Profiling Demo")
    println("=" ^ 70)
    println()
    println("  Features demonstrated:")
    println("    1. NavMesh           -- grid-based navmesh with obstacle filtering")
    println("    2. A* Pathfinding    -- agents navigate around walls automatically")
    println("    3. NavAgentComponent -- automatic path following and steering")
    println("    4. Frame Profiler    -- per-scope timing with stats overlay")
    println("    5. Hot-Reload        -- edit navigation_demo_script.jl live")
    println()
    println("  Controls: WASD to move, mouse to look, Shift to sprint")
    println("            Toggle profiler overlay with the button")
    println("=" ^ 70)
    println()

    # Write companion script if it doesn't exist
    ensure_companion_script!()

    # Load companion script & register for hot-reload
    load_script_file(SCRIPT_PATH; on_reload=() -> begin
        println("  [Hot-Reload] Script updated! Agent behavior will change.")
    end)

    # Enable profiler
    profiler_enable!(true)

    # Build navmesh
    navmesh = build_arena_navmesh()
    println("  NavMesh built: $(length(navmesh.polygons)) polygons, $(length(navmesh.vertices)) vertices")

    # Build scene
    reset_entity_counter!()
    reset_component_stores!()

    defs = build_demo_scene(navmesh)

    # FSM setup (single state, no transitions needed)
    fsm = GameStateMachine(:playing, defs)
    add_state!(fsm, :playing, NavigationDemoState())

    render(fsm;
        title="OpenReality -- Navigation Demo",
        width=1280, height=720,
        ui=ui_callback,
        on_scene_switch=(old_scene, new_defs) -> begin
            reset_engine_state!()
        end,
        post_process=PostProcessConfig(
            tone_mapping=TONEMAP_ACES,
            bloom_enabled=true,
            bloom_threshold=0.8f0,
            bloom_intensity=0.3f0,
            fxaa_enabled=true,
            vignette_enabled=true,
            vignette_intensity=0.3f0,
            vignette_radius=0.85f0
        )
    )
end

main()
