# View-based block rotation

Status: implemented; application build, unit tests, exporter regression test,
and headless GPU tests pass on both shader profiles.

Implemented behavior: choose orientation from the player's viewing direction when
placing a block, then keep that orientation. Start with horizontal quarter turns.
Continuous camera-facing rotation and vertical placement modes are separate scope
decisions.

## Descriptor setting and behavior

Add an optional `rotation` attribute to `.block` descriptors:

```text
name: Directional Block
model: directional.vox
rotation: yaw
```

| Value | Placement behavior |
| --- | --- |
| `none` | Keep the model's authored orientation. Default when omitted. |
| `yaw` | Choose one of four orientations around world Y from the camera heading. |

Use an enum rather than a boolean so future modes can be added explicitly. Keep
existing descriptors valid, accept this attribute for supported formats 1 and 2,
and retain the encoder's current format-2 output. Unknown values and duplicate
attributes must fail with a clear error.

Facing convention: engine-local +Z is the model's front, +Y is up, and
the front faces toward the player (opposite the horizontal look direction).
This convention applies after the existing VOX coordinate conversion. Check an
asymmetric asset before enabling the setting on existing blocks.

Quantize the horizontal view direction to the nearest cardinal axis. Resolve
exact X/Z ties in favor of Z. If its horizontal length is nearly zero, derive the
direction from the camera yaw, so looking straight up or down remains stable.
Use the view direction at the accepted placement click. The hit normal continues
to choose the adjacent destination cell; it does not choose rotation in `yaw` mode.

## Implementation approach

The registry stores a canonical model. `main.zig` passes it and the selected
orientation to `World.setBlockOriented`, which clones and rotates its voxels into
the world. CPU raycasts, voxel removal, shadows, and GPU uploads consume the same
rotated occupancy and palette indices.

- [x] Add a shared rotation-mode type and pure orientation-selection helpers in
  `src/world/blockRotation.zig`.
- [x] Extend `Metadata`, parsing, and encoding in `src/world/blockLoader.zig`.
  Store the mode on `Definition` in `src/world/blockRegistry.zig`; keep model IDs
  and inventory variants independent of orientation.
- [x] Implement a rotated clone operation for `Block`. For side length N, the
  four index mappings are `(x,y,z)`, `(z,y,N-1-x)`,
  `(N-1-x,y,N-1-z)`, and `(N-1-z,y,x)`. These map the authored +Z front to
  +Z, +X, -Z, and -X respectively. Rebuild occupancy and indices in a separate
  destination buffer, preserve palette/material bytes and block ID, preserve
  occupied-voxel count, and mark rotated voxel data dirty. Free and mono geometry
  need no voxel permutation.
- [x] Rotate an attached point light using the same transform about the physical
  block center `(N/2, N/2, N/2)`. Light positions are continuous coordinates:
  the +X-facing transform is `(z,y,N-x)`, whereas voxel indices use `N-1-x`.
  Preserve light radius, color, and intensity, including for mono blocks with lights.
- [x] Add `World.setBlockOriented(coord, model, orientation)` and keep
  `setBlock` as an identity-orientation wrapper. Clone/rotate once before committing
  through the existing chunk expansion and dirty-tracking path. Keep allocation
  cleanup and source-model independence intact.
- [x] In the existing placement branch in `src/main.zig`, resolve the selected
  definition's mode and camera heading, then pass the chosen orientation to the
  world. Preserve the cooldown, empty-cell check, camera-cell exclusion, and
  unloaded-chunk restriction.
- [x] Keep edited geometry in its baked orientation. Voxel removal must not apply
  rotation again. Reuse existing lighting invalidation and streamed-region rebuilds.

The stored voxel data represents orientation for this first implementation; no
new GPU header field or shader transform is required. A future save format that
stores model IDs instead of complete voxel data will need explicit orientation
and edit data. Current world edits remain in memory and are not saved between runs.

## Assets and documentation

- [x] Document `rotation` and the facing convention in `README.md`, with a
  four-direction placement example.
- [x] Enable `yaw` on a deliberately chosen asymmetric sample and inspect it.
  Shipassets Handle is enabled: its base is on -Z and the grip projects toward
  +Z. Other descriptors retain their defaults.
- [x] Update `utils/export_blocks.py` so re-exporting a model preserves an
  existing descriptor's `rotation` setting. It currently rewrites descriptors.
- [x] Keep inventory icons in the authored orientation. A placement ghost can
  reuse the orientation helper if a preview is added later.

## Validation and acceptance

- [x] Test omitted/valid/invalid/duplicate metadata and encode/decode round trips;
  verify registry loading retains the mode and legacy descriptors still load.
- [x] Test all cardinal directions, diagonal boundaries, and near-vertical views.
- [x] Use an asymmetric multi-material voxel fixture to verify all four rotations,
  exact occupancy, preserved palette indices/counts, unchanged source geometry,
  and restoration after four successive quarter turns.
- [x] Verify off-center light rotation, including a light at a voxel center, and
  verify clone allocation failures do not leak.
- [x] Place rotated blocks at positive and negative world coordinates and chunk
  boundaries. Check ray hits and single-voxel removal against expected geometry;
  verify other placements and the registry model remain unchanged.
- [x] Verify packed GPU occupancy/indices and light positions match the CPU copy.
- [x] Verify orientation survives leaving and reentering the streamed region.
- [x] Run `zig build test` and build the application.
- [x] Run `python3 -m unittest discover -s utils -p 'test_export_blocks.py'`.
- [x] Run `zig build test-render`, including all four placement orientations.
- [ ] Optional interactive check: place Shipassets Handle from four sides and
  inspect its facing, lighting, shadows, and removal behavior. Automated coverage
  uses an asymmetric emitter fixture; no interactive session has been run.

Deliver in order: descriptor support and selection helpers, rotated-copy/world
integration, then sample asset/export handling and end-to-end validation.

## Possible extension

If looking up/down should also orient blocks, add a separate `rotation: facing`
mode with six cardinal front directions. Specify deterministic roll for vertical
directions before implementing it. Arbitrary angles require voxel resampling or
transformed traversal and are outside this quarter-turn design.
