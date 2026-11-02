# Configurable world generator and distance LOD

Status: proposed implementation plan. Scope: terrain height, terrain materials,
biome fields, selective generation, actual world rendering, incremental CPU–GPU
streaming, chunk persistence, and world export. Plants, caves,
erosion simulation, and LOD larger than one chunk are future extensions.

## 1. Existing foundations and relationship to other plans

Build on [Hierarchical Generation Core](hierarchical_generation_core.md) and
[Hierarchical Terrain Generation](hierarchical_terrain_generation.md). This plan
defines the configurable composition layer and the first runtime LOD integration.
Their 4096/1024-voxel levels remain useful generation ancestors; the initial
renderer exposes only 256/64/16/4/1-voxel cells.

Current reusable code:

- `src/world/generation/noises/diamondSquare.zig`: deterministic, resumable
  refinement, including a sparse evaluator.
- `src/world/generation/superchunk.zig`: regions, sample results, and the existing
  circular preview policy, currently using 256/16/1 spacing.
- `src/world/position.zig`: global positions and seeded hashing.
- `src/world/world.zig`: streaming, generation jobs, GPU upload, and editing.
- `src/graphics/shaders/include/frag_traverse.glsl`: ray traversal with chunk,
  block, and voxel lookup. Existing uniform-region skipping is useful but is
  not a complete distance-based approximation system.

The runtime storage hierarchy remains 16 voxels per block side and 16 blocks per
chunk side. A generation superchunk remains a 16×16-chunk horizontal region.
“One chunk maximum LOD” limits cell size, not world extent or generation roots.

## 2. A graph of named fields

Represent a world preset as a validated directed acyclic graph:

```text
seed + global coordinates
    → independent noise fields
    → remap / combine / masks
    → biome weights
    → terrain profile + hierarchical height refinement
    → surface materials / optional water mask
    → terrain cells at requested LOD
    → GPU traversal
```

Noise produces data; its name does not impose engine behavior. The default preset
provides `roughness`, `humidity`, and `temperature`, but users can remove every
one of these and build a preset using entirely different fields. Only selected
output ports, such as final terrain height and material, are required.

Each field definition contains:

- Stable ID, enabled flag, output type and range/units.
- Named input dependencies and explicit resampling rules.
- Algorithm and parameters, seed namespace, and configuration version.
- Root spacing, finest required spacing, and per-transition refinement strategy.
- Boundary halo requirements and cache policy.

Support scalar fields, masks, biome-weight sets, height in voxel units, and
material IDs. Start with Zig configuration structs and a registered custom-stage
interface; a file format or visual graph editor can be added later. Built-ins
include constants, noise, curves, clamp, arithmetic, min/max, blend, and masks.
Custom callbacks declare the same dependencies and determinism contract.

Compile the preset once: validate types, cycles, unique IDs, ranges, missing
outputs, and supported algorithm transitions, then schedule only reachable nodes.
Disabling a referenced layer requires an explicit replacement or fallback;
report the dependency path rather than silently using zero. Unused disabled
layers cost no generation work. Seed namespaces use stable IDs, never array order.

## 3. Biome rules and terrain profiles

Default field conventions are roughness 0=flat to 1=mountainous, humidity 0=dry
to 1=wet, and temperature 0=cold to 1=hot. These conventions belong to the preset.
Roughness controls relief, while biome profiles independently control base
elevation: a flat plateau and a rugged lowland must both be possible.

### 3.1. Select a palette, then locate a polygon

Use a two-stage mapping as the primary authoring model:

```text
roughness (+ optional selector fields) → biome palette
(temperature, humidity)              → point in that palette
containing polygon                  → biome ID
```

A palette is a unit square `[0,1] × [0,1]`, partitioned into labeled regions.
The default X axis is temperature and Y axis is humidity; both bindings are
user-definable. Each region contains a biome ID and polygon vertices, primarily
triangles and quads. Multiple disconnected regions can reference the same biome.
This permits diagonal and irregular boundaries that independent per-axis ranges
cannot express conveniently.

