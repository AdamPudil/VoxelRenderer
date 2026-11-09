# Incremental GPU terrain streaming

Status: proposed, 2026-11-07. Follow-up to
[Procedural Terrain Rings](procedural_terrain_rings.md) and the
[shader performance investigation](rtx3060_shader_performance.md).
This plan changes GPU residency and publication, not the terrain algorithm,
render distance, lighting quality, or generation demand policy.

## 1. Intended result

Keep unchanged terrain and authored edit payloads resident on the GPU. A new
coverage request uploads only missing or changed payloads, plus publication
metadata. Turning without changing demand and standing still must upload nothing.
Movement may change refinement throughout the rings, not just at the window edge;
those changed tiles legitimately need replacement.

Keep the current complete-window publication contract: rays see either the old
balanced coverage or the complete new coverage. Incremental transfers do not
require exposing individual tile replacements before their neighbors are ready.
Preserve edits, point lights, glass, picking availability, and all secondary rays.

The observed 20–22 FPS while moving is motivation, not evidence that uploads are
the dominant bottleneck. Measure CPU publication cost and GPU draw time separately.

## 2. Current cost and reusable structure

`terrainStreaming.zig` reuses immutable, reference-counted `terrainHierarchy.Tile`
storage. However, `World.beginTerrainBuild()` clears the packed pools, and
`advanceTerrainBuild()` copies every tile and rebuilds edit descriptors.
`advanceUpload()` allocates replacement storage for six buffers and transfers
the complete snapshot before swapping all buffers, origin and block lights.

The worker can therefore reuse 954 of 1024 tiles, as recorded in the terrain
plan, while the renderer still repacks and transfers the whole geometry snapshot.
That tile count does not imply a particular byte saving: tiles differ in size.

Terrain nodes already store child indices relative to their tile root. A tile's
node bytes can stay unchanged at a stable index-buffer offset. Chunk headers
select that root and optionally an authored edit overlay. The shader need not
gain another indirection for the first implementation.

## 3. Residency and identity

Introduce `src/graphics/worldResidency.zig` for resident records, bounded arena
allocators, upload transactions and retirement. Keep world demand/edit ownership
in `world.zig`, and all OpenGL operations on the context-owning main thread.

| Resident object | Identity and replacement unit | GPU representation |
| --- | --- | --- |
| Terrain tile | World X/Z, generator configuration revision, immutable payload ID | Contiguous node allocation in the index pool, shared by vertical chunk headers |
| Edited voxel block | World block coordinate and edit version | Voxel header, bitmap, palette, indices and summaries |
| Chunk edit overlay | World chunk coordinate and overlay version | Contiguous 4096-entry block-header table pointing to retained or new blocks |
| Published coverage | Request/configuration/edit versions and region origin | Chunk-header table plus references to all reachable allocations and lights |

Add a stable payload ID to owned tile storage, assigned when new immutable
storage is created and preserved by `retain()`. Current `Tile.revision` alone is
insufficient to identify distinct LOD payloads. Do not key reuse by request token
or window slot: reused tiles survive new requests and shifts of the window.
Coordinate plus LOD level alone is also insufficient to identify a whole tree.
Avoid raw pointer keys unless ownership prevents address reuse throughout lookup.

Track per-block edit versions independently of the global transaction edit
revision. An edit invalidates its block payload and containing overlay table,
not the unchanged terrain underneath or other blocks' payloads. Explicitly
edited air stays distinguishable from an absent override.

Published, pending and retained records own their dependencies. Pin CPU tile
storage while uploads reference its bytes; replacing `stream.resident` currently
releases the previous batch, so borrowed slices from that batch are not sufficient.

## 4. Stable arenas and packing

Keep the existing buffer-texture formats and binding layout initially. Replace
per-snapshot pool recreation with persistent allocations in five payload arenas:
block headers, voxel headers, occupancy bitmaps, palettes and the shared index
pool. Chunk headers remain a separate publication resource.

Use aligned free ranges with coalescing and allocation-generation handles.
Allocation and packing are transactional: reserve every range needed by an object
before exposing it; roll back partial reservations on failure. Range handles carry
the pool, base, length and generation so stale handles cannot free reused storage.

