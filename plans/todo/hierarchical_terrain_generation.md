# Hierarchical Procedural Terrain Generation

## Status

Design / implementation specification for hierarchical terrain generation, beginning with a modified Diamond-Square algorithm and extending to additional noises and planet-specific terrain pipelines.

Shared world dimensions, generation regions, resolution levels, sample stability, hashing, seed mixing, caching, and rendering/storage boundaries are defined in [Hierarchical Generation Core](hierarchical_generation_core.md). Implement those prerequisites before the terrain algorithms below.

## ×4 Detail Levels and Algorithm Handoffs

Use the public spatial spacing sequence from the [generation core](hierarchical_generation_core.md):

```text
4096       1024       256       64        16       4        1 voxel
Superchunk 4 chunks   1 chunk   4 blocks  1 block  4 voxels 1 voxel
```

Refine left to right. These increments add detail between the named world scales while allowing distant terrain to stop early. Each level may select its own strategy and consume the completed result of a previous level.

Example configurable pipeline (illustrative, not mandatory):

| Output spacing | Strategy and inputs |
| --- | --- |
| 4096 | Hashed roots and broad mountain-region parameters |
| 1024 | Diamond-Square macro elevation from roots |
| 256 | Hierarchical value refinement consuming macro elevation and a ridge mask |
| 64 | Midpoint-refined ridge skeleton, rasterized into a separate detail mask and combined during height refinement |
| 16 | Height refinement using the previous field and ridged detail |
| 4 | Local slope-aware rock detail at newly introduced samples |
| 1 | Final surface refinement, followed by material/density conversion |

Expose stage configuration per ×4 transition, including algorithm, typed input fields, output field, seed namespace, and parameters. Support branching: one coarse result may feed several later algorithms. Preserve parent samples when refining the same field; transformations that alter existing values produce a separate derived field with explicit dependencies.

For added detail, use interpolation plus a residual constrained to zero at inherited sample positions. Simply adding unrestricted noise everywhere would change the coarse mountain shape. Keep mountain location and existing elevation samples stable while adding finer ridges, valleys, and surface detail between them.

The scheduler accepts a central/focus position and a distance-to-spacing policy, then requests only missing tile detail. Moving the center must reuse existing results and allocated tile capacity. Grow coverage and fill samples in the same ×4 levels, using pooled tile storage rather than repeatedly allocating larger full-region grids. See the core plan for interfaces, cache identity, memory budgets, and 2D versus future 3D scheduling.

## Diamond-Square Operations Versus Public Levels

A public ×4 refinement contains two internal ×2 Diamond-Square refinements. Each internal refinement still has two independently configured operations. Thus one public transition consumes four displacement entries; root initialization consumes entry zero once.

```text
4096 roots: configuration[0]
4096 -> 1024: Square, Diamond, Diamond, Square (entries 1–4)
1024 -> 256: Diamond, Square, Diamond, Square (entries 5–8)
... when Diamond-Square continues
```

The special Square-then-Diamond pair applies only at root initialization. Keep internal ×2 samples as dependencies; hand completed ×4 results to the next public stage. A pure Diamond-Square pipeline from 4096 to 1 has six public transitions, twelve internal refinements, and 25 displacement entries including the root. Shorter arrays are valid only for the depths they cover.

When switching algorithms, preserve inherited samples and use a documented adapter. A stage that resumes Diamond-Square must supply its required grids, boundary halo, and operation index; an arbitrary field is not automatically a valid resumable Diamond-Square state. Reject incompatible stage configurations instead of resetting the special first pass at each handoff.

## Implementation and Acceptance Tasks

- [ ] Add public spacing levels `4096, 1024, 256, 64, 16, 4, 1` and validate ×4 stage transitions.
- [ ] Add focus-driven tile scheduling, configurable distance bands, hysteresis, and per-update work budgets.
- [ ] Extend the noise interface with explicit source/target spacing, typed parent inputs, writable validity, and reusable scratch storage.
- [ ] Implement configurable stage handoffs and adapters, including a coarse mountain stage followed by a different fine-detail strategy.
- [ ] Allocate pooled tiles in batches and fill only missing positions; track internal Diamond-Square dependencies without repeated grid reallocations.
- [ ] Verify pure Diamond-Square operation indexing across all six public transitions and reject insufficient displacement arrays.
- [ ] Compare direct fine generation with incremental mixed-algorithm refinement, including boundary halos and negative coordinates.
- [ ] Move the focus within cached coverage and verify zero regenerated samples; move into new coverage and verify only missing samples/dependencies are generated.
- [ ] Verify inherited samples remain bit-identical across strategy switches and that seed/configuration changes invalidate dependent caches.
- [ ] Verify coarse/fine boundaries and renderer transitions at every public spacing.
- [ ] Measure allocation count, peak memory, generated samples, generation time, and render time at increasing view distances in the 3D world.

