# RTX 3060 shader performance investigation

Latest implementation order: [profile-guided optimization plan](profile_guided_optimization.md)
(2026-11-09), based on the user-provided RTX 3060 direct/face captures. Hardware
measurement limitations below describe the earlier investigation.

## Terrain edit empty-space skipping follow-up

Edited voxel blocks now consume their existing exact summaries before voxel
lookup. An empty root skips 16³; an empty child skips 4³. Mixed groups retain
per-voxel lookup, including thin geometry, emission and zero-opacity glass with
a refractive index. Missing summary pointers retain the original path. This
does not enlarge the conservative 16³ terrain skip cap in overlay chunks and
does not change the GPU payload or unedited terrain representation.

Enabled by default. Use `-Dterrain-overlay-skips=false` for the old shader and
`-Dterrain-overlay-skips=true` for the candidate. The switch specializes every
shader, including primary/optical, shadow, picking and GI paths. Application
startup prints the selection. Compare identical edited scenes using
`zig build run -Doptimize=ReleaseSafe -- --gpu-stats`; append the build option
before `--` to select a baseline. Unedited scenes do not exercise this change.

`zig build test-hierarchy -Doptimize=ReleaseSafe` runs both variants against the
same uploaded sparse edited block containing a small emitter and clear glass,
with a neighboring solid block for primary hits. It checks exact hit/visibility
parity at signed boundaries and diagonal crossings, confirms empty-group skip
sizes, then compares 96×96 orthographic primary and 12-voxel shadow-ray images.
Timings exclude uploads, warm each variant with four draws, and alternate order
across six batches of eight draws. Reported medians are CPU wall time with
`glFinish`, in milliseconds per draw, on software Mesa/EGL:

| Upload mode | Rays | Baseline ms | Empty-group skips ms | Ratio |
| --- | --- | ---: | ---: | ---: |
| Incremental | Primary | 1.127 | 0.606 | 1.86× |
| Incremental | Shadow | 0.588 | 0.433 | 1.36× |
| Snapshot | Primary | 1.089 | 0.603 | 1.81× |
| Snapshot | Shadow | 0.682 | 0.431 | 1.58× |

All benchmark pixels were identical. ReleaseSafe application build, CPU tests
and the full hierarchy target passed, including both shader-profile compilation,
lighting cutoff checks, edits, upload cancellation/publication and moving terrain.
These are narrow sparse-block measurements, not whole-frame or RTX 3060 gains.
Dense mixed blocks can pay extra summary-fetch cost with little skipping; actual
hardware timings and representative scene measurements remain pending because
`nvidia-smi` still cannot communicate with the NVIDIA driver here.

## Earlier investigation and experiments

Source review: 2026-11-07. These are ranked experiments, not measured speedups.
The available environment's `nvidia-smi` could not communicate with the NVIDIA
driver, so no RTX 3060 timing, register allocation, or spill measurements were
obtained. Existing working-tree changes were included in this review.

Continuation: 2026-11-08. Asynchronous world/GI timestamp queries are already
available through `--gpu-stats` (120-sample median/p95/p99 batches). NVIDIA's
driver is still inaccessible here, so hardware measurements remain pending.

