# LRU chunk data cache for streaming terrain
#
# Keeps recently accessed chunk data in memory to avoid regenerating
# chunks the player revisits shortly after leaving.

const ChunkCoord = Tuple{Int, Int}

"""
    ChunkCacheEntry{T}

A cached chunk data entry with access tracking for LRU eviction.
"""
mutable struct ChunkCacheEntry{T}
    coord::ChunkCoord
    data::T
    last_access_frame::Int
end

"""
    ChunkCache{T}

LRU cache for chunk data. Evicts least-recently-used entries when capacity is exceeded.
"""
mutable struct ChunkCache{T}
    entries::Dict{ChunkCoord, ChunkCacheEntry{T}}
    max_entries::Int
    current_frame::Int

    ChunkCache{T}(; max_entries::Int=256) where T =
        new{T}(Dict{ChunkCoord, ChunkCacheEntry{T}}(), max_entries, 0)
end

"""
    cache_get(cache::ChunkCache{T}, coord::ChunkCoord) -> Union{T, Nothing}

Retrieve data from cache, updating access time. Returns `nothing` on miss.
"""
function cache_get(cache::ChunkCache{T}, coord::ChunkCoord)::Union{T, Nothing} where T
    entry = get(cache.entries, coord, nothing)
    if entry !== nothing
        entry.last_access_frame = cache.current_frame
        return entry.data
    end
    return nothing
end

"""
    cache_put!(cache::ChunkCache{T}, coord::ChunkCoord, data::T)

Insert data into cache, evicting LRU entries if over capacity.
"""
function cache_put!(cache::ChunkCache{T}, coord::ChunkCoord, data::T) where T
    if haskey(cache.entries, coord)
        cache.entries[coord].data = data
        cache.entries[coord].last_access_frame = cache.current_frame
        return
    end

    # Evict if over capacity
    while length(cache.entries) >= cache.max_entries
        _evict_lru!(cache)
    end

    cache.entries[coord] = ChunkCacheEntry{T}(coord, data, cache.current_frame)
end

"""
    cache_remove!(cache::ChunkCache{T}, coord::ChunkCoord) -> Bool

Remove an entry from cache. Returns true if it existed.
"""
function cache_remove!(cache::ChunkCache{T}, coord::ChunkCoord)::Bool where T
    return delete!(cache.entries, coord) !== nothing
end

"""
    cache_advance_frame!(cache::ChunkCache)

Advance the internal frame counter. Call once per frame.
"""
function cache_advance_frame!(cache::ChunkCache)
    cache.current_frame += 1
end

"""
    cache_clear!(cache::ChunkCache)

Remove all entries from the cache.
"""
function cache_clear!(cache::ChunkCache)
    empty!(cache.entries)
end

function _evict_lru!(cache::ChunkCache)
    if isempty(cache.entries)
        return
    end
    oldest_coord = first(keys(cache.entries))
    oldest_frame = cache.entries[oldest_coord].last_access_frame
    for (coord, entry) in cache.entries
        if entry.last_access_frame < oldest_frame
            oldest_frame = entry.last_access_frame
            oldest_coord = coord
        end
    end
    delete!(cache.entries, oldest_coord)
end
