# Global Illumination — Implementation Specification

## Goal
Implement the four-stage lighting design from the supplied sketch in the existing Zig voxel renderer. Inspect the current project architecture and reuse its world editing, chunk streaming, voxel traversal, GPU upload, shader generation, and light-object facilities. Do not replace existing placement or destruction systems.

## 1. Compile-time selection
- Preserve the current face-orientation shading as `legacy`.
- Add `global_illumination` as a separate build-time lighting mode, selected in a central Zig configuration or build option before compiling the project.
- Compile only the selected shader code (shader defines, source generation, or distinct shader variants). No runtime `if` selecting between legacy and GI shading.
- Expose independent compile-time toggles for sky visibility, normal probes, direct point lights, and indirect hemisphere tracing, with sensible dependencies. Compile unused stages out.
- Keep sky color, sun direction/color/intensity, and per-light RGB color configurable. Values that should change without recompiling can be uniforms; feature presence is compile-time.

## 2. Surface sample and cache identity
- Lighting is associated with the *visible surface face* of a solid voxel, not with the current camera ray or screen pixel.
- Cache key: stable world-space voxel coordinate plus face index (six axis-aligned faces), and if required a world/dimension identifier. Do not key by GPU buffer slot or chunk pointer that can be recycled.
- Cache RGB radiance/irradiance or separate direct/indirect accumulations, sample count, convergence stage, dirty flag, and world-lighting revision as needed.
- Reuse the result whenever subsequent camera rays hit the same face. Cache misses enqueue work rather than repeating all rays inside the render path.
- Store a bounded, sparse cache for relevant surfaces, or chunk-local surface data with an explicit memory budget. Unloaded chunks can evict cache entries safely.
- GPU shader reads the cached lighting result efficiently. Define a safe fallback for pending entries; do not stall rendering.

## 3. Stage 1 — Sky visibility
- For each surface sample, cast a sky probe in the positive world-up direction from a slightly offset face center. A ray reaching unobstructed sky contributes configurable sky color; blocked rays contribute no direct sky visibility.
- Add configurable extra rays distributed around the upward direction to soften block-shaped skylight/shadows. Use deterministic directions per surface, preferably stratified or low-discrepancy, and a configurable sample count and angular spread.
- Weight probes appropriately for face orientation; distinguish an unobstructed upward ray from physically correct cosine-weighted sky irradiance. Never count a ray that immediately intersects its own surface.
- If an explicit sun direction is implemented, treat it separately from the broad sky probes so direct sun shadows remain directional.

## 4. Stage 2 — Face-normal probes
- Cast probe rays from the face center along its outward normal (the four directions in the sketch are 2D illustrations; 3D has six face normals).
- Use these probes to establish the initial surface exposure/visibility signal or as the first deterministic sample of the indirect estimator. Specify their weighting to avoid double-counting contributions already computed by sky probes.
- Normal probes must not themselves create illumination: they only report what the ray sees and obtain radiance from a defined source (sky, light-emitting surface, or cached bounce estimate).

## 5. Stage 3 — Light objects
- Support colored point lights, including the initially configured sun-like source above spawn and emissive/scifi light blocks using existing world/block placement capabilities.
- For a light at L and face sample at P, calculate direction `normalize(L-P)`, distance `length(L-P)`, visibility by shadow ray, and diffuse cosine `max(dot(normal, direction), 0)`.
- Use a configurable attenuation law and range; avoid singularity at near-zero distance. Add RGB light color and intensity in linear color space.
- Sunlight may be represented as a directional source rather than a nearby point light when appropriate; document the difference.
- A placed, removed, moved, or modified emissive block/light must mark affected cache entries dirty. If moving lights are later supported, either invalidate their influence regions or use a separate dynamic-light pass.

## 6. Stage 4 — Progressive indirect illumination
- Generate N hemisphere directions oriented around the surface normal using Fibonacci hemisphere sampling. One possible canonical construction is:
  - `golden_angle = pi * (3 - sqrt(5))`
  - `y = (i + 0.5) / N`, `r = sqrt(1-y*y)`, `theta = i * golden_angle`
  - local direction = `(r*cos(theta), y, r*sin(theta))`
- Transform each local hemisphere direction into the world-space frame with local +Y aligned to the face normal.
- Apply bit-reversal / low-discrepancy reordering to spread early samples across the hemisphere rather than traversing neighboring directions in sequence. A naive reversal of an arbitrary N is not a valid permutation; choose a power-of-two sample budget or define a robust index mapping.
- Progressive refinement: split the N rays into multiple configurable batches. Example schedule: 1, 2, 4, 8, 16, 32 additional samples, then optional further passes. Maintain a running weighted sum and sample count; do not reset previous work on each batch.
- Sample a hemisphere direction, trace to the first hit or sky, and accumulate incoming radiance from that result. Use cosine weighting or cosine-weighted sampling consistently, with the correct PDF; avoid treating all Fibonacci hemisphere samples as equally weighted diffuse irradiance unless the estimator accounts for it.
- For a hit on another voxel, use that surface's available direct/indirect lighting cache. Avoid cyclic dependencies and feedback explosions: start with direct lighting, then bounded bounce iterations or Jacobi-style previous-iteration reads; apply energy-conserving albedo and clamp/guard numerical errors. Missing samples should use a stable fallback, not recursively launch unbounded traces.
- Continue refinement over successive frames under a configurable per-frame ray budget. Prioritize visible surfaces and coarse initial batches, then refine stable entries. No camera movement should invalidate accumulated samples.
- Deterministic sampling ensures cached results are reproducible for a given world state.

