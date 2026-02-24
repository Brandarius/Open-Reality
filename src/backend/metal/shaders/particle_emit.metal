#include <metal_stdlib>
using namespace metal;

// ---- Shared particle types ----

struct Particle {
    float4 pos_lifetime;      // xyz = position, w = current lifetime
    float4 vel_max_lifetime;  // xyz = velocity, w = max lifetime
    float4 size_flags;        // x = start_size, y = end_size, z = flags, w = unused
    float4 color;             // rgba
};

struct ParticleCounters {
    atomic_uint alive_count;
    atomic_uint dead_count;
    atomic_uint emit_count;
};

// ---- Emit parameters ----

struct EmitParams {
    float4 position;       // xyz + pad
    float4 velocity_min;   // xyz + pad
    float4 velocity_max;   // xyz + pad
    float4 color;          // rgba
    float  lifetime;
    float  size_start;
    float  size_end;
    int    emit_count;
    uint   seed;
    float  _pad1, _pad2, _pad3;
};

// ---- PCG hash for RNG ----

uint pcg_hash(uint input) {
    uint state = input * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

float rand_float(uint seed) {
    return float(pcg_hash(seed)) / float(0xFFFFFFFFu);
}

float rand_range(float min_val, float max_val, uint seed) {
    return mix(min_val, max_val, rand_float(seed));
}

// ---- Emit kernel ----

kernel void particle_emit(
    device Particle*          particles  [[buffer(0)]],
    device uint*              dead_list  [[buffer(1)]],
    device ParticleCounters*  counters   [[buffer(2)]],
    constant EmitParams&      params     [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    if (int(tid) >= params.emit_count) return;

    // Atomically decrement dead count to claim a dead particle slot
    uint dead_idx = atomic_fetch_sub_explicit(&counters->dead_count, 1, memory_order_relaxed);
    if (dead_idx == 0) {
        // No dead particles available, restore counter
        atomic_fetch_add_explicit(&counters->dead_count, 1, memory_order_relaxed);
        return;
    }
    dead_idx -= 1; // Convert from count to index

    // Get the particle index from the dead list
    uint particle_idx = dead_list[dead_idx];

    // Generate per-thread random seeds
    uint seed_base = params.seed + tid * 7u + particle_idx * 13u;
    uint seed_x = pcg_hash(seed_base);
    uint seed_y = pcg_hash(seed_base + 1u);
    uint seed_z = pcg_hash(seed_base + 2u);

    // Random velocity within range
    float vx = rand_range(params.velocity_min.x, params.velocity_max.x, seed_x);
    float vy = rand_range(params.velocity_min.y, params.velocity_max.y, seed_y);
    float vz = rand_range(params.velocity_min.z, params.velocity_max.z, seed_z);

    // Initialize particle
    particles[particle_idx].pos_lifetime     = float4(params.position.xyz, 0.0);
    particles[particle_idx].vel_max_lifetime = float4(vx, vy, vz, params.lifetime);
    particles[particle_idx].size_flags       = float4(params.size_start, params.size_end, 1.0, 0.0);
    particles[particle_idx].color            = params.color;

    // Increment alive count
    atomic_fetch_add_explicit(&counters->alive_count, 1, memory_order_relaxed);
}