---

# 1. First Concrete Noise: Diamond-Square

Implement Diamond-Square as the first hierarchical terrain noise.

It operates over the 2D procedural Superchunk.

Normal Diamond-Square repeatedly performs:

```text
Diamond
Square
```

However:

> The first Superchunk refinement uses the reverse order.

The first refinement is:

```text
Square
Diamond
```

All later refinements return to:

```text
Diamond
Square
```

---

# 2. Reason for Reversing the First Step

The first Superchunk refinement should establish boundary/edge values before calculating the center.

Initial corners:

```text
A---------------B
|               |
|               |
|               |
|               |
C---------------D
```

First generate edge midpoints:

```text
A-------E-------B
|               |
|               |
F               G
|               |
|               |
C-------H-------D
```

Then generate the center:

```text
A-------E-------B
|       |       |
|       |       |
F-------X-------G
|       |       |
|       |       |
C-------H-------D
```

The primary reason is:

```text
SUPERCHUNK EDGE ALIGNMENT
```

Neighboring Superchunks share boundary samples.

Those shared edge samples should be established deterministically from global coordinates before the internal center is generated.

---

# 3. Diamond-Square Step Ordering

The intended sequence is:

```text
Initial corner/root values

Square     <- special first step
Diamond

Diamond
Square

Diamond
Square

Diamond
Square

...
```

Only the first pair is reversed.

After that, use standard Diamond-Square ordering.

---

# 4. Explicit Per-Step Diamond-Square Control

Do NOT control Diamond-Square only with a generic formula like:

```text
amplitude *= roughness
```

Instead, every individual operation must have an explicitly configurable maximum random displacement.

The configuration is provided as a compile-time array.

Example:

```zig
const displacement_steps = [_]i32{
    4096,

    1800,
    1200,

    800,
    650,

    400,
    300,

    180,
    120,

    80,
    50,

    30,
    20,

    10,
    6,

    3,
    1,
};
```

The values above are only examples.

The implementation must not assume this particular curve.

---

# 5. Meaning of the Diamond-Square Configuration Array

The meaning of each index is strict.

```text
index 0
```

is the maximum random range/amplitude for the initial hashed/root values.

Every later index corresponds to ONE individual algorithm step.

A Diamond step and a Square step are separate configuration entries.

The sequence is:

```text
index 0:
    initial hashes / root values

index 1:
    first Square step

index 2:
    first Diamond step

index 3:
    second Diamond step

index 4:
    second Square step

index 5:
    third Diamond step

index 6:
    third Square step

index 7:
    fourth Diamond step

index 8:
    fourth Square step

...
```

In compact form:

```text
0 Initial

1 Square
2 Diamond

3 Diamond
4 Square

5 Diamond
6 Square

7 Diamond
8 Square

...
```

This unusual beginning is intentional.

---

# 6. Why Diamond and Square Get Separate Values

Diamond and Square operations must not share a single amplitude value.

The generator author should be able to independently control them.

This allows terrain such as:

```text
strong Square displacement
weak Diamond displacement
```

or:

```text
weak Square displacement
strong Diamond displacement
```

or irregular sequences like:

```text
large
small
medium
tiny
larger again
...
```

Do not require displacement values to decrease monotonically.

This is intended to provide direct artistic/procedural control.

---

# 7. Compile-Time Configuration

The displacement array should be compile-time known.

Possible API:

```zig
pub fn DiamondSquare(
    comptime T: type,
    comptime displacement_steps: []const T,
) type {
    return struct {
        // ...
    };
}
```

or:

```zig
pub fn generateDiamondSquare(
    comptime displacement_steps: []const i32,
    seed: u64,
    superchunk: *GenerationSuperchunk,
    target_resolution: u32,
) void {
    // ...
}
```

A compile-time array provides:

- validation,
- specialization,
- no dynamic configuration allocation,
- possible dead-code elimination,
- per-generator terrain tuning.

---

# 8. Diamond-Square Compile-Time Validation

Validate configuration where possible.

Example:

