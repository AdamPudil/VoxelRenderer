# Diamond-square terrain rings following the rendering hierarchy

Status: runtime milestone implemented, 2026-11-07. Measurements and remaining
tuning limits are recorded in section 9. This is the focused runtime terrain
milestone following [Hierarchical Rendering and Lighting](hierarchical_rendering_lighting.md).
The next upload milestone is planned in
[Incremental GPU Terrain Streaming](incremental_gpu_terrain_streaming.md): retain
unchanged GPU payloads and transfer replacements while keeping atomic publication.
It uses the existing diamond-square implementation and shared rendering levels.
The broader field graph, biomes, persistence, and export remain in
[Configurable World Generator](configurable_world_generator.md).

## 1. Intended result

Generate deterministic terrain around the player, with fine voxels nearby and
progressively coarser cells farther away. Moving the player requests missing
detail in newly entered rings, reuses existing samples, and eventually releases
cold generated data. Distant terrain must render before its finest voxels exist.

The first version generates an opaque heightfield with one terrain material.
Seed, base elevation, displacement profile, ring radii, and resource budgets are
configurable in Zig. Keep the existing test scene selectable for regression
checks. Caves, water, structures, biome graphs, and smooth mesh terrain are outside
this milestone.

```text
player position + rendering settings
    -> shared stable focus and aligned cell demands
    -> cached diamond-square samples at requested spacing
    -> terrain hierarchy with exact leaves or coarse proxies
    -> versioned GPU snapshot
    -> existing hierarchical ray traversal and independent lighting rings
```

## 2. Existing code and gaps

| Area | Reuse | Required change |
| --- | --- | --- |
| Hierarchy policy | `src/rendering.zig`: sizes, rings, alignment, nearest X/Z bounds | Share the resolved focus and transition demand between CPU generation and GPU rendering |
| Focus hysteresis | `src/graphics/renderPolicy.zig`: anchor dead band | Move anchor ownership into a shared CPU policy state; upload its snapshot |
| Noise | `src/world/generation/noises/diamondSquare.zig`: `DiamondSquare(...).Sparse` | Add bounded rectangular work and cache accounting; preserve existing numerical rules |
| Generation regions | `src/world/generation/superchunk.zig`: 4096-voxel horizontal regions | Manage multiple regions around the moving player |
| Streaming | `src/world/world.zig`: worker, queues, staged GPU publication | Replace missing-chunk-only demand with requested-versus-resident terrain detail |
| Render summaries | `src/world/renderHierarchy.zig` | Add explicit procedural proxy semantics and child availability |
| GPU traversal | `hierarchy.glsl`, `frag_traverse.glsl` | Traverse coarse terrain terminals without requiring nonexistent children |
| Preview/tests | `src/generationPreview.zig`, `src/generationTests.zig`, `src/hierarchyRenderChecks.zig` | Exercise all five levels, moving focus, and runtime terrain |

The current runtime generator creates a uniform floor/wall test scene. Sparse
diamond-square is currently used by the preview. The renderer's existing mixed
node shortcut requires full opaque occupancy: it changes material detail while
preserving geometry. It cannot represent a partially occupied terrain region
whose fine children have never been generated. That representation is a required
part of this plan, not an existing capability.

## 3. One hierarchy and one ring policy

Use `rendering.cell_sizes` as the public runtime level table:

| Cell/sample spacing in voxels | Runtime scale | X/Z samples per chunk, excluding support |
| --- | --- | --- |
| 1 | Voxel | 256 × 256 |
| 4 | Group of voxels | 64 × 64 |
| 16 | Block | 16 × 16 |
| 64 | Group of blocks | 4 × 4 |
| 256 | Chunk | 1 × 1 |

Refine `256 -> 64 -> 16 -> 4 -> 1`. Each step creates 16 horizontal children;
the corresponding volume hierarchy has 64 children. Noise spacings 4096 and 1024,
and internal ×2 passes, remain generation dependencies rather than render LODs.

Use player-centered circular distance in X/Z, measured to the nearest point on
each aligned node's bounds. A node touching a finer ring must refine. Recurse
inside chunks so one near corner does not force an entire chunk to voxel detail.
Do not reuse the preview's parent-center circle membership as runtime policy.
Use floor division for negative coordinates and half-open ownership of cells.