Normalize each input using its declared range or a configured remap curve:
`u = clamp((value - minimum) / (maximum - minimum), 0, 1)`.
Here 1 means the configured upper end of the field's range. Never normalize by
observed tile minimum/maximum: that would change classification across tiles and
LOD. Reject zero-width ranges and non-finite inputs with a diagnostic.

Example selector bands (illustrative, configurable):

| Roughness | Palette |
| --- | --- |
| [0, 0.3) | Flat terrain |
| [0.3, 0.65) | Hills |
| [0.65, 1] | Mountains |

The same temperature/humidity point can mean grassland in the flat palette,
wooded hills in the hills palette, and alpine terrain in the mountain palette.
Within the mountain palette, cold/wet regions can select ice mountains while
cold/moderately humid regions select snow mountains. Polygon coordinates, biome
names, and these relationships are entirely preset-defined.

### 3.2. Polygon authoring and exact classification

Start with data-defined vertex lists and a palette preview export. A future 2D
editor can drag vertices, assign biome labels, and highlight the selected point.
Prefer shared vertices/edges between adjacent regions so boundaries can be moved
without introducing gaps. Triangles and convex quads are sufficient initially;
reject self-intersecting, degenerate, or unsupported concave polygons clearly.

Compile and validate each palette before generation:

- Vertices lie in the unit square and polygons have consistent winding.
- Polygon interiors do not overlap; shared edges and vertices are permitted.
- The square is fully covered, or uncovered regions explicitly use a configured
  fallback biome. Preview any fallback regions so accidental gaps are visible.
- Shared-boundary points have one deterministic owner, selected by stable region
  ID. Include all outer edges, including coordinates exactly equal to 0 or 1.
- Use a single robust containment/boundary convention and fixed authoring
  precision. Do not let different floating-point epsilon choices create holes.

Return one exact biome ID per input tuple. Optional acceleration bins index
candidate polygons; retain exact polygon containment as the final test so a
raster lookup does not silently change diagonal boundaries.

### 3.3. More than three input fields without higher-dimensional editing

Keep two fields visible as palette axes and represent the others as selectors.
Three total fields require one selector slider and a 2D palette. Four total
fields can use a 2D table of selector bands, with each table cell referencing a
palette. Alternatively use a small decision tree:

```text
continentalness → ocean / coast / inland
inland roughness → flat / hills / mountains
selected palette: temperature × humidity → biome
```

Each branch may select a palette or another selector. Palette assets can be
reused by many branches; do not copy identical polygon layouts. Support explicit
AND conditions over selector bands, deterministic rule priority, and a required
fallback branch. Reject cycles and flag unreachable rules.

This is an understandable slice-based representation of a higher-dimensional
mapping, not a lossless simplification of every possible 4D region. Many tightly
coupled inputs can still require many slices. For those cases, allow derived
fields that combine inputs before selection, or a custom classifier implementing
the same output contract. Do not require an N-dimensional polygon editor.

A useful future authoring view shows the current 2D palette with sliders for all
selector inputs, plus neighboring palettes as thumbnails. Changing a slider
reveals which palette activates and where transitions occur.

### 3.4. Optional terrain blending, separate from biome identity

Hard polygon lookup defines biome identity. Keep it available even when terrain
uses blended biome weights to avoid cliffs at boundaries. Blend widths are
explicit configuration, defaulting to zero for exact classification.

For a first deterministic implementation, approximate smoothing with a fixed,
normalized kernel of nearby points in palette coordinates, classify each point
with the exact polygon lookup, and accumulate weights by biome ID. Clamp samples
to the square boundary and normalize the resulting weights. This handles polygon
edges and multi-biome junctions without assuming matching polygon topology.
The kernel is fixed by the preset, independent of camera LOD. Its width is in
normalized field units, not world meters; a separate spatial filter would be
needed to guarantee a fixed-width transition on terrain.

At selector thresholds, optionally crossfade the two neighboring palettes over
an explicit selector-space band. Evaluate both at the same axis coordinates,
then blend their biome-weight vectors, merging matching biome IDs. For multiple
selectors, combine branch weights and bound the number of active branches.
Never interpolate polygon vertex lists or numeric biome IDs. Exact classification
continues to use the hard selector bands and polygon ownership rules; blended
weights are a separate terrain output. Hierarchical height anchoring still applies.

