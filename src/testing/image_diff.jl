# Image comparison for visual regression testing

"""
    ImageDiffResult

Result of comparing two images pixel-by-pixel.
"""
struct ImageDiffResult
    passed::Bool
    psnr::Float64                                       # Peak Signal-to-Noise Ratio (dB); Inf if identical
    diff_pixel_count::Int                               # Pixels exceeding per-channel threshold
    diff_pixel_fraction::Float64                        # diff_pixel_count / total_pixels
    max_channel_diff::Int                               # Maximum per-channel difference (0-255)
    diff_image::Union{Matrix{RGBA{Float32}}, Nothing}   # Visual diff (amplified), or nothing
end

"""
    compare_images(actual::Matrix{<:Colorant}, reference::Matrix{<:Colorant};
                   per_channel_threshold::Int=2,
                   max_diff_fraction::Float64=0.005,
                   generate_diff::Bool=true) -> ImageDiffResult

Compare two images pixel-by-pixel for visual regression testing.

- `per_channel_threshold`: Max allowed difference per R/G/B channel (0-255 scale).
  Default 2 handles GPU driver rounding differences.
- `max_diff_fraction`: Max fraction of pixels allowed to differ (0.0-1.0).
  Default 0.005 = 0.5% of pixels.
- `generate_diff`: Whether to produce a visual diff image showing differences.

Returns an `ImageDiffResult` with pass/fail status, PSNR, and optional diff image.
"""
function compare_images(actual::Matrix{<:Colorant}, reference::Matrix{<:Colorant};
                        per_channel_threshold::Int=2,
                        max_diff_fraction::Float64=0.005,
                        generate_diff::Bool=true)
    if size(actual) != size(reference)
        return ImageDiffResult(false, 0.0, 0, 1.0, 255,
            nothing)
    end

    h, w = size(actual)
    total_pixels = h * w

    diff_count = 0
    max_diff = 0
    mse_sum = 0.0

    diff_image = generate_diff ? Matrix{RGBA{Float32}}(undef, h, w) : nothing

    for row in 1:h, col in 1:w
        ar, ag, ab = _to_uint8(actual[row, col])
        rr, rg, rb = _to_uint8(reference[row, col])

        dr = abs(Int(ar) - Int(rr))
        dg = abs(Int(ag) - Int(rg))
        db = abs(Int(ab) - Int(rb))

        pixel_max = max(dr, dg, db)
        max_diff = max(max_diff, pixel_max)

        mse_sum += dr^2 + dg^2 + db^2

        is_diff = pixel_max > per_channel_threshold
        if is_diff
            diff_count += 1
        end

        if generate_diff
            if is_diff
                # Show differing pixels in red, intensity proportional to difference (10x amplified)
                intensity = min(Float32(pixel_max) * 10.0f0 / 255.0f0, 1.0f0)
                diff_image[row, col] = RGBA{Float32}(intensity, 0.0f0, 0.0f0, 1.0f0)
            else
                # Non-differing pixels: dark ghost of original
                diff_image[row, col] = RGBA{Float32}(
                    Float32(ar) / 255.0f0 * 0.2f0,
                    Float32(ag) / 255.0f0 * 0.2f0,
                    Float32(ab) / 255.0f0 * 0.2f0,
                    1.0f0
                )
            end
        end
    end

    mse = mse_sum / (total_pixels * 3)
    psnr = mse == 0.0 ? Inf : 10.0 * log10(255.0^2 / mse)

    diff_fraction = diff_count / total_pixels
    passed = diff_fraction <= max_diff_fraction

    return ImageDiffResult(passed, psnr, diff_count, diff_fraction, max_diff, diff_image)
end

"""
    compute_psnr(actual::Matrix{<:Colorant}, reference::Matrix{<:Colorant}) -> Float64

Compute Peak Signal-to-Noise Ratio between two images.
Returns Inf for identical images. Higher is better: >40dB excellent, >30dB good.
"""
function compute_psnr(actual::Matrix{<:Colorant}, reference::Matrix{<:Colorant})
    size(actual) != size(reference) && return 0.0

    h, w = size(actual)
    mse_sum = 0.0

    for row in 1:h, col in 1:w
        ar, ag, ab = _to_uint8(actual[row, col])
        rr, rg, rb = _to_uint8(reference[row, col])
        mse_sum += (Int(ar) - Int(rr))^2 + (Int(ag) - Int(rg))^2 + (Int(ab) - Int(rb))^2
    end

    mse = mse_sum / (h * w * 3)
    return mse == 0.0 ? Inf : 10.0 * log10(255.0^2 / mse)
end

# Extract R, G, B as UInt8 values from any Colorant
function _to_uint8(c::Colorant)
    rgba = RGBA{Float32}(c)
    r = round(UInt8, clamp(red(rgba), 0.0f0, 1.0f0) * 255.0f0)
    g = round(UInt8, clamp(green(rgba), 0.0f0, 1.0f0) * 255.0f0)
    b = round(UInt8, clamp(blue(rgba), 0.0f0, 1.0f0) * 255.0f0)
    return r, g, b
end