```zig
comptime {
    if (displacement_steps.len == 0) {
        @compileError(
            "Diamond-Square requires an initial displacement entry."
        );
    }
}
```

If a statically known target level requires more steps than provided:

```text
compile error
```

If the target depth is runtime-selected:

- return an error,
- or clamp explicitly if that behavior is desired.

Do not silently read beyond the provided configuration.

---

# 9. Explicit Step Counter

Implementation should keep one explicit configuration index.

Pseudo-code:

```zig
var step: usize = 0;

// Root values.
generateInitial(
    displacement_steps[step],
);
step += 1;

// Special first refinement.
squareStep(
    displacement_steps[step],
);
step += 1;

diamondStep(
    displacement_steps[step],
);
step += 1;

// Normal refinement.
while (needsMoreRefinement()) {
    diamondStep(
        displacement_steps[step],
    );
    step += 1;

    squareStep(
        displacement_steps[step],
    );
    step += 1;
}
```

Do not hide Diamond and Square under one "refinement level" amplitude.

---

# 10. Diamond-Square Hashing

Every new sample should obtain its random displacement from deterministic hashing.

Conceptually:

```zig
const local_seed = mixSeed(
    generator_seed,
    step_index,
);

const hash = hash2D(
    local_seed,
    global_x,
    global_z,
);

const random_offset = hashToSignedRange(
    hash,
    displacement_steps[step_index],
);
```

Using the step index in the hash prevents different algorithm passes at the same position from automatically receiving the same pseudo-random value.

---

# 11. Initial Diamond-Square Values

The first/root values should also be position-hashed.

Do not initialize the root corners from a sequential PRNG.

Conceptually:

```zig
const value = hashToSignedRange(
    hash2D(
        root_seed,
        global_x,
        global_z,
    ),
    displacement_steps[0],
);
```

This allows shared root samples between adjacent regions to match naturally.

---

# 12. Progressive Diamond-Square Refinement

Stop at the requested public ×4 spacing, caching both the completed public field and any internal ×2 dependencies. One public transition consists of two internal refinement pairs, as specified above.

A work budget may pause within an operation or internal pair. Track completion precisely and resume only missing work; an incomplete public level must not be exposed as a completed input to another strategy.

If the caller requests chunk-scale terrain, stop at spacing 256. Later requests may refine selected tiles through 64, 16, 4, and 1, using the configured strategy at each transition. Reuse existing parent samples and allocated storage throughout.

---

# 13. Additional Hierarchical Noises

The architecture should be designed so more hierarchical noises can be added.

The important ones currently worth considering are:

1. Hierarchical Value Noise
2. Midpoint / Recursive Displacement
3. Wavelet / Residual Multiresolution Noise
4. Hierarchical Voronoi / Worley
5. Recursive Spatial Subdivision Fields

Diamond-Square is only the first implementation.

---

# 14. Hierarchical Value Noise

Hierarchical Value Noise should preserve old grid samples while introducing new values between them.

Example in 1D:

```text
Level 0:

A---------------B

Level 1:

A-------C-------B

Level 2:

A---D---C---E---B
```

Old values stay unchanged.

New values may be generated from:

```text
interpolation of parents
+
deterministic hashed displacement
```

Example:

```zig
C =
    average(A, B)
    + randomOffset(seed, level, position);
```

In 2D:

```text
A-----------B
|           |
|           |
C-----------D
```

refines to:

```text
A-----E-----B
|     |     |
F-----G-----H
|     |     |
C-----I-----D
```

Possible rules:

```text
edge point
    average of two parent samples
    + displacement

center point
    bilinear/average parent estimate
    + displacement
```

This is similar in spirit to Diamond-Square but more generic.

---

# 15. Why Hierarchical Value Noise Is Useful

It is useful because it can be made:

- 1D,
- 2D,
- 3D,
- deterministic,
- random-access friendly,
- chunk friendly,
- easy to customize.

It can be used for more than height.

Examples:

```text
terrain height
temperature
humidity
continental strength
cave density
ore concentration
weather fields
biome weighting
```

It should likely be one of the first additional hierarchical noise implementations after Diamond-Square.

---

# 16. Midpoint / Recursive Displacement

Midpoint displacement recursively creates new points between existing values.

Simplified:

```text
A---------------B

A-------C-------B

A---D---C---E---B
```

Each midpoint is:

```text
parent interpolation
+
random displacement
```

This can be treated as a simpler family relative of Diamond-Square.

