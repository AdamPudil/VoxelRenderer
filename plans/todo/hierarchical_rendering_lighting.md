# Hierarchical Rendering and Lighting Rings

## Runtime implementation (2026-11-07)

The direct-lighting runtime phase is implemented in `src/rendering.zig`,
`src/world/renderHierarchy.zig`, and `src/graphics/shaders/include/hierarchy.glsl`.

- Validated independent geometry/lighting rings, shared level constants, nearest X/Z bounds, a stable focus dead band, configurable transition width, and a finest-detail interaction radius.
- Derived CPU/GPU nodes at 256/64/16/4/1. Existing chunk/block headers reference packed root/child summaries in the index buffer; assets and authoritative edits retain their existing representation. Exact empty/uniform/mixed state, occupied count, opacity flags and emission flags are independent of the representative material. Repacking an edit refreshes ancestors before drawing.
- Exact empty/uniform skips for view, shadow, picking and GI traversal. Geometry rings can stop at fully occupied opaque mixed nodes, with material blending at transitions. Partially occupied nodes, mixed transmitting materials and mixed emitters refine. This conservative first representation preserves silhouettes and thin walls; it does not fill arbitrary sparse cells with coarse cubes.
- Direct irradiance keys contain aligned origin, level and oriented face, with geometry/light revision invalidation. Only complete connected opaque patches with empty adjacent cells share lighting. The sample is on the occupied face; the hit's own material is applied afterward. Coarse/fine estimates blend within the transition band; shadow visibility remains exact.
- Generation delivery and its pending queue are bounded, prioritize X/Z proximity, and stay within the existing streamed region. The current runtime scene generator already produces proven uniform chunks directly; it never constructs their finest voxels. The separate procedural terrain preview is not substituted for the runtime scene.
- Byte-budgeted uploads stage a complete snapshot in a second set of GPU buffers. Geometry, region bounds and block lights publish together; the prior snapshot stays visible and edits arriving during upload remain queued.
- Direct cache population has a per-draw entry budget. Budget exhaustion preserves exact evaluation as a fallback, so this bounds cache writes rather than total shadow rays.

Validation: `zig build test-hierarchy` runs offscreen packing/traversal/ring checks,
compares hit maps with the original traversal, checks staged upload publication
and edits during upload, checks thin geometry/glass/emission and coarse-level
transition continuity, verifies independent rings and cache levels, and reports a fixed-view
lighting benchmark. `zig build test` covers policy validation, packing ancestors
and bounded generation delivery. `zig build test-render` retains the broader
lighting, optics and optional GI regression suite. The application build, all
117 CPU tests, the hierarchy checks, and both rendering shader profiles passed.

Still pending from the broader design: mixed-occupancy procedural terrain
approximations and terrain-to-runtime refinement requests; memory-budget eviction
of derived fine data; localized lighting dependency invalidation and a queue budgeting actual direct-light evaluations;
coarse optional GI keys/sampling; and hardware camera-path/default-quality tuning.
GPU uploads are incremental; CPU packing still rebuilds a complete region
snapshot. Optional GI retains finest surface keys and gains exact hierarchy skips only. The illustrative ring defaults are experimental, not quality guarantees.

The controlled 128×128 plane benchmark on software Mesa populated 16,384 fine
entries versus one level-256 entry; warm draws were approximately 0.35 ms versus
0.26 ms. Mean RGB difference was 8.07/255 in this point-light scene. These numbers
show reduced sampling/storage demand, not a general hardware FPS guarantee.
Atomic publication keeps two geometry buffer sets, increasing GPU geometry
memory; the direct-light cache allocation is unchanged.

The focused next terrain milestone is specified in
[Diamond-square terrain rings](procedural_terrain_rings.md), including shared
generation/rendering demand, direct coarse payloads, and moving-player refinement.

Configuration lives in `src/rendering.zig`. Set both policies to a single ring
`.{ .outer_radius_voxels = 8192, .cell_size_voxels = 1 }` for finest shading/materials.
`Settings.exact_hierarchy = false` also selects the original traversal for A/B
checks; keep both policies finest when comparing full reference images.

## Goal and scope

Reduce generation, traversal, and lighting work with fine detail near the player and configurable coarse detail farther away. Geometry resolution means world-space cell size, not framebuffer resolution. Interpret “4×4” as 4×4 in X/Z terrain fields and 4×4×4 in runtime voxel volumes.