Start with this **terrain-specific experimental preset**, in voxel units:

| Outer radius | Cell side |
| --- | --- |
| 384 | 1 |
| 768 | 4 |
| 1280 | 16 |
| 1792 | 64 |
| Current streamed boundary | 256 |

Encode the last ring with a finite radius covering the current region, consistent
with `requestedSize()` extending the last level to that region's edge. The ring
policy never expands streaming by itself. The initial 16×16×16 chunk window is
now expanded to 32×16×32 (X/Y/Z), doubling horizontal reach to approximately
4096 voxels; distant rings are clipped to it. These defaults differ deliberately
from the current scene preset, whose geometry rings stop at size 64.

Resolve the stable focus once per update and give the same immutable snapshot to
the scheduler and uniform upload. Include geometry radii, interaction radius,
hysteresis guard, transition width, and policy revision. Demand must also retain
the finer level used through a transition band; `requestedSize()` alone does not
describe the shader's blend requirements. Add matching CPU/GPU boundary tests.

Lighting rings remain independent. Coarser lighting never reduces required
geometry or interaction detail. An exact-data consumer can request finer terrain
through the same scheduler; a finer lighting sample alone does not require a
second terrain surface definition.

## 4. Deterministic height sampling

Use the existing sparse evaluator, initially with a dense base at spacing 256
per resident generation superchunk. Reuse its global hashing, signed coordinates,
parent dependencies, pass order, integer rounding, and compile-time amplitude
profile. Do not implement a second diamond-square algorithm.

- Define canonical height `H(x,z) = base_height + diamond_square(seed,x,z)` in
  integer voxel units. Validate elevation arithmetic and supported coordinates.
  Terrain occupies voxel columns below H; H is the exclusive upper surface.
- A preset selects a compiled displacement profile initially. Runtime-editable
  amplitude arrays would require an explicit later change to the existing API.
- Route global requests to superchunks with floor division by 4096. Include seed
  and generator/profile version in cache identity, never player position.
- Keep inherited values unchanged. Sampling the same coordinate at any supported
  spacing returns the same height; refinement introduces additional coordinates.
- Add resumable aligned area sampling over `Sparse.sampleAt()`. Bound each work
  slice by new samples/dependencies and elapsed time, retaining its cursor. A
  single recursive sample evaluation is the initial smallest indivisible unit;
  measure its worst case and split dependency evaluation if that is too costly.
- Do not call dense `resultChunk()`/`resultArea()` on the runtime path: they refine
  the entire superchunk. Support samples outside requested rings are legitimate
  dependencies and must be counted separately from requested output samples.
- Share a heightfield across vertical chunks. Do not rerun noise independently for
  every chunk Y. Preserve deterministic shared edges without loading neighbors.

## 5. Terrain representation and rendering contract

Keep the procedural base, player edits, and render payload distinct. Add a
terrain node payload with aligned origin, level, generator revision, child mask
or references, material, and explicit exact/proxy state. Store it alongside
existing chunk/block asset storage and reference it through a versioned GPU
descriptor. Exact edited blocks override the procedural base.

For the first coarse representation, use solid, axis-aligned columns. For an
X/Z leaf of side `s`, sample its lower corner and use the render surface
`Hs = floorDiv(H(x,z), s) * s`. Fill the column below Hs, clipped to the vertical
streaming region. This defines deterministic coarse cubes at all five levels;
at size 1 it reproduces the canonical heightfield. Height quantization changes
only the render proxy, never cached noise values.

Build uniform vertical spans directly and split only where surface, material,
child-detail, or edits require it. Avoid allocating a full 256³ voxel array for
each chunk. At coarse levels, even an empty or solid column is an approximation
to the canonical terrain: a single height sample does not prove the absence of
unseen peaks or valleys.

Keep these meanings separate:

- **Exact:** canonical finest terrain or an analytically proven uniform region.
- **Proxy:** a terminal coarse representation with known occupancy in the
  published approximation, but unknown canonical fine occupancy.
- **Branch:** children are available and define the published region.
- **Pending:** no replacement is ready; retain the published parent, or report
  unavailable if the region has never had a representation.