Possible uses:

- 1D terrain profiles,
- mountain ridge lines,
- paths,
- coastline control curves,
- hierarchical feature skeletons.

Do not prioritize it over Hierarchical Value Noise unless needed by a specific feature.

## 16.1 Implementation Plan

- [ ] Start with 1D scalar profiles and 2D X/Z feature polylines using the shared hashing and refinement infrastructure.
- [ ] Identify each root segment by a stable feature ID and canonical endpoint order. Identify descendants by their subdivision path and level so neighboring regions reconstruct the same segment.
- [ ] Insert each midpoint using parent interpolation plus a signed, deterministic hashed displacement. For polylines, define a consistent perpendicular direction from the canonical endpoint order.
- [ ] Configure maximum displacement independently for each level, with an explicit maximum depth or minimum segment scale. Do not require monotonically decreasing amplitudes.
- [ ] Retain endpoints and every previously generated midpoint unchanged. Cache the segment tree and generate only missing descendants when refinement resumes.
- [ ] Support regional requests by reconstructing required ancestors and selecting intersecting segments using bounds that include possible descendant displacement. Clip output only after generation so chunk boundaries do not change the result.
- [ ] Expose refined profiles or feature skeletons to later terrain stages, including mountain ridges and coastline curves. Keep rasterization separate from curve generation.

## 16.2 Acceptance Checks

- [ ] Direct fine generation matches coarse generation followed by refinement, including after cache eviction and reconstruction.
- [ ] Existing points remain bit-identical at every refinement level.
- [ ] Reversed endpoint input is canonicalized to the same geometry, and neighboring regional requests agree on shared segments.
- [ ] Zero displacement produces parent interpolation; unusual per-level amplitudes use the correct level.
- [ ] Negative coordinates, seed changes, and request order behave deterministically.
- [ ] Preview successive refinement levels with old points highlighted to reveal drift or boundary discontinuities.

---

# 17. Wavelet / Residual Multiresolution Noise

Wavelet-style generation represents the final field as multiple scales of detail.

Conceptually:

```text
field =
    coarse
    + detail_1
    + detail_2
    + detail_3
    + ...
```

A coarse LOD can evaluate only:

```text
coarse + detail_1
```

while a finer LOD includes:

```text
coarse
+ detail_1
+ detail_2
+ detail_3
...
```

Equivalent conceptual refinement:

```text
fine =
    upsample(coarse)
    + residual
```

This naturally fits progressive LOD.

However, it is more complex than Diamond-Square or Hierarchical Value Noise.

Implement later.

---

# 18. Hierarchical Voronoi / Worley

Hierarchical Voronoi should be considered mainly for large structural fields rather than generic smooth height.

Possible uses:

```text
biome regions
tectonic regions
geological zones
ore provinces
large cave regions
alien terrain cells
climate zones
```

Conceptually:

```text
large Voronoi regions
        ↓
sub-regions inside them
        ↓
smaller regions
        ↓
local detail
```

The parent/child relationship should remain deterministic.

This is especially useful when terrain features need meaningful regions rather than smooth random fields.

## 18.1 Implementation Plan

- [ ] Implement a 2D X/Z nested region generator first, using the common seed mixing, global coordinates, and optional hierarchical cache.
- [ ] Define root sites on a globally anchored lattice with bounded hashed jitter, stable site IDs, and deterministic tie-breaking by ID. Superchunks must not seed independent local diagrams.
- [ ] Find nearest sites using a search whose distance bounds prove that unexplored cells cannot win. Include sites outside the requested region so shared boundaries agree.
- [ ] Derive child site seeds and IDs from the parent ID, level, and child index. Specify a bounded child-placement procedure inside the parent region, including a deterministic fallback for thin regions.
- [ ] Subdivide each parent using its child sites, clipping child ownership to that parent. Preserve parent sites, IDs, boundaries, and attributes when adding children.
- [ ] Return the region ID path and inherited attributes, with optional level-specific nearest-site distances (`F1`, `F2`). Define these distances within the applicable sibling diagram; do not treat `F2 - F1` as an exact distance to the clipped region boundary.
- [ ] Configure root spacing, child count, maximum depth, and attribute variation by level. Stop at the requested hierarchy level and reuse cached parent regions when refining.
- [ ] Integrate region outputs as biome, geology, or tectonic masks in generation pipelines; defer 3D regions and domain warping until the 2D behavior is verified.

