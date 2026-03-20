# Expanded noise library: Simplex, Worley, Ridge, Billow, Domain Warping
#
# All functions are pure, deterministic, and seed-parameterized.
# The existing perlin_noise_2d and fbm_noise_2d in rendering/terrain.jl are preserved.

# ---- Simplex Noise 2D ----

# Precomputed gradients for 2D simplex noise (12 directions)
const _SIMPLEX_GRAD2 = [
    ( 1.0,  1.0), (-1.0,  1.0), ( 1.0, -1.0), (-1.0, -1.0),
    ( 1.0,  0.0), (-1.0,  0.0), ( 0.0,  1.0), ( 0.0, -1.0),
    ( 1.0,  1.0), (-1.0,  1.0), ( 1.0, -1.0), (-1.0, -1.0)
]

# Precomputed gradients for 3D simplex noise
const _SIMPLEX_GRAD3 = [
    ( 1.0,  1.0,  0.0), (-1.0,  1.0,  0.0), ( 1.0, -1.0,  0.0), (-1.0, -1.0,  0.0),
    ( 1.0,  0.0,  1.0), (-1.0,  0.0,  1.0), ( 1.0,  0.0, -1.0), (-1.0,  0.0, -1.0),
    ( 0.0,  1.0,  1.0), ( 0.0, -1.0,  1.0), ( 0.0,  1.0, -1.0), ( 0.0, -1.0, -1.0)
]

"""
    _simplex_hash(ix::Int, iy::Int, seed::UInt64) -> Int

Hash function for simplex noise gradient lookup.
"""
function _simplex_hash(ix::Int, iy::Int, seed::UInt64)::Int
    h = UInt64(ix) * UInt64(374761393) + UInt64(iy) * UInt64(668265263) + seed
    h = xor(h, h >> 13) * UInt64(1274126177)
    return Int(h % 12) + 1
end

function _simplex_hash3(ix::Int, iy::Int, iz::Int, seed::UInt64)::Int
    h = UInt64(ix) * UInt64(374761393) + UInt64(iy) * UInt64(668265263) + UInt64(iz) * UInt64(982451653) + seed
    h = xor(h, h >> 13) * UInt64(1274126177)
    return Int(h % 12) + 1
end

const _F2 = 0.5 * (sqrt(3.0) - 1.0)
const _G2 = (3.0 - sqrt(3.0)) / 6.0
const _F3 = 1.0 / 3.0
const _G3 = 1.0 / 6.0

"""
    simplex_noise_2d(x::Float64, y::Float64, seed::UInt64) -> Float64

2D Simplex noise. Returns values in approximately [-1, 1].
More isotropic than Perlin noise with fewer directional artifacts.
"""
function simplex_noise_2d(x::Float64, y::Float64, seed::UInt64)::Float64
    # Skew input space to determine simplex cell
    s = (x + y) * _F2
    i = floor(Int, x + s)
    j = floor(Int, y + s)

    t = (i + j) * _G2
    x0 = x - (i - t)
    y0 = y - (j - t)

    # Determine which simplex we're in
    i1, j1 = x0 > y0 ? (1, 0) : (0, 1)

    x1 = x0 - i1 + _G2
    y1 = y0 - j1 + _G2
    x2 = x0 - 1.0 + 2.0 * _G2
    y2 = y0 - 1.0 + 2.0 * _G2

    # Calculate contributions from the three corners
    n0 = 0.0
    t0 = 0.5 - x0 * x0 - y0 * y0
    if t0 >= 0.0
        t0 *= t0
        gi = _SIMPLEX_GRAD2[_simplex_hash(i, j, seed)]
        n0 = t0 * t0 * (gi[1] * x0 + gi[2] * y0)
    end

    n1 = 0.0
    t1 = 0.5 - x1 * x1 - y1 * y1
    if t1 >= 0.0
        t1 *= t1
        gi = _SIMPLEX_GRAD2[_simplex_hash(i + i1, j + j1, seed)]
        n1 = t1 * t1 * (gi[1] * x1 + gi[2] * y1)
    end

    n2 = 0.0
    t2 = 0.5 - x2 * x2 - y2 * y2
    if t2 >= 0.0
        t2 *= t2
        gi = _SIMPLEX_GRAD2[_simplex_hash(i + 1, j + 1, seed)]
        n2 = t2 * t2 * (gi[1] * x2 + gi[2] * y2)
    end

    # Scale to [-1, 1]
    return 70.0 * (n0 + n1 + n2)
