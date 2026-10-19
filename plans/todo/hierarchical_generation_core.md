# Hierarchical Generation Core

## Status

Design / implementation specification for shared hierarchical generation infrastructure: world dimensions, generation regions, progressive refinement, hashing, seed mixing, caching, and integration boundaries.

The initial generation region is 2D in X/Z. Its first consumer and concrete noise implementations are specified in [Hierarchical Terrain Generation](hierarchical_terrain_generation.md). Terrain examples below illustrate the shared interfaces and requirements.

---

# 1. Core Goals

The terrain generator should support progressive refinement.

The generator must be able to:

- generate very coarse terrain for distant regions,
- stop generation at the resolution currently required,
- later refine the same region,
- reuse previously generated coarse values,
- avoid recalculating values that are already known,
- keep existing sample points stable across refinement,
- remain deterministic,
- work with chunk streaming,
- support multiple planets with different generation pipelines,
- support multiple hierarchical noise algorithms,
- allow custom user-defined generation stages.

The main idea is:

```text
coarse generation
      ↓
reuse previous data
      ↓
refine
      ↓
reuse previous data
      ↓
refine
      ↓
...
      ↓
full voxel resolution
```

Distant terrain should not require full voxel generation.

---

# 2. Existing World Representation

The existing horizontal hierarchy is:

```text
Superchunk = 16 × 16 Chunks
Chunk      = 16 × 16 Blocks
Block      = 16 × 16 Voxels
```

Therefore:

```text
1 Block      = 16 × 16 voxels
1 Chunk      = 256 × 256 voxels
1 Superchunk = 4096 × 4096 voxels
```

Important distinction:

> The Superchunk described in this document is initially a PROCEDURAL-GENERATION structure only.

It does not automatically become part of runtime gameplay storage.

It exists to provide a deterministic region for large-scale hierarchical generation.

Runtime storage can continue to use the existing chunk/block/voxel hierarchy.

A future runtime Megachunk system may be added later, but that is a separate feature.

---

# 3. 2D Generation Hierarchy

The first hierarchical terrain-generation implementation is 2D.

It works over the horizontal terrain plane.

Use X/Z coordinates.

Vertical terrain can later be derived from the resulting fields as:

- height,
- density,
- surface level,
- biome information,
- material masks,
- mountain strength,
- river masks,
- cave parameters,
- etc.

The hierarchical subdivision itself is initially:

```text
2D only
```

Do not implement the procedural Superchunk as a 3D 16×16×16 chunk container.

It is:

```text
16 × 16 chunks
```

in the X/Z plane.

---

# 4. Natural Resolution Levels

Use ×4 spacing increments per spatial axis for public generation levels:

| Sample spacing in voxels | World scale |
| --- | --- |
| 1 | 1 voxel |
| 4 | 4 voxels |
| 16 | 1 block |
| 64 | 4 blocks |
| 256 | 1 chunk |
| 1024 | 4 chunks |
| 4096 | 1 procedural Superchunk / root scale |

Generate coarse to fine: `4096 -> 1024 -> 256 -> 64 -> 16 -> 4 -> 1`.
Each public refinement divides spacing by four, adding an intermediate level between the named voxel, block, and chunk scales. These are spatial spacing values, not counts of algorithm operations.

Algorithms may require internal ×2 subdivisions. Keep those intermediate dependencies cached, but expose completed ×4 levels for scheduling and stage handoff. A ×4 refinement increases cell count by 16 in 2D or 64 in 3D over the same area or volume; refine only requested regions, not the entire world.

The first terrain field remains 2D X/Z, feeding the 3D voxel world. Future 3D density generators use the same spacing sequence along all three axes without changing the existing 2D Superchunk definition.

---

# 5. Position-Driven Progressive Generation

A request supplies a focus position, bounded region, and configurable detail policy. The policy maps distance to one of the public spacings `1, 4, 16, 64, 256, 1024, 4096`; larger distances request coarser fields. Configure distance thresholds rather than hard-coding view distances.

Conceptual API (types and ownership still need implementation):

```zig
const GenerationRequest = struct {
    region: GenerationRegion2D,
    focus: Vec3i,
    detail_policy: DetailPolicy,
    pipeline_id: u64,
    work_budget: usize,
};
```

The scheduler calculates required spacing per globally aligned tile from its bounds and the focus. For 2D heightfields, use X/Z distance; a future 3D density scheduler uses 3D bounds. Use a conservative bound such as the nearest point on a tile so a tile intersecting a near-detail band receives enough detail.

