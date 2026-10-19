# Sparse Structure Generation

## Status

Initial plan for deterministic placement and generation of sparse world structures.

Use the world hierarchy, position hashing, seed mixing, and generation regions defined in [Hierarchical Generation Core](hierarchical_generation_core.md). Read terrain fields from [Hierarchical Terrain Generation](hierarchical_terrain_generation.md) when evaluating placement.

## Placement

- [ ] Define structure types, placement rules, and planet-specific configuration.
- [ ] Derive candidate positions and stable structure IDs from the world seed and global coordinates.
- [ ] Configure density, minimum spacing, and terrain suitability for each structure type.
- [ ] Resolve overlapping candidates deterministically, independently of chunk generation order.
- [ ] Evaluate nearby candidates outside the requested region when they can affect placement inside it.

## Generation and streaming

- [ ] Define structure bounds and a canonical owning generation region.
- [ ] Support structures spanning multiple chunks without duplicate placement or clipped geometry.
- [ ] Generate a stable coarse description before refining structure details at closer distances.
- [ ] Preserve placement and previously generated decisions during refinement.
- [ ] Cache structure descriptions and reconstruct identical results after eviction.
- [ ] Define how structure geometry combines with terrain and how placement handles slopes and foundations.

## Validation

- [ ] Verify identical results for the same seed across different request orders.
- [ ] Verify shared geometry across chunk and Superchunk boundaries, including negative coordinates.
- [ ] Verify spacing and overlap rules across generation-region boundaries.
- [ ] Verify direct fine generation matches progressive refinement and cache reconstruction.
- [ ] Preview candidate positions, accepted placements, bounds, and ownership regions.

## Scope

This plan covers sparse generated structures. Foliage placement is a separate feature.
