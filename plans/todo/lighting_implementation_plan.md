# Voxel Engine — Lighting Implementation Plan

> Implementation instructions for Codex. Extend the **existing** voxel raycaster, block-placement system, GPU data structures, and face shading. Inspect the repository before editing; keep its current conventions and avoid inventing a separate world/placement system.

## 1. Goal and scope

Implement two optional lighting methods in addition to the existing **face shading**:

1. **Point lights ("Light Objects")**: configurable position, radius/intensity, and RGB color. Light visibility uses occlusion rays against existing voxel/block geometry. Place an initial **sun-like point light above the spawn point** as a temporary demonstration/debug light (distinct from sky lighting).
2. **Skybox / sky visibility lighting**: bluish-tinted ambient illumination based on whether sky directions are visible from a surface. Add an adjustable number of additional sky rays around the initial **straight-up ray** to soften/block-reduce hard, grid-shaped shadows. Expose sky RGB and intensity as easy-to-edit constants.

Also add **one placeable sci-fi light-source block** (not a test structure). The project already supports creating and placing blocks: use that system. Its visible design should contain luminous-looking voxels/material(s), and a light source associated with the block. Do not build a separate placement system or generate any demonstration structure.

Keep existing face shading as an independent method. Support any combination of the three methods, with methods **compiled out** of the GLSL shader variants when disabled.

## 2. Repository inspection first

Before coding, locate:

- Raycasting pipeline, face-hit data, world/chunk/block/voxel coordinate conversion, existing face-shading implementation.
- Shader source loading, GLSL version, compilation/reload code, preprocessor usage, and the mechanism for Zig-to-GLSL compile-time configuration.
- GPU-visible world data and voxel/block opacity tests; use identical hit semantics for both primary and lighting rays.
- World spawn location, world initialization, block type registry, block material/palette definitions, and current block placing/removing/update paths.
- Existing handling of GPU light objects or emissive materials, if any, to avoid parallel systems.

Make changes in the project’s existing architecture. Do not implement a new renderer or assume all block data exists at full voxel resolution.

## 3. Shader feature selection: compile-time variants ONLY

Expose three Boolean **shader build options** in one easily editable Zig configuration location:

```zig
pub const LightingFeatures = struct {
    pub const face_shading = true;
    pub const point_lights = true;
    pub const sky_lighting = true;
};
```

The exact Zig source layout may differ according to existing project patterns.

Inject source preprocessor defines **before compiling the GLSL shader** (after `#version`, before other declarations). For example:

```glsl
#define USE_FACE_SHADING 1
#define USE_POINT_LIGHTS 1
#define USE_SKY_LIGHTING 1
```

Wrap not just lighting calls but also **feature-specific functions, uniforms, SSBO declarations, loops, and dependencies** in `#if USE_...` / `#endif`. When a feature is `false`, produce a shader with that method entirely absent (no uniform-driven toggles, no runtime `if (enableLighting)`, no rays from that method). The Zig CPU side should also avoid unnecessary per-frame uploads/work for disabled features wherever feasible.

Provide a small shader variant generator/loader that takes the feature set and emits the preamble. A switch of feature flags requires shader recompilation, not a frame-time state change. Preserve current shader compilation error logs and `#version` placement. Support all eight on/off combinations (including none); do not require methods to be enabled in a particular order. Compile smoke-test each combination if practical.

Feature constants such as ray count or sky RGB may be compile-time specialization values, whereas **individual light positions/colors/intensities are scene data** and should be dynamically adjustable without recompiling.

## 4. Shared surface and lighting conventions

- Use world-space coordinates for light origins and hit locations; account for block/voxel scale and chunk offsets.
- Derive the surface normal from the actual hit face. Use consistent outward normals and epsilon offsets (`hit_pos + normal * epsilon`) so lighting rays do not immediately re-hit their own surface. Epsilon should be expressed relative to voxel dimensions and verified for each LOD.
- Shadows should use the existing efficient hierarchical traversal/block skipping whenever possible; they only need **visibility/first occluder**, not full surface shading.
- Track which materials are opaque for shadow rays. Initially, binary opaque/not opaque is enough; define a path for translucent materials later, without attempting transmission/refraction now.
- Apply all lighting in a consistent RGB linear-light space, then tone-map/gamma-correct once if that is the current renderer’s convention. Clamp or tone-map appropriately; avoid overflow and washed-out brightness.
- Decide whether face shading is a stylistic multiplicative factor or a separate light component. Recommended initial combination:

```text
face_factor = face shading result if enabled, else 1
point_rgb   = accumulated visible colored point lights if enabled, else 0
sky_rgb     = visible sky contribution if enabled, else 0
emission    = emissive material RGB if present, else 0

surface_rgb = albedo_rgb * face_factor * (point_rgb + sky_rgb) + emission
```

Do not allow a totally black screen when all three lighting methods are off: use an unlit fallback (`surface_rgb = albedo_rgb + emission`) **selected at shader compile time**. If only face shading is enabled, preserve the current face-shaded appearance rather than multiplying by zero. Consider explicitly defining a baseline lighting term for face-only or no-light cases. Do not double-apply lighting to light-source voxels; their own emission should remain visible even if occluded from all external light.

## 5. Colored point lights / Light Objects

### Data model

Create/reuse a compact GPU light descriptor, conceptually:

```zig
pub const PointLight = struct {
    position: Vec3,      // world position
    color: Vec3,         // linear RGB, editable per instance
    intensity: f32,
    radius: f32,         // cutoff for limiting work
    // optional owner block/entity identifier for lifecycle management
};
```

Align/pad fields for whichever buffer layout GLSL expects (`std430`, etc.). Provide an initial small-capacity light array with an explicit active count, and an easy path to many light objects later. Culling nearby lights is preferable to tracing every light for every primary hit: start with a bounded set of relevant lights, or CPU/GPU distance culling consistent with current architecture. Do not introduce an expensive global scan per pixel.

### Shading logic

For each relevant light within radius:

1. Compute vector from hit to light, distance, and normalized direction.
2. Compute `max(dot(normal, light_direction), 0)` for front-side diffuse exposure (optionally allow existing stylized behavior if appropriate).
3. Cast a **shadow ray** from offset hit toward light and stop at the light position. Any opaque intersection **strictly before the light** blocks its contribution.
4. Apply a configurable attenuation curve (e.g. softened inverse-square multiplied by smooth radius cutoff); never divide by zero.
5. Multiply by light RGB and intensity; sum contributions in linear RGB.

Keep shadow ray max distance bounded by the point light distance, not world draw distance. Add a small debug view or logs to verify shadowing and radius behavior. Begin with one hard shadow ray per light; soft shadows/area lights can be a later extension.

### Initial above-spawn light

On world initialization create a debug **sun-like point light** above the spawn position. Give it a configurable height, neutral/warm color and enough radius/intensity to illuminate nearby terrain. It is not the skybox and need not implement a physically distant directional sun. Do not recreate it every frame. For true directional sunlight later, design the lighting interface so a directional light can be added as a different light type.

## 6. Skybox lighting / sky visibility

### Parameters

Expose easy-to-change defaults in a central settings/configuration location, e.g.:

```text
sky_color_rgb        = (0.65, 0.75, 1.0)   // intentionally slightly bluish
sky_intensity        = 0.5                // tune during implementation
sky_extra_ray_count  = 8                  // 0 => straight-up ray only
sky_first_ring_angle = 10 degrees         // first eight extra rays
sky_ring_angle_step  = 5 degrees          // 15°, 20°, ...
sky_ring_rotation    = 22.5 degrees       // alternate rings interleave
sky_max_ray_distance = appropriate horizon / world limit
sky_shadow_epsilon   = small positive offset
```

These are **initial suggestions**, not mandatory final values; avoid blue overpowering all materials. Skybox background color should also be configurable; separate background sky color from sky **lighting** color if they need independent artistic control.

### Ray algorithm

At each visible hit point:

1. Cast the primary sky-visibility ray **straight up** (`+world_up`), using current world axis conventions.
2. Cast `sky_extra_ray_count` additional rays in ordered rings around up: first N/E/S/W at 10°, then the four diagonals at 10°. Each subsequent eight-ray ring adds 5° of tilt; alternate rings rotate horizontally by 22.5° to interleave directions. Precompute directions as shader constants; do not use random or golden-angle sampling.
3. A ray contributes only if it reaches sky without hitting opaque geometry. Reuse the hierarchical ray traversal with early termination and distance/extent bounds.
4. Weight each ray by `cos(tilt)` (the vertical ray has weight 1), and divide the visible sum by the weight sum of all samples, including blocked ones. Apply `sky_color_rgb * sky_intensity * visibility` and the existing normal exposure factor.