Each biome references a terrain profile containing base elevation, relief,
per-level detail amplitudes, ridge controls, and material rules. Blend continuous
profile parameters or candidate heights, then quantize material decisions
deterministically. Algorithm choices are discrete: run compatible candidate
branches and blend their outputs instead of interpolating algorithm IDs.

Humidity may influence water-feature masks, but humidity alone does not define
river connectivity or water elevation. Initially support configurable sea level
and optional basin masks; defer connected river generation. Snow/ice are surface
rules using biome weights, elevation, and slope, with optional thickness.

Avoid a height/biome cycle: classify terrain biomes from source fields first,
generate height second, then derive altitude-adjusted temperature and surface
cover. Any later ecological classification is a separate output for plants.

## 4. Hierarchical algorithm contract

Every refinement stage receives global bounds, source/target spacing, parent
fields, seed, configuration, validity information, and reusable scratch storage.
It declares whether it is a root source, interpolator, anchored refinement, or
derived transform. Completed parent samples remain unchanged when refining the
same field. Transforms that change them create a new field/version.

Example configurable strategy chain:

| Transition | Example strategy |
| --- | --- |
| Generation roots → 256 | Diamond-Square macro field |
| 256 → 64 | Hierarchical value refinement |
| 64 → 16 | Anchored ridge residual |
| 16 → 4 | Biome-scaled local relief |
| 4 → 1 | Fine surface residual |

Different fields may use different chains and stop at different resolutions.
Temperature can stop at block spacing while height reaches voxel spacing.
Consumers must use declared interpolation; categorical material inputs require
categorical sampling. Diamond-Square keeps its internal ×2 operations and
per-operation displacement configuration inside public ×4 transitions.

Existing Perlin/Voronoi/domain-warp functions need adapters and seed/coordinate
audits. Sampling arbitrary noise at several spacings does not by itself satisfy
the parent-preservation contract. Use these functions as independent sources or
residual drivers constrained to zero at inherited positions. Reject incompatible
handoffs, especially attempts to resume Diamond-Square without its support state.

The final height needs this contract too: retain parent heights and introduce
biome-driven changes only at new samples. Recomputing a coarse height from newly
refined biome weights must not move existing anchors. Broad biome classification
uses a camera-independent sampling policy; camera movement changes detail demand,
not world identity. Slope/material sampling also declares a fixed physical scale.

Cache by world seed, graph version, field/stage ID, global tile coordinate, and
spacing. Include dependency versions. Use pooled tiles, explicit sample validity,
bounded work queues, dependency halos, and budgeted eviction. Start by adapting
the existing sparse Diamond-Square evaluator rather than replacing its math.

## 5. Five shared LOD levels

“4 voxels” means a cell four voxels along each axis, not four voxels total.

| LOD | Cell side in voxels | Cell dimensions |
| --- | --- | --- |
| Voxel | 1 | 1×1×1 voxel |
| Voxel cluster | 4 | 4×4×4 voxels |
| Block | 16 | 1×1×1 block |
| Block cluster | 64 | 4×4×4 blocks |
| Chunk | 256 | 1×1×1 chunk |

Share an explicit spacing table between scheduler, generation requests, CPU
summaries, and GPU representation. Keep noise's internal levels separate.

Example policy, with independently configurable cumulative outer radii:

```text
spacing_voxels   outer_radius_chunks
1                3
4                6
16              12
64              24
256             48
```

Only 3 and 6 come from the requested example; the other values are illustrative.
Intervals are [0,3), [3,6), [6,12), [12,24), [24,48); outside the last radius is
outside visible coverage. Require strictly increasing positive radii. Changing
distances does not invalidate procedural field values.

Initially choose LOD per runtime chunk, using horizontal camera-to-chunk-AABB
distance in chunk units. This keeps any chunk intersecting the near zone detailed
and gives the CPU/GPU one unambiguous ownership unit. Use an independent vertical
streaming range; optionally support 3D distance as an explicit policy later.
Within a chunk, all approximation cells use the selected spacing. A future
cell-based policy can refine parts of a chunk without changing the field API.

