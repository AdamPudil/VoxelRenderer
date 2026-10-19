# Hierarchical generation

`noises/diamondSquare.zig` provides a stateful `DiamondSquare(comptime amplitudes)`
structure. It owns the generated samples and resumes refinement without changing
existing values. `superchunk.zig` contains the shared region, rectangle, and result
types; it is separate from runtime world storage.

A superchunk covers 16×16 chunks in X/Z, or 4096×4096 voxels. The generation
structure includes boundary samples at **0 through 4096 inclusive**. Results cover
**0 through 4095** at voxel spacing. The 4096 row/column is support for generation,
not an extra row/column of returned terrain. Root corners are on the geometric
boundary, never clamped to 4095 or placed randomly inside the region.

Internally, each level retains a small additional border for parent dependencies.
These samples are evaluated in global coordinates, so an edge uses the same
neighbor values regardless of which superchunk is generated first. No neighboring
runtime chunks need to be loaded. Negative coordinates use floor/modulo lattice
rules. Existing `Position2.y` fields represent Z in this horizontal API.

```zig
const DiamondSquare = @import("noises/diamondSquare.zig").DiamondSquare;
const Noise = DiamondSquare(&.{
    4096, // Root amplitude.
    1800, 1200, // First Square, Diamond.
    800, 650, // Second Diamond, Square.
    400, 300,
    180, 120, // Chunk spacing (256).
    80, 50,
    30, 20,
    10, 6,
    3, 1, // Block spacing (16).
    4, 2,
    1, 0,
    2, 1,
    1, 0, // Voxel spacing (1).
});

var generator = try Noise.init(allocator, .{
    .position = .{ .x = .{ .superchunk = -1 }, .y = .{ .superchunk = 2 } },
    .seed = 123,
});
defer generator.deinit();

try generator.refineTo(256);
// Later, refine the same cache further.
try generator.refineTo(16);

var whole = try generator.result(allocator, 16);
defer whole.deinit();

// Local chunk (3, 5), sampled every 16 voxels: 16×16 samples.
var chunk = try generator.resultChunk(allocator, 3, 5, 16);
defer chunk.deinit();

// A 2×3 rectangle of chunks.
var chunks = try generator.resultChunks(allocator, .{
    .x = 3, .z = 5, .width = 2, .height = 3,
}, 16);
defer chunks.deinit();

// A rectangle specified in local voxel coordinates.
var area = try generator.resultArea(allocator, .{
    .x = 32, .z = 48, .width = 64, .height = 32,
}, 16);
defer area.deinit();

const edge = generator.sample(4096, 2048); // ?i32; generation-only boundary.
_ = edge;
```

Results are independently owned row-major `i32` arrays with width, height, global
voxel origin, and sample spacing. Origins/extents must align to the requested
spacing. Empty, out-of-bounds, or unaligned requests return errors. Chunk indices
are local 0–15. Extracting an area currently refines the complete superchunk cache
if necessary, then copies only the requested samples. These dense extraction methods refine the complete cache. For selective
refinement, use `Noise.Sparse` as described below. A coarser request after
refinement reuses existing samples.

`advance()` executes one individual pass; `grid()` provides a diagnostic view,
including internal support samples. In a partial pass, `Grid.sample()` returns
null for not-yet-generated points. Treat views as read-only and reacquire them
after refinement; owned results remain valid independently of the generator.
`Grid.writePgm()` can export each pass, while `Result.writePgm()` exports a crop.
Use the same grayscale range for neighboring images.

Amplitudes are nonnegative compile-time `i32` values, with one root entry followed
by individual passes (up to 25 entries). Their sum must fit in `i32`; averaging
uses `i64` intermediates and truncates toward zero. Every pass uses its own seed
mixed with the pass index. Arbitrary amplitude curves, including increases and
zeros, are supported. `refineToComptime()` diagnoses statically unsupported
resolutions; `refineTo()` reports unsupported runtime requests as errors.

Position hashing lives in `../position.zig`: `hash1D/2D/3D`, `mixSeed`, range
helpers, each position's `.hash(seed)`, and `hashPosition(seed, position)`. Typed
hashes distinguish chunk/block/voxel/superchunk units and dimensions, and combine
numeric coordinates rather than struct bytes. Raw coordinate hashes do not add a
unit domain. Range helpers use inclusive bounds; integer modulo reduction has a
small bias for ranges whose width does not divide 2^64. These hashes are for
procedural generation, not cryptography.

## Validation and previews

```sh
zig build test-generation
zig build test-generation-full
zig build generation-preview -- testOut/hierarchical 1 1
zig build generation-preview -- testOut/hierarchical 1 3
```

The regular suite tests all 256 chunk extractions, rectangular crops, all shared
boundaries of a 3×3 neighborhood, negative coordinates, progressive reuse,
regeneration, separate pass amplitudes against a recursive reference, invalid
requests, allocation failures, and PGM output. It is included in `zig build test`.

The separate full-resolution suite generates each of the nine superchunks at
voxel spacing, extracts all 256 chunks from each, compares every shared boundary
sample, and checks the 4096×4096 whole-area crop. It uses ReleaseSafe and processes
one superchunk at a time to bound peak memory.