## 18.2 Refinement and Sample Stability

Keep coarse region membership and coarse sampled values immutable. Refinement adds a child ID and child attributes rather than replacing the parent result.

Nearest-site distances at different levels are separate fields: adding child sites does not preserve the parent's distances. Cache these outputs by level. If a terrain stage requires one scalar field whose old samples never change, use a separate interpolation/refinement stage that explicitly preserves those samples.

## 18.3 Acceptance Checks

- [ ] Direct fine generation and resumed refinement produce identical region paths and attributes.
- [ ] Child regions remain inside their parent and cover it without gaps; parent ownership stays unchanged after refinement.
- [ ] Neighboring Superchunks agree on site IDs, ownership, and distances at shared sample positions, including negative coordinates.
- [ ] Equidistant sites use the same tie-breaking rule regardless of traversal or request order.
- [ ] Cache eviction and reconstruction reproduce the same sites and region hierarchy.
- [ ] Verify nearest-site search against an exhaustive reference over bounded fixtures, including queries near region edges.
- [ ] Preview parent and child region colors, site positions, and Superchunk borders at successive levels.

---

# 19. Recursive Spatial Subdivision Fields

A general subdivision generator may recursively divide a region:

```text
region
  ↓
4 children in 2D
  ↓
each child subdivides
  ↓
...
```

Each child can inherit parent data and apply deterministic modifications.

Possible uses:

- regional terrain parameters,
- density fields,
- procedural feature placement,
- biome hierarchy,
- world simulation regions.

This is a general framework rather than one specific noise.

---

# 20. Standard Non-Hierarchical Noises Still Matter

Hierarchical noises are not intended to replace all existing noise algorithms.

Existing algorithms such as:

```text
Perlin
Value Noise
Voronoi
Domain-Warped Voronoi
Ridged Noise
FBM
```

remain useful.

They can be used as later stages or modifiers.

Example:

```text
hierarchical coarse terrain
        ↓
mountain mask
        ↓
ridged noise detail
        ↓
domain warp
        ↓
local surface noise
```

The hierarchical system mainly solves:

```text
progressive resolution
+
reuse of coarse generation
```

It does not need to solve every terrain-generation problem itself.

---

# 21. Combining Multiple Noises

A planet/world generator should eventually be able to define pipelines such as:

```text
continental field
      ↓
tectonic regions
      ↓
mountain range generator
      ↓
river generator
      ↓
climate
      ↓
biomes
      ↓
local terrain
      ↓
caves
      ↓
ores
      ↓
surface detail
```

Different stages may use different noise types.

Example:

```text
continents
    Hierarchical Value Noise

mountain macro-shape
    Diamond-Square

tectonic regions
    Hierarchical Voronoi

mountain surface
    Ridged Noise

rivers
    Domain-Warped Voronoi / custom river generation

small terrain detail
    Perlin / Value Noise
```

---

# 22. Different Planet Pipelines

The generation system must not assume one universal terrain pipeline.

Different planet types should be able to use different pipelines.

Example:

```text
Earth-like:

continents
tectonics
mountains
rivers
temperature
humidity
biomes
caves
ores
surface detail
```

Example:

```text
Desert planet:

large flat base
rock regions
dune fields
canyons
dry river beds
ore regions
sparse structures
```

Sparse structure placement is planned in [Sparse Structure Generation](sparse_structure_generation.md).

Example:

```text
Alien planet:

cellular regions
warped terrain
floating formations
crystal zones
unusual caves
custom density generators
```

The hierarchical noise infrastructure should be reusable by all of them.

---

# 23. Large Mountain Ranges

Large mountain ranges should not be generated only from high-frequency local noise.

Their macro structure should exist at coarse hierarchical levels.

Possible pipeline:

```text
coarse mountain-region field
        ↓
mountain ridge / skeleton
        ↓
broad elevation around ridge
        ↓
hierarchical refinement
        ↓
secondary ridges
        ↓
local ridged detail
```

This means a mountain visible at long distance already exists in coarse generation.

Approaching the mountain should reveal additional detail rather than completely changing its position.

---

# 24. Mountain Ridge Hierarchy

A range may be represented as:

```text
Level 0
    large mountain belt

Level 1
    main ridge direction

Level 2
    ridge displacement

Level 3
    secondary ridges

Level 4
    valleys and passes

Fine levels
    rock / cliff detail
```

Hierarchical Value Noise or midpoint displacement may be useful for ridge refinement.