The first vector-fetch experiment is selectable with
`-Dvector-world-headers=true`; the default `false` retains the scalar baseline.
Chunk, block and voxel-block headers use one `RGBA32UI` fetch per record instead
of four `R32UI` fetches. Header indices remain record indices; CPU packing and
payload bytes are unchanged. Immediate, staged-snapshot and incremental uploads
share the layout choice with every shader, including selection, icons and GI.
Empty allocations hold a complete texel and texture limits count texels in the
selected format. This follows the [Khronos buffer-texture format and size rules](https://wikis.khronos.org/opengl/GLAPI/glTexBuffer).

This experiment covers headers only. Terrain/hierarchy nodes still share the
scalar index pool; a separate vector view and its alignment/publication work
remain a later, independently measurable experiment. No lighting samples,
geometry rings or optical budgets change, and no RTX speedup is claimed.

For A/B runs, alternate these commands with the same camera, window size and
published terrain; wait for streaming to settle before collecting GPU batches:

```sh
zig build run -Doptimize=ReleaseSafe -Dvector-world-headers=false -- --shader=rtx3060 --gpu-stats
zig build run -Doptimize=ReleaseSafe -Dvector-world-headers=true -- --shader=rtx3060 --gpu-stats
```

Startup prints the selected header layout. Repeat on the authored test scene
with `--world=test-scene` and on terrain with `--uploads=snapshot` to distinguish
the traversal change from upload behavior. Fixed-camera capture, presentation
timing, resolution/swap controls and persisted benchmark reports remain pending.

Validation for this continuation: `zig build`, `zig build test`, and `zig build
test-render` passed in `ReleaseSafe` with both `-Dvector-world-headers=false`
and `true`. The full render suite includes hierarchy checks for both incremental
and staged snapshot uploads, signed boundaries, moving terrain, edits, GI,
lighting caches, both shader profiles, reflection, refraction and icons. Analytic
floor comparisons reported zero incorrect faces out of 262,144 per case within
the existing tolerance. All 38 generated icon/menu PNGs were byte-identical
between the scalar and vector runs. Tests also cover texture-limit accounting
and minimum empty-buffer storage. These are correctness results on software
Mesa/EGL, not hardware performance measurements.

Implementation follow-up: shared material lookup now exposes packed bytes,
combines voxel occupancy/material header reads, and reuses the header already
loaded by render lookup. Point/sky shadow traversal caches its current chunk
header and checks packed opacity/emission/RGB without decoding shading channels.
Point lights reject back-facing and out-of-radius samples before normalization;
thick emissive endpoints reuse their source sample. The mandatory zenith sky ray
uses a vertical interval traversal, with parity checks against the general DDA
at signed voxel/chunk boundaries and terrain surfaces. These changes preserve
the configured light count, sky directions/weights and optical budgets. They
also apply to direct visibility evaluated by GI. Hardware timing remains pending.

Validation for this follow-up: `zig build`, `zig build test`, `zig build
test-hierarchy`, and `zig build test-render` passed with `-Doptimize=ReleaseSafe`.
GPU checks used software Mesa/EGL, including both shader profiles, GI, analytic
point/sky/combined floor lighting, sky sample weights, lamp self-shadowing,
cache invalidation, reflection and transmission. Analytic floor checks reported
zero mismatches across 262,144 faces per case within the existing byte tolerance.

`rtx3060` currently selects the same desktop GLSL entry points as `desktop`,
`vega56`, and `vega` (`src/graphics/gpuProfile.zig:18`). The original review used
legacy face shading with point lighting, sky visibility and GI disabled.
Point-light objects and sky lighting were restored on 2026-11-08 by selecting
`.direct` in `src/lighting.zig`; indirect GI remains disabled. New measurements
must record this lighting change and include direct-lighting cache behavior.
The subsequent temporary quality preset limits direct lighting to geometry
rings 0/1 (`direct_geometry_ring_count = 2`): terrain radius 768 plus the policy
guard. Farther surfaces use legacy face shading before any lighting-cache work;
shadow traversal from near surfaces still includes distant geometry. Use zero
for unlimited direct lighting when comparing against the earlier direct preset.

NVIDIA recommends reducing redundant memory access and prolonged divergent
execution on Ampere. Register use also constrains occupancy. These support the
experiments below, but do not establish this renderer's actual bottleneck.
[NVIDIA Ampere tuning guide](https://docs.nvidia.com/cuda/ampere-tuning-guide/).
Record the actual card and memory configuration: NVIDIA lists RTX 3060 variants
with different memory bus widths, so the profile name alone is insufficient.
[NVIDIA RTX 3060 specifications](https://www.nvidia.com/en-us/geforce/graphics-cards/30-series/rtx-3060-3060ti/).

1. **Establish GPU timings before choosing an optimization.**

   Add asynchronous OpenGL timer queries around the world draw and GI update,
   with separate CPU timings for streaming/upload submission and presentation.
   Consume available query results several frames later; do not introduce a
   per-frame `glFinish()` or wait for unavailable results. The application now
   reports isolated GPU world/GI timing with `--gpu-stats`; separate presentation
   timing and a reproducible benchmark capture are still missing.
   The software EGL terrain benchmark in `src/hierarchyRenderChecks.zig:538`
   uses a 96x96 target and CPU timing with `glFinish()`; it is not a 3060 baseline.

   Use an optimized build, fixed seed, published geometry, camera, resolution,
   and lighting mode. Record driver, renderer, framebuffer size, and swap
   interval. Compare warmed stationary views separately from moving/streaming
   frames. Test sky, near ground, grazing horizon, authored geometry, and glass.
   Report median and p95 GPU milliseconds over hundreds of frames, alternating
   baseline and candidate runs. Repeat at 720p and 1080p to identify pixel cost.
   Use Nsight's supported OpenGL activities and inspect register usage, local
   memory, texture stalls, and active lanes where the installed version exposes
   them. Check activity support before depending on a particular profiler view.
   [NVIDIA shader profiler documentation](https://docs.nvidia.com/nsight-graphics/UserGuide/shader-profiler.html).

2. **Fetch four-word records together. High-priority, moderate change.**

   `sampleTerrain()` (`src/graphics/shaders/include/hierarchy.glsl:61`) issues
   four scalar buffer-texture fetches at each visited node, with up to five
   levels. `hierarchyFetch()` and the three header readers do the same.
   `src/world/world.zig:1115` currently binds every world buffer as `GL_R32UI`.

   Experiment with `GL_RGBA32UI` header views and a vector view of aligned
   hierarchy/terrain nodes; load a node with one `texelFetch`. Keep an R32UI
   view for scalar palette indices sharing the index pool, or separate nodes
   into their own buffer. Verify four-word alignment at every packing path and
   convert word offsets to texel offsets explicitly. Update staged and immediate
   uploads together, including empty-buffer allocation sizes and texture limits.
   Palette pairs can similarly use `GL_RG32UI` as a separate experiment.

   This reduces source-level fetch instructions, not the record's 16 bytes or
   necessarily physical memory transactions. The compiler/cache may already
   combine some work. Compare against scalar reads that defer leaf-only height
   loads until needed; confirm a real GPU-time improvement.

3. **Reuse traversal state between samples. High potential, moderate/high change.**

   Every `traceBoundary()` iteration starts material lookup from world/chunk
   coordinates. `sampleTerrain()` restarts at the tree root. Nearby samples often
   share the chunk and several ancestors. Cache the current chunk header first;
   then experiment with retaining a small terrain path and ascending only when
   the ray exits its node. Measure added registers against saved dependent loads.
   A large per-ray stack could negate the benefit.

   There is also straightforward duplicated work on authored geometry:
   `sampleRenderMaterial()` reads a chunk header, then `sampleHierarchy()` reads
   it again (`frag_traverse.glsl:107`, `hierarchy.glsl:155`). Occupancy and material
   lookup separately fetch the voxel-block header (`world_functions.glsl:222`).
   Pass existing headers/local indices into helpers and defer material decoding
   until a hit requires it. Check generated code: inlining may already eliminate
   some duplicate operations.

   Terrain already uses min/max height bounds for uniform cube skips. A later
   experiment can traverse ray intervals against column bounds directly, skipping
   to a horizontal node exit or relevant height plane. Preserve edited-block
   overlays and the exact union of published columns; do not cross an edited
   region based only on underlying terrain bounds.

4. **Compile a matte opaque shader without the optical stack. High potential.**

   `shadeSelectionOutline()` always calls `castReflectedRay()`. That function
   declares `OpticalRay pending[16]` and supports 32 segments, six reflection
   bounces, and 12 interfaces (`frag_traverse.glsl:224`). A ray contains 19 scalar
   values: the array represents 304 values before compiler optimization/layout.
   Dynamic indexing makes register allocation/local-memory traffic worth checking.
   This is a risk to measure, not evidence that 304 registers are allocated.

   Pure matte terrain needs one first-hit trace and local shading. Add a separate
   compiled variant selected only when published material metadata proves that
   the scene contains no transmitting or reflective materials. Edits, camera
   medium, and publication must participate in that decision. Preserve first-hit
   selection, emission, icon alpha, and the selected lighting mode.

   A branch inside the existing shader may save instructions without reducing
   its static register/local-memory allocation. For mixed scenes, a later option
   is a primary pass followed by optical work only for marked pixels; include
   intermediate-buffer traffic and additional dispatch/draw cost in the comparison.
   Alternatively keep the current ray in scalar variables and store only deferred
   reflected branches, with packed medium data. Preserve traversal order and
   segment limits; reducing stack size requires a proven maximum live depth.

5. **Hoist ray invariants. Small, relatively contained experiment.**

   `skipEmptyRegion()` (`frag_traverse.glsl:36`) divides by ray direction when
   computing exit times and again when rebuilding `tMax`. Compute a signed
   reciprocal once per ray and reuse it, with explicit zero-axis handling.
   Return the crossing distance to shadow traversal rather than reconstructing
   it through a dot-product quotient. Confirm whether the driver already hoists
   these expressions before predicting a benefit.

   Preserve negative-direction boundary ownership, simultaneous edge/corner
   crossings, and clamps that prevent floating-point backtracking. Reciprocal
   multiplication can round differently from division; existing boundary tests
   are essential. Do not remove the documented clamps as an arithmetic shortcut.

   `getRay()` also constructs an invariant camera basis per invocation. Upload
   right/up/forward vectors or interpolate an unnormalized vertex ray and normalize
   in the fragment shader. This is a lower priority than repeated traversal work.

6. **When direct lighting returns, eliminate duplicate cache-miss shading.**

   `cachedLightingLevel()` (`lighting_cache.glsl:20`) correctly avoids reading
   same-draw writes. However, every pixel missing the cache calls
   `evaluateLighting()`, including failed claimants and pixels outside the write
   budget. The default configuration can request nine sky visibility rays plus
   up to eight point-light rays per evaluated surface, subject to normal/radius
   rejection. `lighting_cache_entries_per_frame` bounds writes, not tracing work.

   Investigate a face-request pass, deduplicated lighting work, then a shading
   pass that reads completed results. Bound actual jobs/rays and define behavior
   when work remains pending. A previous-frame estimate changes temporal quality;
   an exact same-frame result requires completing the required work before shade.
   The existing GI queue is useful infrastructure, but GI is already a separate
   budgeted path and should not be described as the direct-cache implementation.

   `lightingCache.Clock.advance()` invalidates the entire cache on geometry
   revision changes, including terrain publication. Measure cold-cache spikes.
   Regional invalidation would need shadow dependencies: retaining an unchanged
   face alone is unsafe because a changed distant occluder can alter its lighting.
   A visibility-only sampler can also avoid decoding full RGB/material data on
   ordinary shadow steps, retaining emitter color checks where required.

7. **Optional quality controls after the equivalent-image experiments.**

   Render-scale control is a direct way to reduce fragment work. A 0.75 scale on
   both axes launches 56.25% as many fragments, but does not guarantee the same
   reduction in total frame time and needs an acceptable upscale/outline policy.
   Coarser terrain rings, fewer sky samples, and smaller reflection budgets are
   explicit quality tradeoffs. Changing lighting samples or GI budgets cannot
   improve the original legacy baseline because those paths were compiled out.

Implementation order: timer queries; vector record fetches and header reuse;
matte variant; reciprocal reuse; retained terrain traversal state. Reorder after
the first actual hardware profile. Address direct-lighting cache misses when
direct lighting is enabled. Use separate A/B switches so gains remain attributable.

For implemented candidates, run `zig build test-hierarchy` and `zig build
test-render`, plus CPU tests when packing/publication changes. Compare the same
published geometry against reference images/hits for signed coordinates, grazing
rays, coarse/fine joins, edited air, glass, and reflections. Retain both shader
profiles in compilation coverage. Software EGL verifies behavior, not RTX speed.

Avoid treating the existing 1024 primary-step cap as an easy performance slider:
lowering it can turn valid distant geometry into sky; exhausting the shadow cap
returns occlusion. Empty-region skipping and loaded-volume exit are already
implemented. Selection already uses only three center rays in the fullscreen
vertex shader, so moving selection out of each fragment is already done.

This OpenGL implementation performs software traversal in GLSL. Selecting the
RTX profile or changing GLSL versions does not route these loops through RT
cores. Hardware ray tracing would be a separate backend/representation project,
not a first shader-tuning step.