Never put estimated canonical occupancy into the current exact `Summary` fields.
Either use a separate terrain descriptor or add an explicit tagged path whose
counts refer only to its published proxy. Missing children must not become air.
Update CPU packing and GLSL readers together, including material queries and
secondary rays, while retaining the existing path for authored assets.

### Visibility and interaction

For this first terrain mode, primary and shadow rays traverse the **same published
terrain geometry**, including far proxies. Shadows are therefore exact relative
to that representation, but approximate relative to ungenerated finest terrain.
This is an explicit extension of the earlier rendering plan's exact-visibility
contract: exact shadows from arbitrary ungenerated detail cannot be promised.
Authored geometry and edited blocks retain their exact traversal. GI/reflections,
when enabled, must recognize the same terrain descriptors.

Collision, picking, and editing require canonical size-1 data inside the
interaction radius. Prefetch a movement margin around it and prioritize that
work. If teleportation or rapid movement outruns generation, return an explicit
unavailable result and defer the interaction; do not treat missing terrain as air
or commit an edit against a proxy. Spawn the player only once the spawn patch is
ready, using the generated surface for initial height.

### Boundaries and publication

Neighboring leaves own disjoint half-open volumes, with explicit ray boundary
tie handling. The union of solid columns defines vertical faces where heights
differ, including coarse/fine joins. Those visible steps are expected voxel
geometry; missed cells, duplicate hits, and holes between columns are defects.
Balance adjacent horizontal leaves to at most one ×4 level difference, including
across chunk and superchunk boundaries. Account for this extra refinement in demand.

Replace a parent only when its complete required child coverage and boundary
dependencies are ready. Publish the replacement atomically using the existing
staged GPU snapshot, retaining the old buffers until publication. The existing
material blend cannot smooth a change in occupied volume. First ship atomic
geometry replacement plus hysteresis; measure popping before adding any geometry
crossfade. Do not imply that stable height anchors alone eliminate LOD popping.

## 6. Streaming, ownership, and budgets

Replace chunk-only `ready_set` semantics with desired, generated, and published
detail per terrain subtree. A loaded coarse region must remain eligible for
refinement. Track seed/configuration revision, terrain/edit revision, and a
request token on jobs and completed payloads. Before commit, reject obsolete
configuration, edits, or replacements; focus movement may retain useful cached
samples but cannot publish an obsolete coverage decision.

Use the existing single worker initially, with worker-owned mutable noise caches.
The main thread sends immutable policy/demand snapshots and receives owned
completed payloads. Keep generation outside the stream mutex. Deduplicate queued
and running work by region, target detail, and relevant version.

Prioritize interaction readiness, then missing coarse coverage, then nearby
refinement. Generate parents before dependent children and avoid far-region
starvation. On movement, diff demand against resident validity and enqueue only
missing work. Retain extra fine data through hysteresis until memory pressure
requires eviction. A stationary unchanged world should generate no new samples
and initiate no new terrain uploads.

Add separate limits for sample-cache bytes, terrain payload bytes, queued work,
completed payload bytes, generation work per slice, main-thread commit work,
and upload bytes per frame. The current completed-chunks-per-frame limit does
not bound the cost of generating a detailed terrain chunk. Count staging copies
and dependency halos in memory accounting.

The sparse evaluator currently owns a growing map. Begin with whole-superchunk
cache eviction outside retained coverage; if a resident cache exceeds its share,
reconstruct it from the coarse base and current demand under budget, or add safe
fine-entry eviction. Never require unbounded growth during a long walk. Pin work
inputs and published payloads until readers finish. Keep unsaved edits resident;
if their budget is exhausted, apply backpressure rather than discard them. Disk
persistence is a separate milestone.

Route `setBlock()`'s missing-chunk fallback through the selected world generator;
it must no longer silently create the old floor/wall scene in terrain mode.
Reapply edits over generated replacements and invalidate affected ancestors and
lighting revisions. Preserve the existing snapshot uploader initially; localized
CPU repacking and incremental residency uploads can follow measured need.

## 7. Implementation sequence

1. [x] **Shared demand policy.** Extract focus resolution from uniform upload;
   implement conservative recursive demands, transition retention, balancing,
   and terrain preset validation in `rendering.zig` or a small shared helper.
