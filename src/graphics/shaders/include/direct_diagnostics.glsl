#ifndef DIRECT_DIAGNOSTICS
#define DIRECT_DIAGNOSTICS
// Fragment-only, independently compiled, and never shares GI's image bindings.
#if DIRECT_DIAGNOSTICS_ENABLED && !USE_GI
layout(r32ui, binding = 3) coherent uniform uimageBuffer uDirectDiagnostics;
uniform uint uDiagnosticStride; // 0 disables this draw; otherwise a power of two
int diagnosticContext = 0; // primary, optical, point visibility, sky visibility
void diagnosticAdd(int counter) {
    if (uDiagnosticStride == 0u) return;
    uvec2 pixel = uvec2(gl_FragCoord.xy);
    uint hash = pixel.x * 0x8da6b343u ^ pixel.y * 0xd8163841u;
    hash ^= hash >> 16u;
    hash *= 0x7feb352du;
    hash ^= hash >> 15u;
    if ((hash & (uDiagnosticStride - 1u)) != 0u) return;
    // Independent hash bits shard sampled invocations across 64 counters.
    int index = (int((hash >> 16u) & 63u) * 28 + counter) * 2;
    uint old = imageAtomicAdd(uDirectDiagnostics, index, 1u);
    // Explicit high word: even a saturated shard never silently wraps to zero.
    if (old == 0xffffffffu) imageAtomicAdd(uDirectDiagnostics, index + 1, 1u);
}
#define DIAG_ADD(counter) diagnosticAdd(counter)
#define DIAG_CONTEXT(value) diagnosticContext = value
#define DIAG_NODES() diagnosticAdd(19 + diagnosticContext)
#define DIAG_STEPS() diagnosticAdd(15 + diagnosticContext)
#define DIAG_EXHAUSTED() diagnosticAdd(24 + diagnosticContext)
#else
#define DIAG_ADD(counter)
#define DIAG_CONTEXT(value)
#define DIAG_NODES()
#define DIAG_STEPS()
#define DIAG_EXHAUSTED()
#endif
#endif