Use continuous camera position, separate promotion/demotion thresholds, and a
configurable hysteresis margin. Balance neighbors to at most one ×4 step, allowing
extra detail where needed. Queue coarse visible coverage first, then near detail;
bound generation, upload work, and memory separately. Cancel obsolete demand,
reuse completed fields, and keep the previous complete representation visible
until its replacement and required boundary data are ready.

The current fixed streaming window is too small for the illustrative 48-chunk
radius. Replace dense far-world residency with sparse chunk descriptors and
budgeted coarse coverage; never allocate full block/voxel storage for each far
chunk. Keep configurable draw distance distinct from cell size.

## 6. Rendering integration and approximation policy

Introduce render-only LOD payloads alongside authoritative world data. A coarse
cell stores occupancy and representative material; full-resolution edits and
collision data remain authoritative. Missing data, known air, and approximate
solid must be distinct states. Do not reinterpret existing exact `mono` chunks
as approximate terrain without explicit metadata.

For the first terrain renderer, use aligned cubic cells at the requested spacing.
Evaluate the canonical coarse height at each horizontal cell's lower corner,
matching the current Result convention, and fill vertical cells whose centers
are below that height. Specify this quantization once for CPU and GPU. This is
an intentional coarse approximation: thin features may disappear and distant
mountains become stepped. One-chunk LOD is particularly coarse; expose previews
so users can tune its starting distance. Do not claim conservative occupancy
from a single height sample. Conservative bounds can be added as a separate
certified summary mode later.

Generate coarse payloads directly from coarse fields, without generating all
children first. Reduction of already resident fine data must use the same
canonical sampling policy so camera travel does not change the coarse result.
For edited regions, retain an edit overlay and invalidate affected summaries;
the terrain surface shortcut cannot represent arbitrary edits. Use an explicit
edit-aware summary path, with fine data retained until the replacement is ready.

Extend GPU chunk descriptors with active spacing and LOD payload references.
Teach `sampleMaterial` and ray traversal to query and step through aligned
1/4/16/64/256 cells. Step to cell or ownership-boundary exits, recomputing all
coordinates from ray position; merely increasing ray step length can miss solids.
Apply the same representation policy to secondary rays and normals. Publish
descriptor/payload changes atomically and retire old GPU storage after readers
finish.

Mixed-resolution ownership uses half-open chunk/cell bounds and exact shared
boundary coordinates, including negative positions. With cubic occupied-cell
rendering, geometric steps between LODs are expected; unintended gaps, overlaps,
or skipped cells are bugs. Mesh stitching is unnecessary for the current ray
renderer. Temporal dithering or morphing is optional later polish, not a substitute
for correct boundary traversal. CPU picking requests fine authoritative data near
the player rather than treating a coarse display cell as an editable voxel.

### 6.1. Incremental CPU–GPU communication and moving rings

The CPU owns world state and decides which chunks the GPU should display at each
LOD. CPU world storage and GPU rendering storage are separate representations;
expect their layouts to diverge substantially in the future. Translate through
an explicit render-payload builder and versioned command interface, never by
requiring CPU chunks, disk records, and GPU buffers to share a memory layout.

Maintain desired residency keyed by global chunk coordinate, alongside the last
published GPU residency. Diff these states after applying distance policy,
hysteresis, and neighbor balancing. Send only changes:

- **Add:** upload a payload and publish a descriptor for a newly visible chunk.
- **Replace:** upload a new payload for a changed chunk or LOD, then switch its
  descriptor once ready. Promotion/upscaling means finer cells; demotion/
  downscaling means coarser cells. Neither changes the authoritative world.
- **Remove:** send an explicit removal command for a chunk outside coverage,
  invalidate its descriptor, and reclaim its GPU storage after readers finish.
- **Unchanged:** retain the existing descriptor and payload without re-upload.

For example, moving one chunk north moves the LOD rings with the player. Some
chunks crossing inner boundaries need finer detail, others crossing outward need
coarser detail, newly covered chunks need adding, and chunks leaving the outer
ring need removal. Most chunks retain their current LOD and send no data. Compute
membership from global coordinates; shifting the camera must not rename chunks
or trigger a full-world upload. Hysteresis may defer individual transitions.