Current runtime traversal supports chunk → block → voxel; direct lighting uses a flat per-voxel-face cache. Extend the ×4 levels already specified in [generation core](hierarchical_generation_core.md) and [terrain generation](hierarchical_terrain_generation.md). Direct lighting ships first; apply the same policy to optional GI afterward.

## Shared hierarchy

| Cell side, finest voxels | Representation |
| --- | --- |
| 256 | Chunk |
| 64 | 4×4×4 blocks — new intermediate level |
| 16 | Block |
| 4 | 4×4×4 voxels — new intermediate level |
| 1 | Finest voxel |

Each refinement produces 64 children in 3D or 16 in 2D. Keep cells globally aligned, including negative coordinates. Store exact empty/uniform/mixed classification separately from approximate render summaries; a mixed cell must never become “empty” merely because its representative sample misses geometry. Summaries retain occupancy, representative material, opacity class, and emission; mixed glass/opaque cells require refinement initially.

## Independent ring settings

Expose separate `geometry_rings` and `lighting_rings`, each containing `{ outer_radius_voxels, cell_size_voxels }`. Accept sizes `1, 4, 16, 64, 256`; require increasing radii and nondecreasing sizes. Radii below are illustrative tuning defaults, not quality guarantees.

| Outer radius (voxels) | Geometry cell side | Lighting cell side |
| --- | --- | --- |
| 128 | 1 | 1 |
| 384 | 1 | 4 |
| 768 | 4 | 16 |
| 1536 | 16 | 64 |
| Loaded-world limit | 64 | 256 |

Use player-centered X/Z distance for the initial rings, consistently across generation and rendering. Classify cells by nearest distance to their bounds; cells crossing a threshold receive finer detail. Add configurable hysteresis, transition width, and per-frame generation/upload/lighting budgets. Settings do not extend the existing streamed-world bounds automatically.

## Implementation sequence

1. **Policy and storage:** centralize level constants and ring validation; extend CPU storage and GPU packing with intermediate-node summaries and child references. Preserve existing block assets and authoritative edits; coarse representations are derived data. Update affected ancestors on edits.
2. **Generation:** request only missing levels required by geometry, lighting visibility, and interaction. Reuse deterministic coarse parents and inherited field samples; refine nearer regions first. Retain useful fine data under a memory budget. Do not generate every finest voxel before producing distant terrain; distinguish procedurally approximated cells from proven uniform cells.
3. **Traversal:** extend `sampleMaterial` and shared ray traversal to descend `256 → 64 → 16 → 4 → 1`. Empty/uniform regions permit exact large steps; mixed regions stop at the requested render level and intersect the coarse representation. Never implement LOD by blindly increasing ray increments. Bound steps at node and ring transitions. Picking/collision retain finest-detail queries within interaction range.
4. **Lighting:** replace face-only cache identity with `{ aligned cell origin, level, face/surface identity, revisions }`. Share coarse irradiance across compatible surfaces; multiply by each hit's material separately. Sample actual occupied surfaces, not empty coarse-cell centers. Keep opposing/disconnected surfaces separate and refine ambiguous cells to avoid illumination crossing walls.
5. **Visibility and transitions:** lighting rings control shading sample density independently of geometry. Shadow rays use exact hierarchy skips and descend mixed occluders initially; coarse lighting must not imply coarse shadow visibility. Retain required occluder data even outside fine geometry rings. Blend compatible parent/child lighting estimates; publish completed geometry replacements atomically with consistent boundary ownership and bounded transition dithering. Keep a valid parent visible while refinement is pending.
6. **Scheduling and GI:** invalidate affected lighting dependencies after geometry/light changes; include level in cache keys so ring changes cannot alias results. Budget coarse/fine cache population and prioritize visible near cells. Extend GI queue keys, surface sampling, dependencies, and accumulated results to the same levels after direct lighting passes validation.

## Validation and acceptance

- All rings at size 1 match the current reference rendering; exact hierarchy skipping preserves hit and shadow results.
- Test every level boundary, negative coordinates, ring crossings, edits, thin walls, small emitters, glass, and coarse/fine terrain joins. No holes, stale cache reuse, or new light leaks; assess popping during movement.
- Benchmark identical camera paths against the reference: frame/GPU time, traversal steps, shadow rays, cache hit rate, generated samples, uploads, and peak memory.
- Tune geometry and lighting rings independently using fixed-view comparisons. Accept defaults only when measured load decreases with acceptable visual differences; retain finer overrides for silhouettes and thin structures. Coarser shading reduces evaluations, but exact shadow traversal and protected detail remain costs.
