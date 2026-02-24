#include <metal_stdlib>
using namespace metal;

// ---- Shared particle types ----

struct Particle {
    float4 pos_lifetime;      // xyz = position, w = current lifetime
    float4 vel_max_lifetime;  // xyz = velocity, w = max lifetime
    float4 size_flags;        // x = start_size, y = end_size, z = flags (1=alive), w = unused
    float4 color;             // rgba
};

struct ParticleCounters {
    atomic_uint alive_count;
    atomic_uint dead_count;
    atomic_uint emit_count;
};

// ---- Simulate parameters ----

struct SimParams {
    float dt;
    float gravity;
    int   max_particles;
    float _pad1;
};

// ---- Simulate kernel ----

kernel void particle_simulate(
    device Particle*          particles [[buffer(0)]],
    device ParticleCounters*  counters  [[buffer(1)]],
    constant SimParams&       params    [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    if (int(tid) >= params.max_particles) return;

    // Only process alive particles (flags.z == 1.0)
    if (particles[tid].size_flags.z < 0.5) return;

    float dt = params.dt;

    // Age the particle
    float lifetime = particles[tid].pos_lifetime.w + dt;
    float max_lifetime = particles[tid].vel_max_lifetime.w;

    if (lifetime >= max_lifetime) {
        // Kill the particle
        particles[tid].size_flags.z = 0.0; // mark as dead
        particles[tid].pos_lifetime.w = max_lifetime;

        // Decrement alive count, increment dead count
        atomic_fetch_sub_explicit(&counters->alive_count, 1, memory_order_relaxed);

        return;
    }

    // Apply gravity to velocity
    float3 vel = particles[tid].vel_max_lifetime.xyz;
    vel.y += params.gravity * dt;

    // Integrate position
    float3 pos = particles[tid].pos_lifetime.xyz;
    pos += vel * dt;

    // Write back
    particles[tid].pos_lifetime = float4(pos, lifetime);
    particles[tid].vel_max_lifetime = float4(vel, max_lifetime);
}