end

"""
    simplex_noise_3d(x::Float64, y::Float64, z::Float64, seed::UInt64) -> Float64

3D Simplex noise. Returns values in approximately [-1, 1].
"""
function simplex_noise_3d(x::Float64, y::Float64, z::Float64, seed::UInt64)::Float64
    s = (x + y + z) * _F3
    i = floor(Int, x + s)
    j = floor(Int, y + s)
    k = floor(Int, z + s)

    t = (i + j + k) * _G3
    x0 = x - (i - t)
    y0 = y - (j - t)
    z0 = z - (k - t)

    # Determine which simplex we're in
    i1, j1, k1, i2, j2, k2 = if x0 >= y0
        if y0 >= z0
            (1, 0, 0, 1, 1, 0)
        elseif x0 >= z0
            (1, 0, 0, 1, 0, 1)
        else
            (0, 0, 1, 1, 0, 1)
        end
    else
        if y0 < z0
            (0, 0, 1, 0, 1, 1)
        elseif x0 < z0
            (0, 1, 0, 0, 1, 1)
        else
            (0, 1, 0, 1, 1, 0)
        end
    end

    x1 = x0 - i1 + _G3
    y1 = y0 - j1 + _G3
    z1 = z0 - k1 + _G3
    x2 = x0 - i2 + 2.0 * _G3
    y2 = y0 - j2 + 2.0 * _G3
    z2 = z0 - k2 + 2.0 * _G3
    x3 = x0 - 1.0 + 3.0 * _G3
    y3 = y0 - 1.0 + 3.0 * _G3
    z3 = z0 - 1.0 + 3.0 * _G3

    n = 0.0
    for (dx, dy, dz, ii, jj, kk) in [
        (x0, y0, z0, i, j, k),
        (x1, y1, z1, i + i1, j + j1, k + k1),
        (x2, y2, z2, i + i2, j + j2, k + k2),
        (x3, y3, z3, i + 1, j + 1, k + 1)
    ]
        tt = 0.6 - dx * dx - dy * dy - dz * dz
        if tt >= 0.0
            tt *= tt
            gi = _SIMPLEX_GRAD3[_simplex_hash3(ii, jj, kk, seed)]
            n += tt * tt * (gi[1] * dx + gi[2] * dy + gi[3] * dz)
        end
    end

    return 32.0 * n
end

# ---- Worley (Cellular) Noise ----

"""
    worley_noise_2d(x::Float64, y::Float64, seed::UInt64; nth::Int=1) -> Float64

2D Worley (cellular) noise. Returns distance to the Nth closest feature point.
Output is in [0, ~1.5] range (not strictly bounded). nth=1 gives classic Worley.
Useful for stone textures, biome boundaries, and organic cell patterns.
"""
function worley_noise_2d(x::Float64, y::Float64, seed::UInt64; nth::Int=1)::Float64
    xi = floor(Int, x)
    yi = floor(Int, y)

    distances = Float64[]

    # Check 3x3 neighborhood of cells
    for dy in -1:1, dx in -1:1
        cx = xi + dx
        cy = yi + dy
        # Deterministic feature point per cell
        h = UInt64(cx) * UInt64(374761393) + UInt64(cy) * UInt64(668265263) + seed
        h = xor(h, h >> 13) * UInt64(1274126177)
        h = xor(h, h >> 16)
        # Feature point position within cell [0, 1)
        fpx = Float64(cx) + Float64(h & 0xFFFF) / 65536.0
        h = xor(h * UInt64(6364136223846793005), h >> 17)
        fpy = Float64(cy) + Float64(h & 0xFFFF) / 65536.0

        ddx = x - fpx
        ddy = y - fpy
        push!(distances, sqrt(ddx * ddx + ddy * ddy))
    end

    sort!(distances)
    idx = min(nth, length(distances))
    return distances[idx]