**Important:** Extra rays soften the spatial transition at cave entrances, under overhangs and beside walls. They do not create physically correct soft shadows by themselves; they approximate directional sky ambient occlusion. If the visible result becomes grainy, use a fixed pattern with spatial scrambling and/or a subsequent low-cost temporal accumulation method, but do not require a full new temporal renderer in this phase.

Define the expected behavior of ceilings, enclosed caves, and surfaces facing downward: these should receive little or no sky light. Choose normal weighting that does not make exposed vertical walls unnaturally black; a hemispherical ambient weighting can be used rather than a strict single directional Lambert term.

### Performance and quality presets

- `sky_extra_ray_count = 0`: exactly one vertical test ray (fast, sharp/blocky).
- `4` extra: low-cost approximation.
- `8`–`16` extra: smoother default/quality mode if performance allows.
- Larger ray counts are optional; test performance on the actual engine workload.

Make ray count compile-time configurable so GLSL can fully specialize or unroll the loop when appropriate. When sky lighting is disabled, its rays and uniforms must disappear from the shader.

## 7. One placeable sci-fi light block

Use the **existing block definition, creation, palette, and placement** mechanisms. Add one user-placeable block type with a sci-fi appearance, not a test structure or separate scene artifact.

Suggested voxel design inside the project's normal block resolution:

- Sparse dark cage with one-voxel-wide edges and two thin bars per face.
- A single cyan emitter voxel near the center, with the point light at its center
  (local `7.5, 7.5, 7.5`). The cage occupies only 345 of 4096 voxels.
- Preserve opaque cage vs luminous emitter materials; only the emitter is self-lit.
- Point shadow rays pass through matching emissive material within their own
  endpoint block, including multi-voxel LED shafts. Cage bars and other intervening geometry still cast shadows;
  sky-ray occlusion is unchanged.

When a block instance is placed, register or attach one colored point light at the emitter's world-space position. When the block is moved/removed/replaced or its chunk unloads, update/remove the light without leaving duplicates or dangling references. Re-register correctly on chunk reload if blocks persist. If the current engine cannot cheaply bind lights to placed blocks yet, add the smallest block->light ownership mechanism compatible with future entity-attached light objects; do not implement an unrelated scene system.

Give the block's point-light RGB/intensity/radius suitable defaults (cyan-blue) but use the same configurable `PointLight` representation as other lights. Its visible emissive voxel material is independent of whether point-light shading is enabled: the block can still look luminous without casting light in variants where point lights are compiled out.

## 8. Performance safeguards

- Avoid allocating buffers or launching work per pixel; GPU lighting should read already uploaded light descriptors.
- Use the renderer's current chunk/block/voxel hierarchy for ray acceleration; never fall back to naive per-voxel loops across long rays unless absolutely necessary.
- Limit point-light traversal to distance-to-light, and sky traversal to sky exit/world bounds or configured maximum range.
- Allow easily adjustable budgets for number of lights affecting a hit and sky ray count; document quality/performance tradeoffs.
- Avoid a shader variant explosion for every numerical value: only feature enablement and explicitly chosen quality constants should specialize shaders.
- If the renderer supports LOD, use equivalent shadow-ray behavior at available geometry levels; document known edge artifacts and ensure the implementation does not require far chunks to be generated at full detail.

## 9. Implementation order

1. Inspect current rendering/world/block code and report the files that will change.
2. Implement compile-time feature flags, shader source define injection and guarded sections. Verify old face shading alone still works.
3. Refactor any necessary surface-hit helper data and shared fast occlusion traversal.
4. Implement sky lighting: vertical visibility ray, configurable bluish sky RGB and intensity; then add selectable extra cone rays.
5. Implement colored point-light data/upload and shadowed shading.
6. Instantiate the initial configurable sun-like point light above spawn.
7. Add the sci-fi **placeable block** to the existing block system, with emissive visual materials and point-light lifecycle integration.
8. Add debug instrumentation and test compile-time variants; fix regressions/performance issues.

Do not replace existing rendering behavior wholesale or remove existing face shading.

## 10. Acceptance criteria