The preview command writes a colored terrain PNG and a grayscale height-map PNG
per run. By default it generates the center
superchunk at one pixel per voxel: `overview_1x1.png` at 4096×4096. To generate a
3×3 superchunk mosaic, use the third argument `3`: `overview_3x3.png` at
12288×12288. The arguments are output directory, voxel spacing (default 1), and
superchunks per side (1 or 3, default 1). Larger power-of-two voxel spacing can
still be used for a smaller preview. Each size has separate filenames.

`heightmap_1x1.png` and `heightmap_3x3.png` match their terrain images pixel for
pixel. They contain 8-bit grayscale elevations, including underwater terrain,
with no coloring, lighting, or sea-level clipping. The minimum elevation maps to
black and the maximum to white using one scale for the entire image. These PNGs are normalized visual exports,
not lossless copies of the generator's signed i32 values.

The command uses the project logger to print generation time per superchunk and
a plain heading followed by a simple section with naive (uniform full-area) generation time,
average time per chunk, and chunk count. Output goes to both the terminal and
`logs/generation_preview.log`, overwritten on each run. The requested voxel
spacing is shown in the log. Timings use a monotonic clock and exclude image
preparation, PNG exports, and compilation.

The terrain palette shows ocean depths, beaches, green lowlands, rocky mountains,
snow, and slope lighting. No individual-tile or per-pass files are emitted.
Coloring uses one elevation range for each image, and lighting samples across
tile boundaries. The rougher displacement profile and palette are preview
choices, not a required terrain preset. The generator's PGM methods remain
available for explicit pass-level debugging.

## Circular mixed-detail preview

```sh
zig build generation-lod-preview
# Optional output directory:
zig build generation-lod-preview -- testOut/hierarchical
```

This adds `overview_lod.png` and `heightmap_lod.png`, both 4096×4096, without
changing the existing uniform-resolution exports. It covers one superchunk,
centered at local voxel (2048, 2048):

- Chunk spacing (256 voxels) over the whole area.
- Block spacing (16 voxels) inside a circle with radius 6 chunks / 1536 voxels
  and diameter 12 chunks.
- Voxel spacing (1 voxel) inside a circle with radius 3 chunks / 768 voxels
  and diameter 6 chunks.

The image repeats coarse cells at display resolution so the resolution changes
are visible; it does not generate a full voxel-resolution field and downsample
it. Circle membership is tested at parent-cell centers: whole chunks are selected
for block detail, and whole blocks for voxel detail. This gives the outer circle
a 256-voxel stepped outline and the inner circle a 16-voxel stepped outline.
Membership is identical throughout each parent; no circle cuts through its
children. The radii remain 6 and 3 chunks, with symmetric grid-aligned boundaries.
Generation tests each parent once, then generates its children in rectangular
loops. Image assembly fills coarse cells in batches with one lookup per cell,
and only reads individual voxels inside selected fine blocks. Interpolation
dependencies can require extra support samples outside a requested circle. The reported counts include these
samples. No fine samples are generated during image assembly.

`DiamondSquare(...).Sparse` owns a dense coarse base and a coordinate-keyed cache
of finer samples. It evaluates the same root, Square, and Diamond rules on demand,
including the reversed first pair. Its results match full refinement exactly.
The original `refineCircle()` is also available for precise circular requests.
Each coordinate is cached once, independent of hierarchy level. Repeated requests
reuse the cache; refining a circle never promotes the entire base to finer spacing.

```zig
var sparse = try Noise.Sparse.init(allocator, superchunk, 256);
defer sparse.deinit();
const layout = @import("superchunk.zig").CircularLod{};
try sparse.refineParentCircle(layout.blockCircle(), 16, 256);
try sparse.refineParentCircle(layout.voxelCircle(), 1, 16);

// No generation: returns null if this sample has not been requested or needed.
const cached = sparse.sampleCached(2049, 2049);
_ = cached;
// Generate an individual aligned sample and its dependencies if needed.
const height = try sparse.sampleAt(2049, 2049, 1);
_ = height;
```

The preview uses the project logger for both terminal output and
`logs/generation_lod.log`, overwritten on each run. All preview output is plain text, without timestamps or severity tags. Reports use
`-==TestName==-` headings, `[Type]` sections, and tab-indented `Name - value [unit]`
lines via `printBoth()`, without table borders or repeated severity tags. The LOD command also benchmarks naive generation of the same
seed and superchunk at full voxel detail, using the dense generator and extracting
its whole-area result. This baseline does not prepare or export additional images.
Both methods use the same noise algorithm; "naive" means uniform full-area detail,
while "hierarchical" means selective LOD refinement.

The naive section shows total generation milliseconds, average milliseconds per
chunk, and chunk count. The hierarchical sections show those metrics per detail
stage and for the complete superchunk. Its refinement counts overlap: 256 chunks
receive coarse data, 112 receive block refinement, and 36 contain voxel refinement.
Stage averages divide incremental stage time by the affected chunk count and
include support generation. The total average divides total generation time by
256 unique chunks.

A separate final-count metric classifies each chunk by its finest requested detail:
144 coarse, 76 block, and 36 voxel chunks, totaling 256. Voxel edge chunks can still
contain blocks at block detail. Final counts describe the output distribution;
they are not the denominators for stage averages because the stages reuse earlier
work. All reported timings exclude image preparation, exports, compilation, and
report writing. The sparse hash map favors simple selective generation over the
dense generator's sequential throughput; fewer samples do not necessarily mean
less generation time.