- Schedule missing ancestors before dependent detail, with nearer visible work first.
- Stop at the requested spacing and respect the per-update work budget.
- On focus movement, compare desired coverage with cached validity and enqueue only missing samples and dependencies.
- Keep existing samples and coarse parents unchanged. Moving the focus changes demand, never seeds or generated values.
- Retain finer cached data when a region moves farther away; hysteresis at distance thresholds avoids repeated promotion and eviction.
- Deduplicate queued/inflight work. Evict only under a defined memory budget, recycling buffers; revisiting evicted regions may require deterministic reconstruction.
- Allow explicit target-spacing requests for previews, tests, and callers without a moving focus.

Coarse/fine interfaces need compatible boundary samples and a renderer transition policy to avoid cracks. Additional generation levels enable farther coarse coverage, but do not by themselves guarantee a frame-rate or draw-distance improvement.

---

# 6. Reusing Previous Values

This is a core requirement.

When refining:

```text
existing samples MUST stay unchanged
```

Only newly introduced sample positions should be generated.

Example:

```text
coarse:

A---------------B
|               |
|               |
|               |
C---------------D
```

after refinement:

```text
A-------E-------B
|               |
|               |
F-------X-------G
|               |
|               |
C-------H-------D
```

Values:

```text
A B C D
```

already existed.

They must not be regenerated.

Only:

```text
E F G H X
```

are new.

Further refinement repeats this rule.

This allows:

```text
generate far terrain
      ↓
cache coarse values
      ↓
player approaches
      ↓
continue refinement
```

instead of:

```text
generate coarse terrain
      ↓
throw it away
      ↓
generate everything again
```

---

# 7. Generic Hierarchical Noise Architecture

Separate position-driven scheduling from deterministic algorithm execution. The scheduler accepts the focus and detail policy, computes tile demands, and passes explicit source and target spacing to each algorithm. Algorithms must not use camera position as randomness.

Conceptual interface (placeholder types, not final compilable Zig):

```zig
pub const GenerationRegion2D = struct {
    origin: Vec2i,
    size: Vec2u,
};

pub const RefinementRequest = struct {
    region: GenerationRegion2D,
    source_spacing: u32,
    target_spacing: u32,
    stage_id: u64,
    seed: u64,
};

pub fn refine(
    request: RefinementRequest,
    inputs: []const FieldView,
    output: *MutableFieldTile,
    scratch: *ScratchArena,
) !void;
```

`FieldView` describes immutable input samples, global origin, spacing, dimensions, value type, validity, and dependency/version identity. Output provides allocated storage and a validity mask: write only missing samples. Scratch storage is reused between calls.

Each stage declares its accepted input/output fields, source and target spacing, required neighbor halo/ancestors, configuration, and algorithm identity. Validate field compatibility and acyclic dependencies before execution. Cache keys include world/planet seed, pipeline/configuration version, stage, field, spacing, and global tile coordinates; focus position is excluded.

A completed stage output can feed a different algorithm at the next ×4 level or a separately named derived field. Adapters define interpolation, resampling, units, and masks explicitly. Do not silently reinterpret region IDs as heights or 2D fields as 3D density.

For refinement of the same field, preserve every inherited sample exactly. A strategy that modifies old samples must produce a separate derived field/version; it cannot overwrite the cached parent field. Changes to seeds or pipeline configuration explicitly invalidate affected outputs and their dependents.

Algorithms may keep private internal passes and caches. A random-access implementation must reconstruct the same parent dependencies as incremental refinement rather than bypassing the configured stage pipeline.

---

# 8. Hierarchical Noise Requirements

Where practical, hierarchical noises should provide:

- deterministic generation,
- stable old samples,
- progressive refinement,
- reusable coarse data,
- global-coordinate sampling,
- chunk-independent results,
- configurable resolution levels,
- optional caching,
- random-access reconstruction where possible.

Each implementation may define:

- subdivision rule,
- interpolation rule,
- displacement rule,
- dimensionality,
- required parent values,
- step count,
- level spacing,
- data type,
- output range.

---

# 9. Procedural Generation Superchunk

Implement a 2D structure used specifically for procedural generation.

Conceptually:

```zig
pub const GenerationSuperchunk = struct {
    position: Vec2i,
    seed: u64,

    // Hierarchical data / cache.
};
```

Size:

```text
16 × 16 Chunks
```

or:

```text
4096 × 4096 Voxels
```

horizontal coverage.

Main responsibilities:

- provide a stable generation region,
- own or reference hierarchical generation data,
- allow progressive refinement,
- support caching,
- guarantee deterministic shared boundaries,
- allow large terrain features to span many chunks,
- allow far terrain generation to stop early.

