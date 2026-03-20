# Hydraulic erosion: particle-based droplet simulation for realistic terrain
#
# Simulates water droplets flowing downhill, picking up sediment on steep slopes
# and depositing it in flat areas. Produces natural-looking valleys, ridges, and rivers.

"""
    ErosionParams

Configuration for hydraulic erosion simulation.
"""
struct ErosionParams
    num_droplets::Int               # Total erosion iterations
    inertia::Float32                # How much the droplet maintains direction (0..1)
    sediment_capacity::Float32      # Max sediment a droplet can carry
    min_sediment_capacity::Float32  # Minimum capacity threshold
    erosion_speed::Float32          # How fast terrain erodes
    deposition_speed::Float32       # How fast sediment deposits
    evaporation_speed::Float32      # Droplet evaporation rate per step (0..1)
    gravity::Float32                # Gravitational acceleration
    max_droplet_lifetime::Int       # Max steps before droplet dies
    erosion_radius::Int             # Brush radius for erosion/deposition

    ErosionParams(;
        num_droplets::Int = 70000,
        inertia::Float32 = 0.05f0,
        sediment_capacity::Float32 = 4.0f0,
        min_sediment_capacity::Float32 = 0.01f0,
        erosion_speed::Float32 = 0.3f0,
        deposition_speed::Float32 = 0.3f0,
        evaporation_speed::Float32 = 0.01f0,
        gravity::Float32 = 4.0f0,
        max_droplet_lifetime::Int = 30,
        erosion_radius::Int = 3
    ) = new(num_droplets, inertia, sediment_capacity, min_sediment_capacity,
            erosion_speed, deposition_speed, evaporation_speed, gravity,
            max_droplet_lifetime, erosion_radius)
end

"""
    default_erosion_params() -> ErosionParams

Well-tuned defaults for medium-resolution terrain (256x256 to 1024x1024).
"""
default_erosion_params() = ErosionParams()

"""
    _heightmap_gradient(hm::Matrix{Float32}, x::Float64, y::Float64) -> (Float64, Float64, Float64)

Compute the gradient (gx, gy) and interpolated height at a floating-point position.
Uses bilinear interpolation of surrounding grid cells.
"""
function _heightmap_gradient(hm::Matrix{Float32}, x::Float64, y::Float64)
    rows, cols = size(hm)
    ix = floor(Int, x)
    iy = floor(Int, y)
    fx = x - ix
    fy = y - iy

    # Clamp to valid indices (1-based)
    ix0 = clamp(ix + 1, 1, rows)
    iy0 = clamp(iy + 1, 1, cols)
    ix1 = clamp(ix + 2, 1, rows)
    iy1 = clamp(iy + 2, 1, cols)

    h00 = Float64(hm[ix0, iy0])
    h10 = Float64(hm[ix1, iy0])
    h01 = Float64(hm[ix0, iy1])
    h11 = Float64(hm[ix1, iy1])

    # Bilinear interpolated height
    height = h00 * (1.0 - fx) * (1.0 - fy) +
             h10 * fx * (1.0 - fy) +
             h01 * (1.0 - fx) * fy +
             h11 * fx * fy

    # Gradient via finite differences of bilinear interpolation
    gx = (h10 - h00) * (1.0 - fy) + (h11 - h01) * fy
    gy = (h01 - h00) * (1.0 - fx) + (h11 - h10) * fx

    return (gx, gy, height)
end

"""
    _erosion_brush_weights(radius::Int) -> (Vector{Tuple{Int,Int}}, Vector{Float64})

Precompute erosion brush offsets and weights for a given radius.
Weights fall off linearly from center.
"""
function _erosion_brush_weights(radius::Int)
    offsets = Tuple{Int,Int}[]
    weights = Float64[]
    total = 0.0

    for dy in -radius:radius, dx in -radius:radius
        dist = sqrt(Float64(dx * dx + dy * dy))
        if dist <= radius
            w = max(0.0, 1.0 - dist / radius)
            push!(offsets, (dx, dy))
            push!(weights, w)
            total += w
        end
    end

    # Normalize
    if total > 0.0
        weights ./= total
    end

    return (offsets, weights)
end

