#include <metal_stdlib>
using namespace metal;

// ---- Counter buffer layout ----

struct ParticleCounters {
    atomic_uint alive_count;
    atomic_uint dead_count;
    atomic_uint emit_count;
};

// ---- Indirect draw arguments (matches MTLDrawPrimitivesIndirectArguments) ----

struct IndirectArgs {
    uint vertexCount;
    uint instanceCount;
    uint vertexStart;
    uint baseInstance;
};

// ---- Fill indirect draw arguments kernel ----
// Writes alive_count * 6 (vertices per billboard quad) into the indirect buffer.

kernel void particle_fill_indirect(
    device ParticleCounters*  counters [[buffer(0)]],
    device IndirectArgs*      args     [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid != 0) return;

    uint alive = atomic_load_explicit(&counters->alive_count, memory_order_relaxed);

    args->vertexCount   = alive * 6; // 6 vertices per billboard quad (2 triangles)
    args->instanceCount = 1;
    args->vertexStart   = 0;
    args->baseInstance  = 0;
}