2. [x] **Terrain sampler.** Add `src/world/generation/terrainGenerator.zig` with
   preset identity, superchunk cache ownership, bounded sparse area jobs, height
   convention, and sample/allocation counters. Prove parity with existing noise.
3. [x] **Terrain payload.** Add `src/world/terrainHierarchy.zig` for exact/proxy
   terminals, branch construction, vertical runs, and edit overlays. Build each
   LOD directly, without first creating its finest descendants.
4. [x] **GPU support.** Extend packing, descriptors, `hierarchy.glsl`, and shared
   traversal to render terrain proxies at every level. Validate a static mixed
   LOD scene before enabling moving rings. Cover shadows and interaction queries.
5. [x] **Runtime scheduler.** Add `src/world/generation/terrainStreaming.zig` or
   equivalent helpers; integrate versioned demands/results with `world.zig`,
   movement updates, commit budgets, cache limits, and atomic publication.
6. [x] **Playable integration.** Add terrain/test-scene selection in `main.zig`,
   spawn readiness, interaction prefetch, and terrain-aware edit fallback. Wire
   the shared policy snapshot to generation and rendering each update.
7. [x] **Preview and tuning.** Extend the LOD preview to all five bands using
   the runtime demand builder, include movement across region boundaries, and
   report requested/generated/published levels and resource use. Tune defaults
   from runtime camera paths after correctness passes.

## 8. Verification and completion criteria

Extend existing suites rather than introduce a second test harness:

```sh
zig build test-generation
zig build test
zig build test-hierarchy
zig build test-render
zig build
```

Use `zig build test-generation-full` when numerical rules or dependency handling
change; the full dense suite is not needed for every scheduler-only iteration.

- Every spacing 1/4/16/64/256 generates and renders independently. Far requests
  allocate no fine voxel payloads and produce only requested noise/support work.
- Direct and progressive requests produce identical samples and size-1 terrain,
  including reordered jobs, negative coordinates, shared superchunk boundaries,
  eviction/revisit, and inherited anchors. Zero-amplitude terrain is a flat control.
- CPU demand and GPU policy agree at exact thresholds, bounds crossings, focus
  hysteresis, transition bands, interaction overrides, and loaded-world edges.
- A reduced bounded all-size-1 world matches a dense reference for heights,
  occupancy, materials, hit positions, and shadows. Mixed-detail terrain matches
  a reference assembled from its specified published column proxies.
- Rays crossing coarse/fine faces, edges, and corners in both directions have
  consistent ownership, including axis-aligned and grazing rays. Test a steep
  surface and negative elevations; preserve authored thin walls/glass/emitters.
- Walking, reversals, threshold oscillation, and teleports trigger bounded work.
  Delayed/out-of-order results and edits during generation/upload cannot replace
  newer data. Old geometry remains visible until its replacement is complete.
- Near-player queries use exact terrain or explicitly report pending data. Edits
  survive promotion, demotion, cache eviction, and return visits during the session.
- A long traversal remains within configured generated-data budgets. Returning
  to retained coverage reuses samples; returning to evicted coverage reconstructs
  the same terrain. Allocation failures retain the last valid representation.
- Record frame time, worker time, new samples by level, cache hits, queue latency,
  payload/upload bytes, CPU/GPU/staging memory, and transition artifacts. Compare
  mixed LOD with uniform finest detail over identical bounded coverage and camera
  paths. Fewer samples are not, by themselves, evidence of faster rendering.


## 9. Implementation record

Implemented in `rendering.zig`, `terrainGenerator.zig`, `terrainHierarchy.zig`,
`terrainStreaming.zig`, `world.zig`, the shared traversal shaders, and `main.zig`.
The existing asset storage and rendering paths remain selectable with
`--world=test-scene`; terrain is the default. `--terrain-stats` reports sample
levels, worker/queue timings, payloads, uploads, CPU capacity and both GPU buffers.

### Representation and ownership decisions

- Horizontal render distance is doubled through the shared streamed-window size:
  32×16×32 chunks, or 8192×8192 voxels horizontally. Scheduler tile arrays, lookup
  strides, staged GPU packing, preview coverage and counters derive from that
  size. Near-detail ring radii and generation/upload budgets stay unchanged;
  additional coverage consists of coarse chunk proxies. The primary/secondary
  traversal step cap increases from 512 to 1024 for the longer paths. GPU tests
  trace from the center to all four outer corners, including positive and
  negative terrain heights.