## 7. Cache invalidation and dependencies
- The *only ordinary static-geometry invalidation triggers* are world changes such as placing/breaking/replacing a block or changing voxel geometry/material. Reuse the project's existing edit notifications; do not add a duplicate editing mechanism.
- Invalidation must propagate beyond the edited voxel: geometry can block/unblock sky rays, point-light shadows, and indirect paths on distant faces.
- Begin with a correctness-first strategy: mark potentially affected chunks/regions dirty using conservative influence bounds; for global sky or multi-bounce dependencies, provide a conservative world-lighting revision / staged invalidation fallback when exact affected surfaces cannot be proven.
- Optionally record ray-to-chunk or ray-to-region dependencies so editing a region invalidates cached faces whose rays traversed it. Maintain reverse dependency lists, including rays that previously escaped into empty space. This can reduce recomputation without sacrificing correctness.
- A dirty entry must not be reused as if valid. Rebuild progressively and display the previous value only if explicitly labeled as a temporary visual fallback.
- Cache entries for newly exposed surfaces are created on demand; entries for destroyed/covered surfaces are removed or ignored.
- Camera movement, viewport changes, and merely looking at a voxel must not invalidate lighting. Rendering may *schedule first-time cache population* and progressive refinement, which is distinct from invalidation.
- Changing sky settings, sun settings, light properties, or material reflectance changes the lighting solution and therefore requires invalidation of relevant cache data. If settings are compile-time only, a rebuild can clear the cache. Never claim geometry edits are the only possible cause of stale lighting.
- Streaming/generation of previously absent world geometry must invalidate cached rays that assumed those regions were empty, or treat unloaded regions as unknown until resolved.

## 8. Scheduling and GPU integration
- Prefer a work queue for cache misses and invalidated faces; batch ray tracing on GPU if the existing shader and buffer architecture permit it. Do not perform the full N-ray GI loop on every primary camera hit.
- Keep the camera's primary raycaster separate from the lighting update workload. Integrate with the existing hierarchical voxel/block/chunk DDA and skip acceleration.
- Limit lighting updates by rays per frame and cache memory. Include stages `uninitialized -> direct-ready -> indirect-partial -> converged`, plus a dirty state.
- Prevent stale GPU writes after world edits by checking a revision/generation when committing results.
- Accumulate lighting in linear RGB; apply exposure/tone mapping/gamma once in the final shading path. Preserve material albedo and existing face-shading behavior in legacy mode.
- Avoid GPU/CPU readbacks in the per-hit hot path.

## 9. Implementation sequence
1. Inspect current renderer and identify world-edit hooks, surface coordinates, shaders, and GPU data structures.
2. Add compile-time mode selection and prove legacy mode remains unchanged.
3. Implement face-cache lookup, pending states, update queue, and basic invalidation.
4. Implement sky visibility and normal probes, with independent compile-time toggles.
5. Implement colored point lights and shadow rays, and hook edits affecting emissive blocks.
6. Implement progressive Fibonacci hemisphere sampling with bit-reversed ordering and stable accumulation.
7. Add conservative invalidation for occlusion and indirect dependencies, then optimize with reverse dependency tracking if useful.
8. Profile GPU memory, cache hit rate, rays/frame, dirty region size, and convergence.

## 10. Acceptance criteria
- Existing legacy lighting remains selectable and visually unchanged.
- GI can be enabled before compilation; unused shader features are compiled out.
- Multiple primary ray hits on the same unchanged voxel face reuse its cache entry.
- GI refinement visibly progresses over multiple update passes, without restarting when the camera moves.
- Placing/breaking a block updates relevant illumination and shadows, including affected neighboring faces.
- Sky rays soften exposure when extra samples are enabled; light sources contribute configured RGB colors.
- No infinite bounce recursion, runaway cache growth, stale cache after chunk reuse, or unbounded per-frame work.

## Notes for Codex
This is an implementation specification, not a request to introduce a new block placement system or generic test structure. Use the existing project's concrete APIs and data layout. Before changing code, inspect them and adapt the implementation to their actual capabilities. Where the sketch is ambiguous, favor physically consistent diffuse transport and explicit bounded costs.


## Implementation notes

Implemented in `src/lighting.zig`, `src/graphics/globalIllumination.zig`, and
`src/graphics/shaders/include/gi_{cache,update}.glsl`, integrated with the existing
world revision, block-light ownership, shader specialization, and primary draw.
GI is retained as experimental and is currently disabled by default following
visual review of `screenshots/screenshot_1793615694.png` (patchy illumination and
large dark pending regions). Further GI tuning is deferred. `mode = .direct`
restores point lights plus ordered sky visibility with the persistent face cache;
`mode = .legacy` restores face-orientation shading.

- GPU FIFO + separate update draws; camera hits only read/enqueue. All queues,
  hash probing, batches, ray distances, traversal steps, and memory are bounded.
- 64 Fibonacci samples with a power-of-two bit-reversal permutation, progressive
  1/2/4/8/8/... batches, `2*cos(theta)` diffuse weights, and persistent sums/counts.
- Normal probes are a pilot replaced by hemisphere estimates. Broad upward sky
  is an exposure approximation; escaping secondary rays do not count it again.
- One bounce from earlier-frame direct-only cache data, albedo capped at 0.95,
  no cyclic indirect reads. Missing dependencies enqueue direct work and retry
  the sample without resetting its accumulated predecessors.
- Revision-based global invalidation for existing geometry/streaming hooks and
  light changes; unchanged camera/viewport state does not invalidate. Epoch
  checks guard job commits, and old queues are dropped on revision changes.
- Current limitations: one diffuse bounce, binary-transparent glass, finite-range
  point sun, coarse global invalidation, and pending dark faces under sustained
  cache pressure. Reverse dependency tracking and additional bounces are deferred.
- `zig build test-gi` supplies focused offscreen acceptance checks; the full
  `test-render` suite also runs them. README documents controls and diagnostics.