"""
    erode_heightmap!(hm::Matrix{Float32}, params::ErosionParams, seed::UInt64)

Apply hydraulic erosion to a heightmap in-place. Deterministic via seed.

Each droplet:
1. Starts at a random position
2. Flows downhill following the gradient
3. Picks up sediment proportional to velocity and slope
4. Deposits sediment when slowing or in flat areas
5. Evaporates over time
"""
function erode_heightmap!(hm::Matrix{Float32}, params::ErosionParams, seed::UInt64)
    rows, cols = size(hm)
    if rows < 3 || cols < 3
        return
    end

    # Precompute brush
    brush_offsets, brush_weights = _erosion_brush_weights(params.erosion_radius)

    # Deterministic RNG using seed
    rng_state = seed

    for drop_i in 1:params.num_droplets
        # Advance RNG
        rng_state = xor(rng_state * UInt64(6364136223846793005) + UInt64(1442695040888963407),
                        UInt64(drop_i))

        # Random start position
        pos_x = Float64(rng_state % UInt64(rows - 2)) + Float64((rng_state >> 32) % UInt64(1000)) / 1000.0
        rng_state = xor(rng_state * UInt64(6364136223846793005) + UInt64(1442695040888963407),
                        UInt64(drop_i + params.num_droplets))
        pos_y = Float64(rng_state % UInt64(cols - 2)) + Float64((rng_state >> 32) % UInt64(1000)) / 1000.0

        dir_x = 0.0
        dir_y = 0.0
        speed = 1.0
        water = 1.0
        sediment = 0.0

        for _ in 1:params.max_droplet_lifetime
            ix = floor(Int, pos_x)
            iy = floor(Int, pos_y)

            # Check bounds
            if ix < 0 || ix >= rows - 1 || iy < 0 || iy >= cols - 1
                break
            end

            # Compute gradient and height at current position
            gx, gy, old_height = _heightmap_gradient(hm, pos_x, pos_y)

            # Update direction with inertia
            dir_x = dir_x * Float64(params.inertia) - gx * (1.0 - Float64(params.inertia))
            dir_y = dir_y * Float64(params.inertia) - gy * (1.0 - Float64(params.inertia))

            # Normalize direction
            len = sqrt(dir_x * dir_x + dir_y * dir_y)
            if len < 1.0e-10
                # Pick random direction
                rng_state = xor(rng_state * UInt64(6364136223846793005), UInt64(0xDEADBEEF))
                angle = Float64(rng_state % UInt64(6283)) / 1000.0
                dir_x = cos(angle)
                dir_y = sin(angle)
            else
                dir_x /= len
                dir_y /= len
            end

            # Move to new position
            new_x = pos_x + dir_x
            new_y = pos_y + dir_y

            # Check bounds (negated form catches NaN — NaN comparisons return false)
            if !(0.0 <= new_x < rows - 1) || !(0.0 <= new_y < cols - 1)
                break
            end

            # Height at new position
            _, _, new_height = _heightmap_gradient(hm, new_x, new_y)
            height_diff = new_height - old_height

            # Sediment capacity based on slope, speed, and water
            capacity = max(Float64(params.min_sediment_capacity),
                          -height_diff * speed * water * Float64(params.sediment_capacity))

            if sediment > capacity || height_diff > 0
                # Deposit sediment
                deposit_amount = if height_diff > 0
                    # Moving uphill: deposit min of sediment and height difference
                    min(sediment, height_diff)
                else
                    (sediment - capacity) * Float64(params.deposition_speed)
                end

                # Apply deposit using brush
                cix = clamp(ix + 1, 1, rows)
                ciy = clamp(iy + 1, 1, cols)
                for (k, (odx, ody)) in enumerate(brush_offsets)
                    bx = clamp(cix + odx, 1, rows)
                    by = clamp(ciy + ody, 1, cols)
                    hm[bx, by] += Float32(deposit_amount * brush_weights[k])
                end
                sediment -= deposit_amount
            else
                # Erode terrain
                erode_amount = min((capacity - sediment) * Float64(params.erosion_speed),
                                   -height_diff)
                erode_amount = max(erode_amount, 0.0)

                # Apply erosion using brush
                cix = clamp(ix + 1, 1, rows)
                ciy = clamp(iy + 1, 1, cols)
                for (k, (odx, ody)) in enumerate(brush_offsets)
                    bx = clamp(cix + odx, 1, rows)
                    by = clamp(ciy + ody, 1, cols)
                    hm[bx, by] -= Float32(erode_amount * brush_weights[k])
                end
                sediment += erode_amount
            end

            # Update speed
            speed = sqrt(max(0.0, speed * speed + height_diff * Float64(params.gravity)))

            # Evaporate water
            water *= (1.0 - Float64(params.evaporation_speed))

            pos_x = new_x
            pos_y = new_y
        end
    end
end