- The application temporarily uses the existing face-orientation lighting
  (`lighting.mode = .legacy`) for terrain inspection: fixed directional shading
  plus ambient fill, with point/sky visibility and GI disabled. Restore `.direct`
  to resume the lighting-ring configuration described below.
- Runtime displacement profile v2 leaves the final three refinements
  (spacing 8 -> 4 -> 2 -> 1) interpolation-only: both diamond/square amplitudes
  are zero at each level. Coarser heights stay unchanged; fine samples use the
  existing integer neighbor averages without added random displacement. The
  runtime LOD preview uses this same profile.
- A horizontal chunk owns a four-way-per-axis column tree shared by all sixteen
  vertical chunks. Four GPU words per node encode children, exclusive surface,
  and bounds on the **published** subtree's heights. Bounds allow direct uniform
  vertical skips without allocating voxels. Leaf size is derived from descent;
  size one is canonical, every coarser leaf is a proxy, including empty columns.
- Chunk header state 3 selects the terrain descriptor. An optional exact block
  overlay distinguishes an absent override from explicitly edited air. Canonical
  occupancy summaries never receive estimated terrain counts. Lighting has an
  explicit published-geometry query, independent of canonical summaries.
- Initial chunk proxies publish before full refinement. Subsequent replacements
  cover the whole horizontal window atomically. This deliberately uses a broader
  publication unit than an individual subtree so cross-chunk balance cannot be
  broken by partial promotion/demotion. Immutable tiles are reference counted and
  reused whenever their demand topology remains valid. Old geometry stays visible
  during generation, CPU assembly and upload; stale request/edit tokens cannot
  publish. Very fast movement can postpone replacement until generation catches up.
- In-flight terrain uploads check request/edit validity before each frame's
  transfer, including frames with zero upload budget. Obsolete snapshots stop
  immediately instead of consuming the remaining transfer budget before being
  discarded. The last published geometry remains visible until the current
  replacement is ready; pending edits are included in that replacement.
- `FocusState.resolveWithRequests()` supports up to four additional exact-data
  consumers through the same scheduler. The interaction ring adds a 64-voxel
  movement margin. A size-dependent conservative halo enforces adjacent ×4 balance,
  including custom policies that skip intermediate levels.
- Main-thread voxel queries expose `unavailable`, `air`, or `solid`;
  `raycastChecked()` reports `TerrainUnavailable`. The compatibility picking API
  defers on that error. Edits require complete exact block coverage and remain
  independently owned when the underlying tile or sample cache is evicted.

### Budgets and their scope

| Resource | Default bound |
| --- | --- |
| Noise caches, including hash capacity, dependency samples and rehash copies | 96 MiB, at most 8 superchunks |
| One completed/in-progress/resident coverage payload | 24 MiB each |
| Worker tile reuse cache | 24 MiB; shared tiles are counted conservatively |
| All shared node storage/capacity and transient payload allocation copies | 96 MiB hard allocation cap across owners |
| Requests/completions | One latest immutable request and one completed batch |
| Worker slice | 2048 outputs/dependencies or 2 ms, checked between recursive samples |
| Main-thread commits | At most one replacement batch per update |
| CPU snapshot assembly | 2 ms or 1,048,576 words, checked between small node batches/edited blocks |
| GPU transfer | 8 MiB per frame |
| Unsaved edits | 32 MiB conservative reservation, backpressure on exhaustion |

The payload limits are **per owner**, not a claim that total terrain memory is
24 MiB. Resident, completed, in-progress and reusable coverage can coexist; CPU
staging and both GPU snapshots coexist too. Shared tile storage avoids duplicate
allocations, and telemetry counts staging capacity and GPU allocations separately.
Whole-superchunk LRU eviction safely reconstructs samples under the cache cap.
A stationary unchanged world queues no work and performs no terrain upload.