end

# ---- FBM Variants ----

"""
    simplex_fbm_2d(x::Float64, y::Float64; octaves, frequency, persistence, seed) -> Float64

Fractal Brownian Motion using simplex noise. Returns values in approximately [-1, 1].
"""
function simplex_fbm_2d(x::Float64, y::Float64;
                         octaves::Int=6,
                         frequency::Float64=0.01,
                         persistence::Float64=0.5,
                         seed::UInt64=UInt64(42))::Float64
    value = 0.0
    amplitude = 1.0
    freq = frequency
    max_value = 0.0

    for _ in 1:octaves
        value += simplex_noise_2d(x * freq, y * freq, seed) * amplitude
        max_value += amplitude
        amplitude *= persistence
        freq *= 2.0
    end

    return value / max_value
end

"""
    ridge_fbm_2d(x::Float64, y::Float64; octaves, frequency, persistence, seed) -> Float64

Ridged fractal noise: sharp mountain ridges via `1 - abs(noise)`.
Returns values in [0, 1] range with sharp peaks.
"""
function ridge_fbm_2d(x::Float64, y::Float64;
                       octaves::Int=6,
                       frequency::Float64=0.01,
                       persistence::Float64=0.5,
                       seed::UInt64=UInt64(42))::Float64
    value = 0.0
    amplitude = 1.0
    freq = frequency
    max_value = 0.0
    weight = 1.0

    for _ in 1:octaves
        signal = simplex_noise_2d(x * freq, y * freq, seed)
        signal = 1.0 - abs(signal)
        signal *= signal  # Square for sharper ridges
        signal *= weight
        weight = clamp(signal * 2.0, 0.0, 1.0)  # Feedback for sharper features

        value += signal * amplitude
        max_value += amplitude
        amplitude *= persistence
        freq *= 2.0
    end

    return value / max_value
end

"""
    billow_fbm_2d(x::Float64, y::Float64; octaves, frequency, persistence, seed) -> Float64

Billow noise: puffy, cloud-like shapes via `abs(noise)`.
Returns values in [0, 1] range. Good for mesas, sand dunes, rolling hills.
"""
function billow_fbm_2d(x::Float64, y::Float64;
                        octaves::Int=6,
                        frequency::Float64=0.01,
                        persistence::Float64=0.5,
                        seed::UInt64=UInt64(42))::Float64
    value = 0.0
    amplitude = 1.0
    freq = frequency
    max_value = 0.0

    for _ in 1:octaves
        signal = abs(simplex_noise_2d(x * freq, y * freq, seed))
        value += signal * amplitude
        max_value += amplitude
        amplitude *= persistence
        freq *= 2.0
    end

    return value / max_value
end

# ---- Domain Warping ----

"""
    domain_warp_2d(x::Float64, y::Float64, noise_fn::Function,
                   warp_fn::Function, amplitude::Float64) -> Float64

Domain warping: distort input coordinates through a warp noise field
before sampling the primary noise. Creates organic, non-repetitive patterns.

# Arguments
- `noise_fn(x, y) -> Float64`: Primary noise function to sample
- `warp_fn(x, y) -> Float64`: Warp noise function for coordinate distortion
- `amplitude`: How far coordinates are warped (world units)

# Example
```julia
seed = UInt64(42)
warped = domain_warp_2d(x, y,
    (x, y) -> simplex_fbm_2d(x, y; seed=seed),
    (x, y) -> simplex_fbm_2d(x, y; seed=seed + 1),
    50.0)
```
"""
function domain_warp_2d(x::Float64, y::Float64,
                         noise_fn::Function,
                         warp_fn::Function,
                         amplitude::Float64)::Float64
    # Sample warp field at two offset positions for X and Y distortion
    wx = warp_fn(x, y) * amplitude
    wy = warp_fn(x + 5.2, y + 1.3) * amplitude
    return noise_fn(x + wx, y + wy)
end