Diamond-Square may be useful for broad elevation.

Ridged noise may be added at finer levels.

---

# 25. First Implementation Priorities

Implement in roughly this order:

First implement the prerequisites in [Hierarchical Generation Core](hierarchical_generation_core.md).

## 25.1 Diamond-Square core

Implement:

- root sample generation,
- Square pass,
- Diamond pass,
- deterministic hash displacement,
- arbitrary refinement depth.

---

## 25.2 Special first pass

Implement:

```text
Square
Diamond
```

for the first refinement only.

Verify neighboring Superchunks generate identical shared edge samples.

---

## 25.3 Compile-time displacement array

Implement the exact semantics:

```text
[0] root/initial hash max

[1] first Square
[2] first Diamond

[3] second Diamond
[4] second Square

[5] third Diamond
[6] third Square

...
```

Diamond and Square must be independently configurable.

---

## 25.4 Progressive stopping

Allow Diamond-Square to stop at a requested resolution.

Verify that continuing refinement later does not modify existing values.

---

# 26. Tests

Add deterministic tests.

Run the shared hashing checks in [Hierarchical Generation Core](hierarchical_generation_core.md), then verify the terrain implementation below.

## Superchunk edge tests

Generate:

```text
Superchunk (0, 0)
Superchunk (1, 0)
```

Compare their shared boundary.

Every shared sample must be bit-identical.

Repeat for:

```text
left/right
top/bottom
negative coordinates
```

---

## Progressive generation tests

Generate a Superchunk only to coarse resolution.

Store all generated samples.

Then refine further.

Verify:

```text
every previously generated sample remains unchanged
```

---

## Regeneration tests

Generate the same Superchunk twice from scratch.

Outputs must match exactly.

---

## Step-amplitude tests

Use deliberately unusual displacement arrays to verify each individual Square/Diamond pass uses the correct index.

Example:

```zig
const test_steps = [_]i32{
    0,
    100,
    0,
    200,
    0,
    400,
    0,
};
```

This makes it easy to detect if the wrong step uses the wrong amplitude.

---

# 27. Debug Visualization

Provide a simple debug output for hierarchical noise development.

Useful options:

```text
PGM
PNG
raw grayscale
```

It should be possible to export:

```text
root/coarse field
after first Square
after first Diamond
after each later Diamond
after each later Square
```

This will make it easier to verify:

- edge alignment,
- progressive refinement,
- displacement behavior,
- artifacts,
- terrain character.

---

# 28. Future Hierarchical Noise Priorities

Suggested implementation order after Diamond-Square:

```text
1. Hierarchical Value Noise

2. Hierarchical / Nested Voronoi

3. Midpoint / Recursive Displacement

4. Wavelet / Residual Multiresolution Noise
```

Reasoning:

```text
Hierarchical Value Noise
    general purpose
    simple
    useful in 2D and 3D

Hierarchical Voronoi
    useful for regions/biomes/geology

Midpoint Displacement
    useful for feature skeletons / ridges

Wavelet
    powerful multiresolution representation
    but more complex
```

---

# 29. Non-Goals for the First Pass

Do NOT try to implement all of the following immediately:

- full planet generation,
- every hierarchical noise type,
- runtime Megachunks,
- GPU terrain generation,
- final LOD renderer,
- erosion simulation,
- complete biome generation,
- full cave generation,
- networking representation.

Build on the hashing, 2D procedural Superchunk, and progressive storage specified in [Hierarchical Generation Core](hierarchical_generation_core.md).

Focus on:

```text
Diamond-Square
+
first Square-Diamond pass
+
per-operation compile-time displacement control
```

---

# 30. Summary of Critical Rules

Apply the shared hierarchy, sample stability, and hashing rules in [Hierarchical Generation Core](hierarchical_generation_core.md).

Diamond-Square begins:

```text
Initial values

Square
Diamond
```

then continues:

```text
Diamond
Square

Diamond
Square

...
```

Diamond-Square displacement configuration is a compile-time array.

Its indexing is:

```text
0 = initial/root hash maximum

1 = first Square
2 = first Diamond

3 = second Diamond
4 = second Square

5 = third Diamond
6 = third Square

...
```

Every Diamond and Square step has its own independent configurable maximum displacement.

Do not force a simple roughness multiplier.

Do not force monotonically decreasing amplitudes.

Allow unusual terrain-generation profiles.

Design the infrastructure so other hierarchical algorithms can later use the same general world-generation system.