Adapt packers to produce local payloads and relocate references into reserved
arena ranges. Document reference units explicitly: header indices, word offsets,
and existing offset-plus-one sentinels differ. Terrain child indices remain local;
only the root base changes. Keep terrain nodes aligned to four words. Validate
all cross-pool pointers, shader signed-index limits and texture-buffer limits.

First version replaces a whole changed terrain tile. A single edited voxel
replaces its containing voxel-block payload and chunk overlay table, retaining
other block payloads. A 4096-entry overlay table is 64 KiB at the current ABI;
this is an explicit bounded metadata cost, not an entire-world repack.
Subtree deltas and sparse overlay tables are later optimizations if measured need
justifies their additional addressing and ownership complexity.

## 5. Incremental transfer, atomic publication

1. Accept a complete balanced worker batch; capture request token, configuration
   revision, edit revision and the target region origin.
2. Diff its object identities against resident records by world coordinates.
   Retain unchanged allocations; queue only missing payloads and changed overlays.
3. Pack/upload changed data into newly reserved ranges under the existing 2 ms
   CPU slice and 8 MiB/frame transfer budget. Account metadata transfers too.
   Never overwrite payload bytes referenced by a published or in-flight draw.
4. Assemble an inactive chunk-header table referencing both reused and new data.
   Build the matching block-light set from retained per-chunk light records and
   changed records, rather than rediscovering every block's lights.
5. Check versions before each transfer slice, including a zero-budget slice,
   and again immediately before publication. An obsolete transaction cannot publish.
6. After every dependency's transfer is submitted, bind the new header table,
   origin and light set together at the frame boundary before any consumer.
   Same-context command ordering keeps uploads before the draw; do not add a
   blocking CPU wait for upload completion just to publish.
7. Retire allocations no longer referenced by any published, pending or retained
   coverage only after the last GPU work using them has completed.

Start with two chunk-header tables and rebuild/upload the whole inactive table
once per publication. At 32×16×32 chunks and 16 bytes/header, this is 256 KiB.
This small full metadata upload is deliberate; the large payloads are incremental.
No unchanged frame uploads the table. If metadata later matters, add patches
against each physical table's own version—never assume both copies contain the
previous published state.

Reuse an inactive table only once its previous readers have completed. With
both tables busy, defer publication while retaining current coverage. Include a
vertical region-origin change even when the horizontal terrain demand is unchanged.
Window slots change meaning on movement; rebuild the mapping without relocating
the retained world-coordinate payloads. Removed regions disappear through the
new mapping, not through clearing shared payload memory.

## 6. GPU lifetime, cancellation and bounded memory

Add a frame-lifetime hook after the last geometry consumer, including GI update
and any other world-reading passes. Associate published generations with GL
completion fences; poll without waiting and reclaim retired ranges only when
their last-use fence is signaled. Do not use per-frame `glFinish()` or fixed
frame-count delays as a substitute for completion tracking.

Cancelled transactions release CPU references and unsubmitted reservations.
Ranges with uploads already submitted must also wait for those writes to finish
before reuse. Cancellation must not free allocations shared with current coverage.
Maintain explicit published, pending, cached and retired reference ownership.

Set configurable hard caps for total GPU arena capacity, CPU staging bytes,
pending upload bytes and retained cache bytes. Choose initial capacities from
measured packed workloads and validate room for published data plus a replacement
and retirement overhead. Count allocation capacity, fragmentation and old/new
storage during migration, not just live payload bytes.

Evict unreferenced cached payloads first; otherwise defer and report pressure.
Never evict visible data or discard unsaved CPU edits to satisfy an upload.
Limit the system to one current pending transaction and bounded retirement records.
Distinguish temporary fence pressure from a transaction that cannot fit at all;
report the latter explicitly rather than silently retrying forever.

Avoid `glBufferData` on active arenas during routine movement. Arena growth or
compaction is an exceptional, separately budgeted migration retaining old storage
until publication and fence completion; keep it out of normal walking. The first
release may use fixed capacities and explicit capacity errors instead. Ordinary
buffer subrange uploads may still incur driver overhead, so preserve timing
instrumentation and coalesce adjacent transfers without copying unchanged payloads.

## 7. Lighting, compatibility and scope