- [x] Existing face-only shader variant looks and performs as before.
- [x] Each of `face_shading`, `point_lights`, `sky_lighting` can be switched on/off **before shader compilation** and any combination builds.
- [x] Disabled methods produce **no runtime toggle branch and no associated shadow/sky ray tracing**; their unused GLSL code and resources are not compiled in.
- [x] Sky lighting produces configurable **slightly blue** illumination, distinct from sky background rendering.
- [x] Setting `sky_extra_ray_count=0` produces one straight-up ray; higher counts add spread rays and produce smoother transitions near edges/overhangs.
- [x] Per-light RGB can be changed without rebuilding the shader, and a red/green/blue light visibly tints nearby surfaces appropriately.
- [x] Point lights are occluded by solid world voxels and are bounded by a configurable radius.
- [x] One configurable sun-like light is located above spawn for initial testing.
- [x] One sci-fi light **block** is selectable/placeable using the existing engine systems; no new test structure is introduced.
- [x] The placed block emits visually and casts configurable colored light when point-light shading is compiled in.
- [x] Removing the placed block cleans up its corresponding light; reloading a chunk does not duplicate lights.
- [x] Engine still handles normal chunk streaming, voxel LOD, and shader compilation errors gracefully.

## 11. Notes to Codex

Use actual repository types, naming conventions and shader language version; pseudo-types and config values in this document are illustrative. Focus on a working first version over advanced global illumination, reflection, or denoising. Keep light source and sky parameter configuration obvious. Where implementation specifics depend on currently existing code, inspect that code rather than inferring an API from this plan.


## Implementation and verification

Implemented in `src/lighting.zig`, `src/graphics/pointLights.zig`, the shared
`lighting.glsl` include, shader source specialization, and the existing block
metadata/world packing paths. `31_scifi_lamp.block`/`.vox` provide the selectable
lamp. No new demonstration structure is generated.

`zig build`, `zig build test`, and `zig build test-render` validate the implementation.
The Mesa/EGL suite compiles all eight variants on both shader profiles; tests RGB
changes, radius cutoff, opaque/transparent and single-voxel occlusion, all six
normals, negative coordinates, light-distance bounds, sky presets 0/4/8/16,
overhangs/ceilings, unlit fallback, emission, lamp replacement/removal, and GPU
region leave/reentry. Existing face-only reflection, refraction, icon and menu
checks remain intact. Interactive appearance and target-GPU frame times still
need hardware tuning; the checks above use software OpenGL.

Known first-version limits are documented in README: eight camera-selected lights,
coarse shadows from coarse geometry, transparent untinted glass shadows, unloaded
geometry treated as sky, and no saved-world persistence (matching the existing
engine). The existing spawn is inside a roofed building, so its interior naturally
blocks sky/sun illumination until a lamp is placed or the roof is opened.

### Performance follow-up: voxel-face cache

Added an optional, default-on 9 MiB GPU face cache with full world-coordinate /
normal keys and frame-safe publication. Geometry and selected-light revisions
invalidate it without buffer clears. Empty streamed chunks and off-region edits
do not invalidate visible lighting. Outdoor miss rays stop at the loaded-region
boundary. See README for quality tradeoffs, collision fallback, cold-frame costs,
and the software OpenGL indoor/outdoor benchmarks. Cache integration tests cover
reuse, collisions, stale shadows, changing lights and chunk-region reentry.

### Artifact fix: false shadows at empty-region boundaries

Clamped reconstructed non-exit coordinates to the region being skipped before
advancing the actual exit axes. Floating-point rounding could otherwise send a
ray backward across an already-crossed boundary; exhausting the shadow step
budget then produced an isolated dark sample. Reproduced on a uniform floor
with caching disabled (three pixels lost one of nine sky rays). The flat-floor
regression now checks 262,144 exact face samples for point/sky/combined lighting
and oblique camera views on both sides of zero, cached and uncached. All samples
match the expected unobstructed illumination after the fix. Face-cache sampling
and lighting quality settings are unchanged.


### Requested sampling refinement

Point-light and sky illumination now always use the voxel-face center, including
uncached, cold-cache and collision fallback paths. Disabling caching changes only
reuse/performance. Replaced the golden-angle cone with precomputed ordered rings:
4 cardinal rays at 10°, 4 diagonal rays at 10°, then rings at 15°, 20°, etc., with
alternating 22.5° horizontal offsets. Cosine tilt weights are normalized across
all rays. Tests move pixel samples within each face to verify constant point-light
illumination, and check GPU sky visibility against known weighted occlusion.