One recursive sample, allocation, edited block pack or OpenGL call remains an
indivisible unit: time limits are soft at those boundaries, byte limits are hard.
The preview observed a worst sample around 4.8 ms (including allocation/rehash).
The existing whole-snapshot GPU transfer remains; driver allocation/upload cost
can exceed the CPU assembly slice. Incremental GPU residency remains a measured
follow-up rather than part of this representation change.

### Measurements (software Mesa/EGL; illustrative, not hardware targets)

ReleaseSafe, original 4096×4096 horizontal coverage (before the distance increase):

| Path step | Worker | End-to-end publication | Reused tiles | Noise cache | Payload |
| --- | ---: | ---: | ---: | ---: | ---: |
| Initial focus | 243 ms | 257 ms | 0/256 | 13.6 MB | 12.7 MB |
| Move +20 X | 77 ms | 86 ms | 188/256 | 13.6 MB | 12.7 MB |
| Reverse to -20 X | 76 ms | 86 ms | 162/256 | 13.6 MB | 12.7 MB |
| Teleport across superchunk boundary | 251 ms | 261 ms | 0/256 | 27.3 MB | 12.7 MB |

After splitting CPU assembly, its measured worst slice was 0.44–0.53 ms in that
run. Whole update peaks (including driver uploads) were 1.56–6.07 ms. Debug builds
are substantially slower; before incremental assembly the main-thread repack
alone produced 30–50 ms spikes. These are CPU/update measurements, not full
interactive frame-rate claims.

A separate bounded 256×256 comparison uses the same seed, area, two camera views,
96×96 image size and warmed software GPU:

| Detail | Height requests | Generation | Packed snapshot | GPU time/view |
| --- | ---: | ---: | ---: | ---: |
| Mixed | 212 | 0.18 ms | 69,136 bytes | 1.11 ms |
| Uniform finest | 65,537 | 20.72 ms | 1,184,016 bytes | 1.78 ms |

The mixed approximation changes occupied volume; this comparison is not an
image-equivalence claim. Reference ray tests instead compare each mode to its
specified column union. Hardware GPU frame times, visual popping during a long
interactive walk and a geometry crossfade remain tuning work. Atomic replacement
and focus hysteresis do not eliminate popping.

The runtime preview reports all five leaf levels. Its original 16×16 window had
614,784/105,960/18,304/2,196/12 leaves at spacings 1/4/16/64/256. A 20-voxel move
across a region edge added about 18,916 cached noise entries; returning to retained
coverage added zero. These counts include conservative demand margins.

After expanding to 32×16×32, the ReleaseSafe moving-worker check published the
initial window in about 284 ms and the +20 X update in 91 ms, reusing 954/1024
tiles. Payload remained about 12.7 MB. The expanded preview covered 8192×8192
voxels and added zero noise dependencies when returning to retained coverage.
Build, CPU tests, generation tests, the runtime preview and software EGL hierarchy
checks passed, including rays to all four distant corners and bounded uploads.

### Verification coverage

Extended the existing generation, block/world and EGL hierarchy suites with:
all five direct levels, signed exclusive heights, sparse evaluator parity,
resumable rectangles, eviction/revisit, balance across chunk boundaries, exact
consumer versioning, stationary reuse, actual worker startup/shutdown, stale
completion rejection, moving/teleporting focus, canonical interaction readiness,
edits surviving eviction, bounded uploads and edits during staging.
The staging checks also invalidate a partial upload through an edit with a small
byte budget and through focus movement with a zero byte budget, verify that no
obsolete bytes are sent, and check the subsequent replacement on the GPU.
The small-budget edit regression failed on the previous implementation with
`StaleTerrainUploadContinued`. After early cancellation was added,
`zig build test-generation`, `zig build test`, `zig build test-hierarchy`,
`zig build test-render`, and `zig build` passed (GPU checks on software Mesa/EGL).

GPU checks cover matching CPU/GPU transition weights, mixed primary and shadow
rays against an independent unit-voxel reference, positive/negative face/edge/
corner crossings, sky spans, and independent lighting. These exposed and fixed
unit-DDA corner ties and negative-direction ownership inside a skipped region.
Existing authored thin walls, glass, emitters, lighting-cache and GI tests remain
in the regression suites. The numerical diamond-square algorithm was unchanged;
its full dense stress suite is not required for these scheduler/representation
changes.