Publish lamp additions, removal and rotation with their geometry. Keep the
existing global `gpu_revision` lighting/GI invalidation on actual publication
initially. Reusing geometry memory alone does not prove cached illumination is
valid: a distant changed occluder can affect an unchanged face. Regional lighting
invalidation requires dependency tracking and is a separate follow-up.

Retain the whole-snapshot backend as an explicit startup A/B option during rollout.
Do not silently switch backends mid-frame. Apply incremental residency to terrain
and its authored edit overlays first; the standalone test scene and icon producer
can keep their existing upload paths. Both shader profiles must read the same
material/hierarchy ABI. CPU collision, picking and canonical-data readiness retain
their existing ownership and availability rules.

## 8. Implementation sequence

- [ ] **Baseline and diagnostics.** Add asynchronous GPU timings for world draw
  and GI, CPU timings for diff/packing/upload submission, and counters separating
  uploaded payload, metadata, reused bytes, retired bytes and allocated capacity.
- [ ] **Identity and allocator model.** Add stable tile IDs, edit/overlay versions,
  resident dependency ownership and pure CPU range-allocation tests. Add a dry-run
  diff that reports expected upload bytes while the old backend still renders.
- [ ] **Terrain residency.** Upload only new node arrays, retain unchanged roots,
  publish through inactive header tables, and integrate frame-completion fences.
- [ ] **Edited blocks and lights.** Relocate authored payloads into stable arenas,
  replace only changed block/overlay objects, and publish matching light records.
- [ ] **Lifecycle and limits.** Finish cancellation, zero-budget handling,
  reclamation, capacity backpressure, shutdown and allocation-failure recovery.
- [ ] **Integration and validation.** Run reference-image and streaming stress
  checks with both backends. Enable incremental terrain by default after correctness
  and workload measurements, retaining the reference option for diagnosis.

Likely integration points: `world.zig` packing/upload state and statistics;
`terrainHierarchy.zig` storage identity; `terrainStreaming.zig` retained payload
ownership; `main.zig` frame-completion hooks; `rendering.zig` budgets; and
`hierarchyRenderChecks.zig` publication/streaming regression tests.

## 9. Acceptance checks

- Stationary unchanged terrain: zero packed payload bytes, upload bytes and
  publications after settling. Camera rotation with unchanged demand does the same.
- Small movement: retained tiles keep identical GPU roots; uploaded node bytes
  equal the sum of missing/replaced tile payloads, independently of total residency.
- Window movement in X, Y and Z, including negative coordinates: retained payloads
  keep their addresses while headers map to the correct world coordinates.
- One block edit: no terrain-node reupload; unchanged block payloads retain their
  addresses. Explicit air, glass, rotations, lamps and removal match the reference.
- Partial uploads and delayed fences: every draw sees a complete old or new
  coverage, and no live range or in-use header table is overwritten/recycled.
- Cancellation after each transfer phase, including zero budget and a final
  pre-publication edit: no stale geometry/light publication or leaked ownership.
- Reversal, teleport, generator revision change and memory pressure: valid old
  coverage survives; retirement is bounded and allocation failures are recoverable.
- Long traversal/revisit: stable total memory bounds, reuse within retained cache,
  and no monotonically growing abandoned allocations or retirement queues.
- For identical published coverage, compare hit positions, shadows and rendered
  materials against the whole-snapshot backend on both shader profiles. Include
  LOD boundaries, thin authored geometry, glass/reflections and GI consumers.

Use existing `zig build test`, `test-generation`, `test-hierarchy`, `test-render`
and normal build checks; extend their allocator/publication cases rather than
creating a separate rendering harness. Emulate unsignaled fences in allocator
tests as well as exercising actual GL fences. No full numerical terrain stress
suite is required unless the generation algorithm changes.

For performance, repeat fixed-seed paths in an optimized build at identical
resolution and lighting: settled rotation, walking within a chunk, chunk crossings,
reversal and teleport. Record median/p95/p99 frame time, CPU repacking/submission,
GPU world/GI time, transferred bytes and memory high-water marks. Separate initial
loading from steady movement. Accept byte-volume improvements by exact counters;
claim RTX 3060 frame-time gains only from measurements on that GPU. Persistent
slow horizon views after streaming settles remain a shader-traversal problem.