Do not make this structure responsible for normal gameplay chunk storage.

---

# 10. Superchunk Coordinates

A Superchunk has integer coordinates:

```text
superchunk_x
superchunk_z
```

Its chunk-space origin is:

```text
chunk_origin_x = superchunk_x * 16
chunk_origin_z = superchunk_z * 16
```

Its voxel-space origin is:

```text
voxel_origin_x = superchunk_x * 4096
voxel_origin_z = superchunk_z * 4096
```

All procedural sample positions should preferably be convertible to stable global integer coordinates.

---

# 11. Deterministic Position Hashing

Implement reusable position hashing for procedural generation.

Required forms:

```text
1D
2D
3D
```

Conceptually:

```zig
pub fn hash1D(
    seed: u64,
    x: i64,
) u64;

pub fn hash2D(
    seed: u64,
    x: i64,
    z: i64,
) u64;

pub fn hash3D(
    seed: u64,
    x: i64,
    y: i64,
    z: i64,
) u64;
```

Requirements:

- deterministic,
- fast,
- good avalanche,
- works with negative coordinates,
- no mutable RNG state,
- coordinate order matters,
- suitable for very frequent generation calls.

---

# 12. Position Structures and Hashing

The engine already uses or will use position structures for:

```text
Voxel
Block
Chunk
```

and now procedural:

```text
Superchunk
```

Provide a consistent way to hash those positions.

Example concept:

```zig
pub fn hashPosition(
    seed: u64,
    position: anytype,
) u64;
```

or explicit functions if that is cleaner and faster.

Do not depend on memory layout / raw struct hashing unless layout is deliberately standardized.

Prefer hashing the numeric coordinates explicitly.

---

# 13. Seed Mixing

Different generation systems should be able to derive independent deterministic seeds from the same world seed.

Example:

```text
world seed
   ↓
planet seed
   ↓
generator seed
   ↓
noise seed
   ↓
position hash
```

Provide something equivalent to:

```zig
pub fn mixSeed(
    seed: u64,
    value: u64,
) u64;
```

Example:

```zig
var seed = world_seed;

seed = mixSeed(seed, planet_id);
seed = mixSeed(seed, generator_id);
seed = mixSeed(seed, hierarchy_level);

const value = hash2D(
    seed,
    global_x,
    global_z,
);
```

This should make separate procedural systems independent while remaining reproducible.

---

# 14. Hash Output Helpers

Provide helpers for common output formats.

Examples:

```zig
hashToU8
hashToU16
hashToU32

hashToUnitF32
hashToSignedF32

hashToRangeI32
hashToRangeI64
```

Useful ranges:

```text
[0, 1]

[-1, 1]

[-max, +max]
```

Terrain generation should support integer-based displacement where useful.

Avoid forcing every terrain algorithm through floating-point math.

---

# 15. Shared Superchunk Edges

Neighboring Superchunks must generate identical values on their shared edge.

Example:

```text
Superchunk A          Superchunk B

+-----------+-----------+
|           |           |
|           |           |
|           |           |
+-----------+-----------+
            ^
            shared edge
```

Both sides must generate the same value for every shared sample.

Do not rely on:

- generation order,
- which Superchunk generated first,
- mutable RNG state,
- copying from an already existing neighbor.

Instead:

```text
same global position
+ same seed
+ same hierarchy step
= same result
```

This is one of the main reasons position hashing is required.

---

# 16. Caching Hierarchical Levels and Allocation

Cache globally aligned tiles by field, stage, and public spacing. Each tile tracks allocated capacity, completed samples, and pending work separately. Validity must be granular enough to resume partial generation without recalculating already completed values.

Grow and fill the sampling pattern at ×4 spatial increments: preserve parent positions, then populate only missing child positions in requested tiles. Internal ×2 dependencies, when required by an algorithm, remain reusable in the same cache or scratch storage with an explicit lifetime.

- Use fixed-size tile slabs or pooled buffers per sample type and level; reserve tile storage once and fill it incrementally.
- Reuse scratch buffers and retained capacities across requests and focus movement.
- Batch allocations for newly entered regions instead of allocating per sample, algorithm operation, or frame.
- Avoid repeatedly resizing and copying a monolithic grid and avoid reserving full voxel-resolution storage for an entire Superchunk.
- Retain coarse ancestors while dependent fine work needs them. Pin buffers during inflight work and recycle only after readers finish.
- Apply a configurable memory budget and eviction policy; release or recycle cold detail before useful coarse data.
- Include required boundary/halo samples in capacity planning and use global sample identity to keep neighboring tiles consistent.