Batch commands and changed payloads within per-frame budgets. Initially a changed
chunk may send its complete replacement render payload; change-only streaming
means avoiding unchanged chunks, not requiring voxel-level patches. Reserve
partial-payload updates as a later optimization. Metadata-only removal carries
no terrain payload.

Commands carry chunk coordinates, world/configuration identity, content revision,
and a residency/request generation. Reject obsolete completions, including a
late upload after removal or a remove targeting an older incarnation of a chunk.
Track pending versus published state so delayed uploads are not enqueued every
frame; coalesce superseded requests. Publish compatible replacements and boundary
data together where required by the neighbor policy. Keep old coverage until
replacement publication, and fence storage retirement before reusing allocations.
GPU eviction and CPU unloading are distinct decisions: removing a GPU chunk does
not itself discard authoritative CPU state.

### 6.2. CPU persistence and world export

Use `worlds/test/worldstructure/` as the initial world-storage root. When unloading
a CPU chunk, persist its authoritative state before releasing it; unchanged
chunks with an already committed record need no rewrite. Store coordinates,
content revision, and lossless world data or sufficient deterministic generation
inputs plus edits to reconstruct that data. Never persist only its current coarse
render payload, which may omit edits or fine detail. On revisit, load saved state
before falling back to procedural generation for a chunk with no saved record.

Plan a versioned storage format independent of both CPU structs and GPU layouts:

- A world manifest records world identity, seed, generator/configuration version,
  the field graph/preset, material definitions or stable references, coordinate
  conventions, and chunk-index/format versions.
- Chunk records use stable global coordinates, including negative coordinates,
  and record their schema, revision, encoding, and integrity check. Define whether
  a record contains full authoritative data or a procedural base plus edit overlay.
  Procedural records require a compatible generator and all referenced assets;
  otherwise loading must report incompatibility rather than silently change terrain.
- Save asynchronously from a consistent chunk revision. Commit records through
  temporary files and atomic publication, with an index/manifest commit protocol
  that never references incomplete records. Clear dirty state only for the saved
  revision; edits made during a write remain dirty. Failed saves retain data for
  retry, apply memory backpressure, and report errors instead of losing edits.
- Treat missing, corrupt, and unsupported-version records differently. Only a
  genuinely absent record permits normal generation; damaged saved edits must not
  be silently overwritten. Define migrations before changing the storage schema.

World export is a separate milestone built on this persistence format. Initially
export a consistent snapshot of the saved/explored world plus all resident dirty
chunks, including chunks currently outside GPU coverage. Capture one logical
snapshot revision, flush or snapshot pending writes, and include the manifest,
chunk index/records, preset, and required assets. An unbounded procedural world
cannot be fully materialized: label this export as saved chunks plus generation
rules for the remainder. A future bounded-region export may explicitly generate
and include all chunks within requested bounds.

Write exports to a staging destination, validate referenced records and assets,
then publish the completed directory or archive without overwriting the source
world. Specify export format version, progress, cancellation, and failure cleanup.
Provide import/load into a separate world directory and a round-trip check of
seed, configuration, chunk coordinates, materials, and edits. GPU buffers and
rebuildable rendering caches are not part of the portable world format.

## 7. Implementation milestones

1. **Shared resolution and policy types.** Add the five-level spacing table,
   configurable chunk radii, validation, distance selection, and hysteresis.
   Replace the preview's hard-coded three-level policy and display all five bands.
2. **Graph and stage contract.** Add field IDs/types, graph validation, stable seed
   namespaces, dependency scheduling, and adapters for sparse Diamond-Square,
   constants, remaps, and hierarchical value noise. Demonstrate a custom callback.
3. **Biomes and height.** Add selector bands/trees, polygon palettes, exact
   classification, optional normalized transition weights, fallback behavior,
   blended terrain profiles, and anchored final-height
   refinement. Ship the three default fields plus a preset using none of them.
4. **Terrain outputs and inspection.** Add materials, snow/ice surface rules,
   basic water masks, and exports for each field, labeled polygon palettes, biome
   identities/weights, height, and LOD.
   Keep plant placement as a future consumer of these outputs.
5. **Streaming and CPU payloads.** Integrate graph requests with world jobs,
   sparse far coverage, generation versions, edit protection, cache budgets,
   direct coarse payload generation, and safe promotion/demotion. Define the
   CPU-to-render conversion boundary independently of authoritative storage.