Measure allocation counts, peak memory, cache hits, and generated sample counts during movement. Moving within already cached coverage should require no new sample generation or growth of generation buffers.

---

# 17. Avoiding Duplicate Boundary Storage

Shared Superchunk boundaries may either:

1. be physically duplicated but guaranteed identical by hashing,

or

2. eventually use shared ownership/cache structures.

For the first implementation, deterministic duplication is acceptable and simpler.

Correctness matters first.

Optimization can come later.

---

# 18. Custom User Generation

The engine should eventually allow a user/game to define custom generation code.

Do not design the system so only built-in noise types can be used.

Possible concept:

```zig
const GenerationStage = union(enum) {
    hierarchical_noise: HierarchicalNoiseConfig,
    noise: NoiseConfig,
    remap: RemapConfig,
    combine: CombineConfig,
    custom: *const fn (...) void,
};
```

Exact API can be designed later.

The important requirement is:

```text
custom generation remains possible
```

---

# 19. Relationship to Rendering LOD

This procedural system is intended to support the engine's spatial LOD concept.

Runtime rendering may approximately move through representations such as:

```text
full voxels
    ↓
merged voxel cells
    ↓
blocks
    ↓
merged blocks
    ↓
chunks
    ↓
future megachunks
```

Do not directly couple generation algorithms to those exact renderer structures.

Instead:

```text
renderer requests required spatial resolution
        ↓
generation system generates enough detail
```

Far terrain may therefore be rendered using large boxes/cells while only coarse terrain generation has been performed.

---

# 20. Keep GPU Branching Limited

The runtime LOD system should avoid excessive numbers of representation types because too many types can increase GPU branching.

This is not directly the responsibility of the hierarchical noise implementation, but the generation system should not force one distinct GPU representation per noise level.

Many generation refinement levels may map to a much smaller number of rendering LOD representations.

For example:

```text
many noise levels
      ↓
few GPU LOD stages
```

This separation is intentional.

---

# 21. Important Separation of Concepts

Keep these concepts separate:

```text
hierarchical NOISE level

generation RESOLUTION

runtime WORLD storage

GPU LOD representation
```

They interact, but they are not the same thing.

Example:

```text
Diamond-Square may perform many refinement steps

but

renderer may expose only 4 or 5 practical LOD representations
```

Do not encode GPU-specific assumptions into Diamond-Square.

---

# 22. Performance Notes

The first implementation should prioritize correctness and deterministic behavior.

Still avoid obviously unnecessary work.

Important principles:

- generate only requested levels,
- do not recompute existing samples,
- use integer coordinates for hashing,
- avoid sequential RNG state,
- operate on contiguous arrays where practical,
- generate full rows/regions rather than excessive function-call-per-sample overhead,
- leave room for SIMD/vectorization later.

Do not prematurely optimize the initial version into an unreadable implementation.

---

# 23. Future Optimization Possibilities

Possible later improvements:

```text
SIMD generation
parallel Superchunk generation
parallel independent refinement regions
memory pooling
sparse cached levels
GPU-assisted procedural generation
precomputed hash batches
vectorized interpolation
```

These are NOT requirements for the first implementation.

---

# 24. First Implementation Priorities

Implement hashing and the generation region before terrain algorithms.

## 24.1 Position hashing

Implement:

```text
hash1D
hash2D
hash3D
seed mixing
hash-to-range helpers
```

Test:

- determinism,
- negative coordinates,
- nearby-coordinate distribution,
- same inputs produce same values,
- different dimensions/order produce different values.

---

## 24.2 2D Generation Superchunk

Implement:

```text
16×16 Chunk procedural region
```

Provide:

- coordinate conversion,
- global origins,
- generation seed,
- simple hierarchical data storage.

Do not over-engineer caching yet.

---

## 24.3 Cache/reuse

Make it possible to continue generation from already produced data rather than restarting from scratch.

---

# 25. Tests

## Hash tests

Test:

```text
same seed + same position = same hash
different position usually = different hash
negative coordinates work
coordinate order matters
```

---

# 26. Summary of Critical Rules

The most important rules are:

```text
Superchunk = 16×16 Chunks

Chunk = 16×16 Blocks

Block = 16×16 Voxels
```

The Superchunk in this document is:

```text
2D
procedural-generation only
```

Generation is:

```text
progressive
```

Old values are:

```text
reused
and never changed by refinement
```

Randomness is:

```text
position-hashed
deterministic
seeded
```


---