6. **GPU LOD.** Add render descriptors/payloads and all five traversal sizes.
   Add batched add/replace/remove commands and desired-versus-published residency
   diffing. Verify mixed boundaries, stale commands, and secondary rays; then
   enable automatic camera LOD with change-only uploads.
7. **Chunk persistence.** Define the manifest and chunk schema under
   `worlds/test/worldstructure/`, save before CPU eviction, reload saved chunks,
   and handle concurrent edits, failed writes, and incompatible records.
8. **World export/import.** Implement consistent saved-world snapshots, bundle
   generator configuration and assets, validate staged exports, and verify import
   into a separate world directory.
9. **Performance and tuning.** Measure generation time, GPU time, upload bytes,
   resident memory, cache hits, allocations, and generated samples per level.
   Tune defaults with moving-camera scenes rather than preview images alone.

Suggested new modules under `src/world/generation/`: `fields.zig`, `graph.zig`,
`biomes.zig`, `terrainProfiles.zig`, and `terrainPipeline.zig`. Put shared LOD
policy in `src/world/lod.zig` and render payload construction in a separate world
module. Exact module boundaries may evolve during implementation.

## 8. Acceptance criteria

- All default fields can be disabled; a custom field/biome preset still works.
- Invalid graphs, missing references, incompatible handoffs, and invalid radii
  produce actionable errors before generation starts.
- Palette validation rejects invalid polygons and interior overlaps; complete
  coverage or explicit fallback guarantees a biome for every valid input tuple.
  Shared edges, vertices, selector thresholds, and exact 0/1 endpoints are tested.
- Three- and four-field presets work through palette selectors without 3D/4D
  authoring. Reused palettes and disabled/replaced axis inputs work correctly.
- Optional biome weights are finite, nonnegative, normalized, and deterministic
  at polygon junctions and palette transitions. Zero blending gives exact lookup.
  Profile blends avoid accidental cliffs without changing exact biome identity.
- Direct fine generation matches progressive refinement, including algorithm
  switches, cache eviction, request reordering, and negative coordinates.
- Parent field and final-height anchors remain unchanged; adjacent tiles agree
  on shared samples without requiring neighboring runtime chunks to be loaded.
- Every spacing 1/4/16/64/256 works in generation and actual rendering. Coarse
  requests do not expand the full region to voxel detail.
- Changing camera position updates LOD automatically with independently editable
  radii. Threshold oscillation does not repeatedly regenerate or upload terrain.
- Moving one chunk north produces only the required additions, removals, and
  finer/coarser replacements after hysteresis and balancing. Unchanged chunks
  produce no payload uploads; a stationary unchanged world sends no chunk updates.
  Measure command counts and uploaded bytes against a full-residency upload.
- Delayed uploads/removals, rapid direction reversals, and leaving then re-entering
  coverage never resurrect stale chunks or retire a newer chunk's allocation.
- CPU representation changes do not require matching GPU or disk layouts; the
  conversion and serialization contracts preserve world identity and edits.
- CPU eviction and reload preserve edits and fine data across all display LODs,
  including negative coordinates. Failed saves prevent loss; edits during a save
  remain dirty until their revision is committed.
- Export/import round trips preserve saved chunks, seed, graph, materials, and
  edits, including unloaded chunks and pending resident changes. Interrupted
  exports do not appear complete or damage the source world; incompatible or
  corrupt saved records produce explicit errors.
- Boundary rays in both directions, axis-aligned rays, and edge/corner ties cross
  mixed LODs without unintended holes or missed cells.
- Player edits survive outstanding generation and LOD changes. Collision and
  picking remain correct near the player.
- Slow generation or upload leaves a complete prior representation visible.
  Stale job results never replace newer configuration or edits.
- Compare uniform and mixed LOD on identical worlds and coverage. Report actual
  CPU/GPU/memory results; fewer samples alone do not establish a speedup.

Future extensions: plant/structure consumers, 3D density fields and caves,
connected water networks, erosion, runtime preset editing, partial-chunk LOD,
and spacing above 256. None should require reserving particular climate names
inside the core graph API.
