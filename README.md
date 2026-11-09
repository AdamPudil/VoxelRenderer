# Description

# Versions

## FPS table

4 -> 16x16x16 voxels (blocks) and 4x4x4 blocks big world. so 64x64x64 voxels.  
8 -> 8x8x8 blocks big world. so 128x128x128 voxels.  
16 -> 16x16x16 blocks big world. so 256x256x256 voxels.  
32 -> 32x32x32 blocks big world. so 512x512x512 voxels.  

| Version | Machine | Generation |Resolution| FPS at render distance |||
|---------|---------|------------|----------|---|---|----|
|         |         |            |          | 54 | 128 | 256 |
|  0.0.1  | T430    | low noise  | 1280x720 | 48 | 25 | 12 | 
|         |         |            |

## GPU detection and shader profiles

For a low-FPS comparison, use an optimized build and compare
`zig build run -Doptimize=ReleaseSafe -- --lighting=direct --gpu-stats`
with `--lighting=face` in the same stationary view after streaming settles.
The default remains direct lighting with the configured ring cutoff. The face
mode compiles out point/sky lighting and their cache; terrain and optical
traversal remain enabled. Startup reports the actual GPU, build mode and lighting
mode, and `--gpu-stats` also prints framebuffer size and batched GPU timings.

Run from the repository root:

```sh
zig build run -- --gpu-info
zig build run -- --shader=rtx3060
zig build run -- --shader=vega56
zig build run -- --shader=thinkpad
zig build run -- --shader=desktop
```

Startup prints the active OpenGL renderer (GPU), vendor, OpenGL version, GLSL
version, and selected shader paths. `--gpu-info` creates a hidden context and
compiles/links the selected shaders, then exits before generating the world.
It needs a working graphical session and GPU driver. These are the capabilities
of the active context, not a list of all installed GPUs or their VRAM sizes.

The default `--shader=auto` identifies the active GPU at runtime from the OpenGL
vendor and renderer strings, using case-insensitive model matching:

- Explicit RTX 3060 names select `rtx3060` (RTX 3060 Ti is a separate model).
- Explicit Radeon Vega 56 names select `vega56`.
- Generic Radeon RX Vega / VEGA10 names select `vega`; startup reports that the
  exact model is not identified. Integrated Vega 8/10 Graphics do not match this
  discrete-GPU family. Use `--shader=vega56` to override an ambiguous name.
- Unknown GPUs retain the `thinkpad` compatibility profile.

Device profiles use the desktop shader when OpenGL 4.6 is available; automatic
selection falls back to compatibility shaders on a 4.2 context while still
reporting the detected device. Selection does not switch GPUs on machines with
multiple adapters. Model names are not performance rankings or VRAM queries.

- `thinkpad`: existing `src/graphics/shaders/voxel.vs` (GLSL 3.30) and
  `voxel.fs` (GLSL 4.20), requiring an OpenGL 4.2 context.
- `desktop`: separate `src/graphics/shaders/desktop/voxel.vs` and `voxel.fs`
  entry points targeting GLSL 4.60, requiring OpenGL 4.6.
- `rtx3060`, `vega56`, `vega`: independent selection names currently sharing
  the desktop entry points and settings. They provide a place for future measured
  device-specific tuning; Vega is not assigned lower quality or smaller budgets.

Startup requests OpenGL 4.6, falling back to 4.2. An explicitly selected desktop
or device profile fails with a diagnostic if 4.6 is unavailable. Shader compilation errors
are reported rather than silently switching profiles.

The desktop profile initially shares traversal and world-data code with the
ThinkPad profile. It is a starting point for separate desktop shader development;
it does not yet introduce RTX-specific acceleration, increase the VRAM budget,
or promise faster rendering. Changing the GLSL version alone is not an optimization.

The RTX 3060 header-fetch experiment can be compared using
`zig build run -Doptimize=ReleaseSafe -Dvector-world-headers=true -- --shader=rtx3060 --gpu-stats`.
Use `-Dvector-world-headers=false` for the default scalar baseline. The candidate
fetches each chunk/block/voxel header as one four-component texture record;
terrain nodes and rendering quality are unchanged. `--gpu-stats` reports
asynchronous per-pass median, p95, p99 and maximum GPU milliseconds in 120-sample batches.
Compare the same stationary view after streaming settles. Hardware gains have
not been measured; see the [RTX 3060 investigation](plans/todo/rtx3060_shader_performance.md).

## CPU and GPU profiling

Use an optimized build from the repository root:

```sh
zig build run -Doptimize=ReleaseSafe -- --profile
# Optional per-frame CSV (enables both CPU and GPU profiling):
mkdir -p logs
zig build run -Doptimize=ReleaseSafe -- --profile-csv=logs/profile.csv
# Include existing terrain worker build/queue and upload diagnostics:
zig build run -Doptimize=ReleaseSafe -- --profile --terrain-stats
```

Profiling is off by default. `--profile` prints median, p95, p99 and maximum
milliseconds in batches of 120 samples, plus a partial batch on normal exit.
`--gpu-stats` enables just the GPU side. Framebuffer dimensions, device, shader,
lighting mode and build mode are printed at startup. Compare the same resolution
and camera view after streaming settles; initial frames include warm-up work.

CPU stages cover input/setup, streaming and uploads, editing, render preparation,
world draw submission, lighting-cache publication, GI submission, menu, buffer
swap, and housekeeping (including screenshots and FPS logging). These are
**main-thread wall times**, including driver waits, rather than CPU utilization
or sampled call stacks. `total` covers those stages; profiler collection and
report/CSV writing are outside that interval. Background terrain worker timings
are reported separately by `--terrain-stats`. Minimized frames are excluded.

GPU stages cover cache preparation, the world draw, lighting-cache publication,
GI update, and menu rendering. GPU `total` is the sum of those measured passes;
it excludes terrain uploads, clearing, presentation and gaps between passes.
CPU and GPU overlap, so their totals should not be added together. Timestamp
intervals can include GPU stalls or starvation; they are not shader instruction
or utilization counters. The `swap` CPU stage helps expose presentation/driver
waits; profiling does not change swap interval or rendering quality.

The profiler uses an eight-frame ring of [OpenGL timestamp queries](https://registry.khronos.org/OpenGL/extensions/ARB/ARB_timer_query.txt).
It polls availability before reading results and skips GPU samples if all slots
are busy. Collection never waits for timing results. Controlled benchmark exit polls for
up to two seconds outside measurement to drain completed queries. Shutdown reports skipped and still
pending samples; pending GPU results may be absent from a short capture. A
context without timestamp support disables the GPU side with a diagnostic.

CSV output retains `frame,domain,stage,ms` columns (`domain` is `cpu`, `gpu`, or
`cadence`). `cadence,frame_interval` measures the full frame including profiler
and log overhead, attributed to the originating frame. Existing CPU/GPU stage
names and totals are unchanged. GPU
rows arrive later and retain the originating frame number; join on `frame`, not
row order. The file is overwritten on launch, buffered, and flushed on normal
exit. Its parent directory must exist. CSV and console output add overhead, so
use matching capture options for comparisons. A write failure disables CSV
output with a diagnostic while profiling continues.

```sh
zig build test-profile       # percentiles, CPU stages, disabled mode, CSV
zig build test-profile-gpu   # Mesa/EGL queries, ring reuse, GPU frame IDs
```

Stationary benchmarks freeze camera movement and editing, wait for the full
requested terrain publication, require stable geometry/light revisions, then run
warm-up and measured frames. All phases remain in the CSV; the frame sidecar
labels `settling`, `warmup`, and `measured`, so cold/streaming costs are retained.
A revision change during measurement fails the run. `--benchmark-max-frames`
bounds startup/settling (default 10000). An interrupted or unsettled benchmark
returns an error and records `complete: false`.

```sh
mkdir -p logs
zig build -Doptimize=ReleaseSafe
./zig-out/bin/voxel --world=terrain --lighting=direct \
  --camera=100,453,100 --camera-angles=3.14,-0.15 --framebuffer=1920x1008 \
  --benchmark-frames=300 --benchmark-warmup=120 --benchmark-settle=60 \
  --swap-interval=0 --profile-csv=logs/direct-1.csv
python3 utils/compare_profiles.py logs/direct-1.csv logs/direct-2.csv logs/direct-3.csv
python3 utils/compare_profiles.py logs/direct-1.csv --phase=all --start=1 --end=40 --json
```

Camera angles are yaw/pitch in radians. Explicit camera position bypasses automatic
terrain spawn-height adjustment. Without `--camera`, the default spawn is resolved
before warm-up; the actual pose is recorded. `--framebuffer=WxH` requests pixel
dimensions and rejects a mismatch. Benchmark windows are hidden by default;
`--benchmark-visible` enables visual/presentation checks. Match visibility between
runs. `--swap-interval=0|1` is explicit; omitting it preserves the normal platform
default. The metadata records the request, not a claim that the driver honored it.
Benchmark/diagnostic mode enables CPU/GPU profiling and defaults to
`logs/benchmark.csv` if no CSV path is supplied. Captures overwrite their paths.

Each timing CSV has `.meta.json` and `.frames.csv` sidecars. Metadata includes GPU,
driver, build mode/compiler, content hashes of build-time and runtime source
(including modified/untracked files), assets, shader flags, generation and ring
settings, lighting, uploads, framebuffer, camera options, and dropped/pending GPU
samples. Per-frame context records camera, geometry/light revisions, cache
invalidation stamps, upload bytes, and GPU allocation. Generated icons are excluded
from source identity. A null metadata `result` indicates an unfinished/crashed run.
The comparison tool selects phases/frame ranges, reports sample counts,
median/p95/p99, stage shares, missing samples, metadata differences and variation
across identical repeated configurations. It supports old timing CSVs, but warns
that phase/comparability data is unavailable. It never treats an unmatched timing
difference as an accepted optimization.

Add `--direct-diagnostics=64` to compile sampled direct-lighting instrumentation
(one spatially hashed pixel in 64); `1` counts every fragment, and powers of two
through 65536 are supported. Normal shaders compile out all counters and resources.
The extra `.diagnostics.csv` reports raw sampled cache lookups/hits/misses,
ownership/pending/collision/probe/window outcomes, actual lighting evaluations,
point/sky visibility rays, primary/optical rays, traversal steps, hierarchy record
visits and step exhaustion. These are algorithmic counts, not hardware counters;
node counts include lighting-level queries in the owning primary/optical context.
Selection vertex work and icons are excluded. `same_frame_pending` means an occupied
slot in this draw, which may belong to another key; it is not proof of a duplicate
face. Evaluation counts include uncached/zero-normal fallbacks as well as misses.

Counters use 64 shards, low/high carry words and eight fenced readback buffers
(112 KiB). Busy buffers drop a diagnostic sample rather than wait or overwrite.
Frame/revision/stamp fields correlate counters with invalidation and ordinary
capture phases. Report instrumentation overhead against matched captures without
`--direct-diagnostics`; diagnostic GPU times are not production timings.
`lighting_cache` is only a publication barrier: direct evaluation belongs to `world`.
Use at least 300 measured frames, three repetitions, and alternating order for
baseline/candidate experiments. Keep camera routes, edited/optical scene coverage,
cache redesign and traversal experiments gated on the measurements described in
[the optimization plan](plans/todo/profile_guided_optimization.md).

```sh
zig build test-profile -Doptimize=ReleaseSafe
zig build test-profile-gpu -Doptimize=ReleaseSafe
python3 -m unittest discover -s utils -p test_compare_profiles.py
```

## Block models, icons and building

Run `zig build run` from the repository root. Startup creates missing
sample `.block` descriptors and MagicaVoxel `.vox` models in `assets/blocks`:
red, green, blue, white, black, yellow, orange, purple, cyan, pink, gray, brown,
lighter red/green/blue variants, coarse checkerboard, fine checkerboard, and an
open frame, gold, copper, iron, mirror, eight glass variants, a sci-fi lamp,
and six LED sticks (37 entries total).
Existing sample files are preserved. Use `--assets=some/directory` to choose a
different block folder (the samples are created there too).

- **Tab** opens/closes the block menu and releases/captures the cursor.
- Click an icon to select it. Click it again, right-click in the menu, or choose
  **Empty hand** to deselect. **Prev/Next** navigate larger collections.
- **Esc** closes the menu; in normal gameplay it exits.
- With a block selected, **right mouse** places a copy in the adjacent block
  cell on the face hit by the center-screen ray.
- **Left mouse** removes the entire block containing the hit voxel by default,
  including with an empty hand. No selected block is needed for removal.
- **V** toggles left-click removal between a whole 16×16×16 block and just the
  targeted voxel. The HUD displays the current mode; holding V toggles only once.
  Release the mouse after switching modes. Right-click always places whole blocks.
  Voxel deletion also works on the solid floor/walls and preserves neighboring
  voxels. The black outline follows the mode: the targeted block in block mode, or
  the targeted voxel in voxel mode.
- Holding a mouse button repeats at most once per 0.20 seconds and six frames.
  Menu clicks cannot edit the world. Release both buttons after closing it.
- Editing reaches 256 voxels. Placement requires an empty, loaded block cell
  and cannot put a block around the camera. Movement pauses while the menu is open.

Edits survive streaming/rebuilding during the current session. World saving to
disk is not implemented; edits reset on restart.

A descriptor is a UTF-8 text file with a `.block` extension:

```text
name: Checker
variant: 0
model: checker.vox
# Optional; omit (or leave empty) to generate from the model:
# icon: icons/my_checker.png
```

`Block name`, `model path`, and `icon path` are also accepted as attribute names;
keys are case-insensitive. `variant` defaults to 0 and must fit in a `u8`.
Blank lines and full-line `#` comments are supported. Values may be quoted.
Names are case-sensitive, and `(name, variant)` pairs must be unique. Paths are
relative to the descriptor's directory. Custom icons must be PNG files.

Add `rotation: yaw` to a descriptor to orient it when placed. The model's front
is engine-local **+Z** (after VOX import), and **+Y** stays upright. Its front faces
toward the player, snapping to the nearest horizontal cardinal direction:

| Looking toward | Placed model's front |
| --- | --- |
| +Z | -Z |
| +X | -X |
| -Z | +Z |
| -X | +X |

Exact diagonal ties use Z; looking straight up/down retains the camera heading.
The block stays fixed after placement. Geometry, materials, and attached lights
rotate together, including for ray picking and voxel removal. `rotation: none`
(the default when omitted) keeps the authored orientation. Keys and rotation
values are case-insensitive; unsupported modes are rejected. Both descriptor
formats support this setting. Vertical rotation and arbitrary angles are not
supported yet.

**Shipassets Handle** is enabled as an asymmetric example. Its base lies on the
local -Z side and its grip projects toward +Z. Other blocks retain their existing
defaults. Inventory icons show the authored orientation. The GOX exporter preserves
an existing descriptor's `rotation` attribute when re-exporting its model.

Reflective blocks use the extended, backward-compatible `.block` format:

```text
format: 2
name: Gold
variant: 0
model: 19_gold.vox
color: 255, 209, 112
reflectivity: 0.85
metallic: 1
```

`color` optionally overrides occupied voxel RGB (three integers 0–255); omitting
it preserves the model palette. `reflectivity` and `metallic` are finite numbers
from 0 to 1, defaulting to zero. `reflectiveness` is an alias for `reflectivity`.
Metallic controls reflection tint: 0 reflects neutral scene colors, 1 tints with
the voxel color. `format` may be omitted for legacy descriptors; versions 1 and 2
are accepted. Invalid/duplicate fields fail loading with a diagnostic.
`blockLoader.encodeMetadata` writes canonical version 2 descriptors;
`saveMetadata` saves them atomically. Geometry stays in the referenced `.vox`.
This saves block definitions, not world placements.

| Block | Reflectivity | Metallic |
| --- | --- | --- |
| Gold | 0.85 | 1 |
| Copper | 0.72 | 1 |
| Iron | 0.55 | 1 |
| Mirror | 0.98 | 0 |

These are artistic polished-surface presets, not measured optical constants.

Clear and sanded glass each come in **White (neutral), Red, Green, and Blue**.
Clear glass uses opacity `0.04`; sanded glass uses `0.50`. Both use IOR `1.5`.
Select them in the block menu (use Next on smaller windows).

```text
format: 2
name: Glass Red
model: 24_glass_red.vox
color: 255, 105, 105
opacity: 0.04
ior: 1.5
reflectivity: 0
metallic: 0
```

- `opacity`: optional finite value 0–1; absent preserves model alpha. For glass,
  this controls loss of transmission and a simple colored haze per 16 voxels of
  travel. 0 is clear, 1 is opaque. `transparency` is an alternative spelling with
  the inverse value (`1 - opacity`); specifying both is an error.
- `ior`: finite index of refraction from 1 to 2.5, default 1.5. At 1 the ray does
  not bend; at 1.5 it bends like the glass preset. Used only below full opacity.
- Glass color filters transmitted RGB over distance. White is neutral; stacked
  colors multiply their filters (subtractive mixing), and thicker glass filters
  more strongly. Glass remains occupied, collidable/pickable by existing voxel
  queries, and editable even at opacity 0; it is not an empty voxel.
- Glass uses dielectric Fresnel reflection derived from IOR, with `reflectivity`
  as a minimum surface reflection. `metallic` tints opaque reflections only.

The shared shader follows both reflected and refracted rays, bending at medium
entry/exit and handling total internal reflection. Contiguous equal glass voxels
form one medium instead of charging opacity at every internal face. Sanded glass
uses higher opacity/haze; it does not yet blur the transmitted image.

Glass-to-glass boundaries never spawn reflections, including between different
colors or opacity values. They preserve color filtering and refract for differing
IORs when possible; an internal glass-to-glass critical-angle case continues
straight. Fresnel reflection and total internal reflection apply at glass/air
boundaries.

Work is bounded to 32 ray segments per pixel, 12 transmission/interface steps per
path, and six reflection bounces. Deep optical paths may lose residual light at
these limits; the final opaque reflection hit uses local shading. Opaque matte
surfaces need no extra rays. Only geometry in the loaded GPU region participates;
misses use the sky. There is no dispersion, caustics or full global illumination.
Selection/picking stays on the first surface. Scene transmission is composited in
the shader; icons keep transparent backgrounds outside the model and use a neutral
studio environment. Both ThinkPad and desktop shader profiles share this code.

Materials still use 64 bits per voxel. Reflectivity and metallic retain their
bytes; the formerly redundant transparency byte now stores an IOR code (0 means
non-transmitting/empty, 1–255 encodes IOR 1–2.5). Opacity retains its own byte.
The engine's `.block` and `.vox` files remain backward compatible; no saved-world
binary format exists to migrate. Reflection, opacity and tint values are quantized
to bytes when loaded.

The registry stores definitions in an array indexed by numeric ID, plus a name
hash map with variant slots. IDs are assigned from sorted descriptor filenames,
so they are deterministic for an unchanged asset set, not persistent save IDs.
`BlockRegistry.find(name, variant)` resolves a definition's ID. Each placed model
is a deep copy; editing it does not mutate the registry or other placements.

Supported models contain one raw MagicaVoxel model (VOX version 150 or 200), at
most 16×16×16 voxels. Smaller models are padded with empty space at the positive
ends of the block. Z-up data is converted to Y-up while preserving handedness.
Explicit and default palettes are supported. Scene transforms and extended
material properties are not applied; multiple models are rejected. The future
custom model format is not implemented. Parser layout follows the
[MagicaVoxel format specification](https://github.com/ephtracy/voxel-model/blob/master/MagicaVoxel-file-format-vox.txt).

Missing `icon` attributes produce transparent 64×64 PNGs in
`assets/blocks/icons/<descriptor-stem>.png` (or the chosen asset folder).
They use the engine's world shader, a three-quarter camera showing three sides,
and supersampling. Generated icons are refreshed at startup; explicit icon
files are loaded as supplied. The generated PNGs can be reused by a future inventory.

Validation:

```sh
zig build test          # parser, registry, world edits, ray hits, menu, cooldown
zig build test-render   # optional headless Mesa/EGL icon and menu integration
```

`test-render` requires EGL development files and Mesa software rendering. It
checks both shader profiles, reflected offscreen targets, all six face directions,
material tint, matte fallback, transmission, color mixing, oblique refraction,
and total internal reflection. It also compiles all eight lighting feature combinations on both shader profiles and checks colored lights, shadow/radius bounds, sky ray presets, emission, and lamp ownership across edits and streaming. It writes previews to `/tmp/voxel-block-smoke/`.
Normal builds continue to use GL, GLFW and GLEW. PNG loading uses the vendored
[stb_image](https://github.com/nothings/stb) implementation and existing PNG writer.

## Developer input and frame queues

The current controls use the `developer` input mode. GLFW callbacks feed a
remappable input system; the renderer consumes actions from the existing event
bus. Each frame promotes deferred commands, processes input commands, polls
GLFW, writes mapped actions directly into their owning **current-frame** queues,
dispatches actions, and clears current queues. Queue and input-command dumps are
disabled; FPS is printed approximately once per second and can be toggled with F3.
Next-frame/debt buffers survive cleanup. Queues without a runtime consumer yet
are retired at this cleanup point.

`developer` is a binding mode, not a queue. `src/core/input/routing.zig` defines
an exhaustive action-to-event mapping:

| Actions | Destination events |
| --- | --- |
| Forward/back/strafe/up/down; look | `entity.move`, `entity.look` |
| Remove/place; removal-mode toggle | `world.remove`, `world.place`, `world.toggle_removal` |
| Menu state, clicks, pointer; binding responses | `UI.menu_input`, `UI.activate`, `UI.deselect`, `UI.pointer`; UI response events |
| Screenshot; FPS toggle | `render.screenshot`, `render.toggle_fps` |
| Quit | Existing `core.EngineShutdown` |

Entity/world payloads deliberately contain nonexistent testing IDs:
`TEST_ENTITY_ID = 0xffffffffffffffff`, `TEST_WORLD_ID = 0xffffffff`.
Movement includes a local direction (W = `[0, 0, -1]`, release = zero) and
input phase/frame metadata. These IDs do not spawn or resolve real entities.
Temporary main-thread adapters preserve the existing camera/menu/editing controls;
they merge routed events by input sequence to preserve cross-queue click and
cancellation order. Real subsystem consumers can later read these typed events
directly, with actual target IDs replacing the test values.


F2 (screenshot), F3 (FPS toggle), Tab and V trigger once per press. Movement and
mouse editing support holding; opening the menu or losing focus cancels active
controls. Release held controls before using them after a context change.

Load an optional profile with:

```sh
zig build run -- --input-profile=input.json
```

Example `input.json` (omitted actions keep defaults; an empty sources list unbinds):

```json
{
  "version": 1,
  "mode": "developer",
  "bindings": [
    { "action": "forward", "sources": [{ "key": "E" }, { "key": "UP" }] },
    { "action": "screenshot", "sources": [] }
  ]
}
```

Runtime callers submit typed commands to `input` through `EventSystem.submit`:
`replace_bindings`, `reset_bindings`, `apply_profile`, `query_bindings`,
`begin_rebind`, `cancel_rebind`, `set_menu`, `set_enabled`, or `change_mode`.
Commands apply at the next frame boundary; responses, binding snapshots and
capture candidates appear in `UI`. Up to four keyboard/mouse sources
can bind one button action. The settings layer can save acknowledged profiles
with `types.saveProfile`; no settings UI or controller backend is included yet.
Unsupported modes and invalid mappings are rejected without changing bindings.

`beginFrame`, `submitCurrent`, `drainCurrent`, `printCurrent`, and `clearCurrent`
are frame-coordinator APIs, used on the main thread with no concurrent current
queue consumers. Other threads use deferred `submit`. Do not mix this explicit
frame schedule with `processConsumer`/`processType`, which advance queues themselves.
Current-frame or raw-input overflow returns an error and stops the application;
it does not silently discard a release or defer a current-frame action.

```sh
zig build test-input   # mapper, profiles, cancellation, frame queues
zig build test         # also includes existing block tests
```

## Startup building

A matte gray building starts at block X=0, Z=0 and extends through X/Z=15:
a **16×16-block exterior**, one-block walls, and a **14×14×4-block clear interior**.
The reddish-brown floor occupies Y=-1 (top at world Y=0); walls occupy Y=0–3
and the gray roof Y=4. A 2-wide, 3-high doorway is centered on the negative-Z
side. The default camera starts inside. The building uses ordinary editable,
opaque, nonreflective blocks and is recreated on startup, like the rest of the
unsaved world.

### Default: simple face-orientation shading

`mode = .legacy` in `src/lighting.zig` currently selects a fixed directional
face factor with ambient fill for terrain previewing. Brightness depends on the
surface normal and a fixed light direction `(1, 1, 0.8)`, so it stays stable as
the camera moves. Point lights, sky visibility rays and GI are disabled in this
mode. Set `mode = .direct` and rebuild to restore direct lights and sky.

### Direct lights and sky

`mode = .direct` in `src/lighting.zig` enables point lights (including the sun and
lamps) and ordered sky visibility. Normal probes and indirect GI are disabled;
the legacy artistic face factor is also omitted so shading comes from the lights.
Lighting samples each voxel face center and uses the persistent 9 MiB GPU face
cache. Entries survive frames and camera movement, and are invalidated by world,
streaming, or light changes. Misses compute the same lighting immediately instead
of displaying pending black faces. This cache persists during the running session,
not on disk across restarts.

Skylight is cool blue (`0.6, 0.75, 1.0`, intensity `0.65`); the spawn sun is warm
(`1.0, 0.825, 0.535`, intensity `0.75`). Their linear contributions are balanced to
roughly neutral white on exposed ground beneath the sun without relying on RGB
clipping. Since this sun is still a finite-range point light, distant ground gets
less sunlight and a cooler sky-dominated tint. Lamp colors remain independent.

### Experimental progressive global illumination

`src/lighting.zig` selects the shader at build time with `mode`:
`legacy` (current default, face-orientation shading), `direct`, or
`global_illumination` (experimental). GI is retained for later tuning.
There is no runtime shading-mode branch. Rebuild and restart after changing it.
In GI mode, `LightingFeatures.sky_lighting`, `LightingFeatures.point_lights`,
`gi_normal_probes`, and `gi_indirect` independently compile stages in or out.
GI does not multiply diffuse transport by the legacy artistic face factor.

Camera rays only look up a world voxel coordinate plus face index and enqueue
missing/incomplete faces. A separate OpenGL 4.2 fragment pass consumes a persistent
GPU FIFO; no compute shader, per-hit CPU readback, or full GI loop in the camera
shader is required. New visible misses enter before refinements are requeued.
Secondary hits request direct-only dependencies, so there are no recursive bounce
jobs. Direct values are read only from earlier frames and remain immutable until
invalidation. One diffuse bounce is currently supported.

The stages are pending, direct-ready, indirect-partial, and converged. Pending or
dirty entries show emission only, never a stale lighting result. A face-normal
probe supplies a temporary first estimate from the surface it sees; it creates no
light of its own. Its estimate is **replaced**, rather than added, when hemisphere
samples arrive. The final estimate uses 64 deterministic Fibonacci hemisphere
samples, in bit-reversed order, accumulated in batches of 1, 2, 4, 8, 8, ... .
Uniform hemisphere sampling uses `2 * cos(theta)` weights for diffuse irradiance
normalized by pi. Reflected albedo is bounded to 0.95; emissive radiance is added
separately. `gi_max_radiance` bounds HDR cache values and non-finite values are
rejected. Only cached **direct** light is bounced, preventing feedback cycles.

Broad sky remains the ordered upward visibility probes described below. This is
an artistic exposure approximation, not a full hemisphere sky integral. Normal
and indirect rays that escape contribute zero additional sky, avoiding double
counting; sky can still reach a receiver through a bounce from a sky-lit surface.
Disabling sky visibility removes sky illumination from all stages. The above-spawn
sun remains a finite-range colored point source, with varying direction and
attenuation; it is not a directional sun. `point_attenuation` controls the softened
inverse-square denominator. Glass passes diffuse/shadow probes without tint.

Default limits: 262,144 face slots (22 MiB plus a small queue), 4,096 queued faces,
256 jobs/frame, 8,192 rays/frame as a hard ceiling, and 512 voxels per indirect ray.
With the default direct-light settings the scheduler caps work at 4,352 rays/frame
(the lower job limit applies first). Each ray also has a 2,048 traversal-step cap.
`gi_samples` must be a power of two; `gi_max_batch`, `gi_ray_budget`,
`gi_max_jobs`, `gi_queue_capacity`, and `gi_max_distance` set the cost/quality tradeoff.
Completed faces consume no more lighting rays. Unused, unqueued entries older
than 120 frames are evicted in 1,024-slot maintenance slices. Full queues defer
work; hash/capacity pressure uses the pending fallback and retries, never another
surface's light. Dense scenes can take longer to refine or retain pending faces
under sustained cache pressure.

Existing `World.gpu_revision` invalidates conservatively across the whole cache
when geometry/materials or the streamed region changes. Light descriptor changes
also invalidate it; dirty state is represented by an old revision stamp. Merely
moving the camera within the same streamed region or resizing the viewport does
not discard samples. GI light selection is anchored to the streamed region's
center, so camera motion does not change the selected set. Crossing streaming
boundaries changes the known geometry domain and intentionally invalidates rays
that previously assumed unloaded space was empty. Shader/config changes create a
new cache. No duplicate edit/placement system or test structure is added.

`zig build test-gi` checks all 16 feature combinations, both camera shader profiles,
progressive convergence/color bleed, zero warm-cache rays, sky energy, camera
motion, edits, streaming, wraparound, eviction, and queue overload under software EGL.
`Cache.counters()` is an explicit diagnostic readback; the normal frame loop never
calls it. `Features.diagnostics` enables per-pixel hit counters for profiling and
is off in the application to avoid a global atomic on every pixel. Startup reports
memory and budgets; tests report convergence, hit/miss counts, and software timings.
These timings are not measurements of the RTX 3060.

### Lighting

`src/lighting.zig` is the central configuration. Set `LightingFeatures.face_shading`,
`point_lights`, and `sky_lighting` independently and rebuild the executable. The
loader injects GLSL defines after `#version`; disabled methods and their resources
are preprocessed out. Explicit legacy test variants retain face-only and unlit
material-color references; GI with all light sources disabled stays dark apart
from emission. Selection rays do not shade surfaces.

Sky lighting uses a blue ambient color separate from the background. A vertical
visibility ray plus `sky_extra_ray_count` ordered rays approximate sky occlusion.
The first four extras tilt 10° toward north (-Z), east (+X), south and west. The
next four fill NE/SE/SW/NW at the same tilt. Each further group of eight forms a
wider ring: 15°, 20°, etc., in 5° steps. Alternate rings rotate horizontally by
22.5° to interleave their directions. These angles are configurable through
`sky_first_ring_degrees`, `sky_ring_step_degrees`, and `sky_ring_rotation_degrees`;
`sky_max_ring_degrees` keeps rays above the horizon. There is no random sampling.

A tilted ray contributes `cos(tilt)` times the vertical ray's weight. Visible
weights are divided by the total weight of **all** rays, including blocked ones,
so more samples do not brighten fully open sky. Exposed walls retain a half-strength
ambient factor; downward faces receive none. Use 0 extras for vertical-only,
4 for the cardinal cross, 8 for the complete inner ring (default), or 12–16 to
add the interleaved outer ring. More rays increase cache-fill cost, including
reflections; target-GPU frame-time tuning remains workload dependent.

A warm point light is created once above the initial camera position. Its height,
color, intensity and radius are in the same configuration file. The default camera
starts inside the existing roofed building: its roof blocks this light and the
sky. Place a lamp through the Tab menu, remove roof blocks, or fly outside to
inspect the lighting. Point lights use
Lambert exposure, a smooth radius cutoff and softened inverse-square attenuation.
Both point and sky visibility use the existing chunk/block/voxel hierarchy. Mono
chunks and blocks remain solid at their available resolution, so coarse geometry
can cast coarse shadows; full voxel generation is never required. Opaque material
bytes block shadows. Glass currently passes visibility rays without tint or
attenuation; transmission-aware shadows are a future extension.

The CPU selects at most `max_lights` (default 8) from the active region and scene
lights using distance divided by radius (region-center distance in GI; camera
distance in the older direct-lighting variants). This keeps the broad sun relevant
alongside nearby lamps and limits per-hit GPU work. Beyond that budget, lights may
pop as the camera moves; tiled/clustered selection is a future scaling option.
Light uniforms upload only when the selected descriptors change. Edit entries in
`World.scene_lights` to change individual lights without shader recompilation.

The Tab menu also offers **Cold White LED Stick**, **Warm White LED Stick**,
**Neutral White LED Stick**, **Red LED Stick**, **Green LED Stick**, and
**Blue LED Stick**. Each is a one-voxel-wide, six-voxel-tall glowing stick with
a matching colored point light at its tip (radius 128 voxels, intensity 3).
They use the usual placement, removal, streaming, and lighting-cache invalidation.

Choose **Sci-Fi Lamp** in the Tab menu and place/remove it normally. It is a sparse
cage with one-voxel-wide edges, two thin bars per face, and a cyan emitter voxel
in the middle. The emitter glows independently of the point-light feature; the
dark cage does not emit. The point light sits inside the emitter. Shadow rays
pass through matching glowing material in the light source's own block, so an
LED shaft does not shadow its own base. Opaque cage bars and other objects still
cast shadows; sky rays receive no emitter exemption.
The existing `.block` format now accepts:

```text
emission_color: 90, 220, 255
# local x, y, z; radius; linear R, G, B; intensity (voxel units)
light: 7.5, 7.5, 7.5, 128, 0.25, 0.8, 1, 3
```

`emission_color` identifies only matching palette entries (before a color override).
`light` is optional and copied with the placed block. Replacing/removing the block
removes its light; voxel removal keeps it until the last luminous voxel disappears.
Active block lights are rebuilt from owned blocks whenever the GPU region changes,
so leaving/reentering the region neither leaks nor duplicates them. World chunks
currently remain cached in CPU memory; placements are not saved between runs.

New lighting variants decode palette colors to linear RGB, combine illumination
and emission, clamp, and gamma-encode once after optical compositing. The face-only
and fully unlit variants retain the legacy display-color path. Inventory icons
use a studio baseline. Visibility stops at the point-light endpoint or sky range /
loaded-region boundary; unloaded geometry cannot occlude light. The traversal has
a conservative step cap (exhaustion means occluded) and a finest-voxel epsilon
that grows with floating-point world-coordinate precision.

### Voxel-face lighting cache

Direct lighting uses `face_cache = true` in
`src/lighting.zig` to enable a persistent GPU cache for combined
point and sky illumination. It evaluates lighting at the center of each finest
voxel face, keyed by signed world voxel coordinates and face normal. Subsequent
frames (including reflected views) reuse that illumination. Albedo, emission,
face shading and optical compositing remain outside the cache. The sky ray count
is unchanged. Point-light attenuation/exposure and all shadow/sky rays always use
the voxel-face center, even if caching is disabled, cold, or full. Set
`face_cache = false` and rebuild to compare performance without changing sampling:
all pixels on the same voxel face receive the same illumination.

For direct lighting, `face_cache_entries = 1 << 18` uses 9 MiB of image-buffer storage on
both GL 4.2 and GL 4.6. Capacity must be a power of two. Full coordinate checks
prevent hash collisions from mixing unrelated faces. Four probes bound lookup
cost; collisions or a full table fall back to evaluating the same face-center
sample. New entries are read starting with the next frame, after an image memory
barrier. There is no spin-wait between fragment invocations. Cold frames still
trace lighting rays and can be slower while the table fills.

World GPU uploads and changes to the selected light descriptors invalidate the
cache with a revision stamp, without clearing or uploading the whole table.
Camera movement and reordering the same lights retain cached illumination. Newly
streamed air and edits outside the GPU region no longer trigger unnecessary
rebuilds/invalidation; moving into another region does. Empty-space primary and
reflection rays now stop at the loaded-world boundary instead of exhausting
hundreds of extra chunk steps, which particularly helps outdoor views.

`zig build test-render` tests actual cache writes/reads, full-frame cold/warm
consistency, forced hash collisions, all six normals, negative coordinates,
light edits/removal, geometry edits, sky-shadow invalidation and region changes.
It also benchmarks the existing building from inside, above its roof and outside
its wall, with background generation and vsync excluded. A Mesa software-rendered
640×360 run measured the desktop roof view at about 48 ms uncached versus 20 ms
cached (2.4×), and the exterior wall at 13 ms versus 8 ms (1.6×), averaged over 20
warm frames. Both comparisons include the traversal-bound fix. These are software
OpenGL measurements, not RTX 3060 frame-rate predictions; cold frames and active
streaming/editing have less reuse.

### Procedural terrain rings

Edited voxel blocks now skip proven-empty 4×4×4 voxel groups (or an entirely
empty 16³ block) using the existing exact summaries. Mixed groups still use
individual voxels, preserving thin detail, emitters and transparent glass.
This is enabled by default; compare with
`zig build run -Doptimize=ReleaseSafe -Dterrain-overlay-skips=false -- --gpu-stats`
and `-Dterrain-overlay-skips=true` on the same edited scene. Unedited terrain
is unaffected. The conservative 16³ cap around terrain overlays remains.
`zig build test-hierarchy -Doptimize=ReleaseSafe` includes pixel/hit parity
checks and alternating before/after software benchmarks for primary and shadow
rays through a sparse edited block, with both GPU upload modes.

Point-light objects and sky lighting currently shade only geometry rings 0 and 1.
For terrain this covers 768 voxels in X/Z plus the 16-voxel hysteresis guard;
the original test-scene preset covers 384 plus the guard. More distant surfaces
use legacy face shading, with no direct-lighting cache work or visibility rays.
Emission and optical materials still render, and distant geometry can still
occlude lights on nearby surfaces. The cutoff follows the stable ring focus and
applies to reflected surfaces too. Configure `direct_geometry_ring_count` in
`src/lighting.zig` (zero restores unlimited direct lighting). Lighting sampling
rings remain independent of this geometry-ring cutoff. The boundary is a hard
quality switch for now. `zig build test-lighting-rings -Doptimize=ReleaseSafe`
checks the cutoff, face brightness, cache behavior and moving focus offscreen.

The runtime now starts in deterministic diamond-square terrain. Use
`zig build run -Doptimize=ReleaseSafe -- --world=terrain --terrain-stats` for
terrain and publication counters, or `zig build run -- --world=test-scene` for
the original floor/wall scene and startup building.

Geometry uses the shared 1/4/16/64/256 voxel hierarchy. The experimental radii
are 384/768/1280/1792 voxels, with chunk proxies filling the remainder of the
32×16×32 streamed window (X/Y/Z). Horizontal reach is approximately 4,096 voxels
from the player, twice the original distance; the full footprint is 8,192×8,192
voxels. The added area uses coarse chunk proxies. Conservative transition, interaction prefetch and
balancing margins expand refinement around these thresholds. Lighting rings
remain independent. Coarse columns and their shadows describe the same published
approximation; they do not claim visibility against ungenerated finest terrain.

`src/rendering.zig` owns the preset and stable focus. Configure seed, elevation,
flat control and cache budget in `src/world/generation/terrainGenerator.zig`, and
worker/payload budgets in `terrainStreaming.zig`. The worker reuses immutable
column trees, samples only missing diamond-square dependencies, and evicts whole
noise caches under a hard allocation cap. Main-thread assembly and GPU upload
are spread across frames; complete coverage replaces the old snapshot atomically.
The player spawns above the generated surface after exact data is ready.

Picking/editing defer while canonical terrain is unavailable. Edited blocks are
an independent in-memory overlay, survive terrain replacement and eviction, and
apply backpressure at their memory limit. There is no disk persistence yet.

`zig build generation-lod-preview -- /tmp/terrain-rings` exports height, terrain
and five-level maps along a path crossing a superchunk boundary and returning,
plus a CSV of samples, timings and memory. `zig build test-hierarchy` includes
published-column ray/shadow references, terrain edits during upload, a moving
worker test, and a bounded mixed-versus-finest rendering benchmark. See
[the terrain implementation record](plans/todo/procedural_terrain_rings.md#9-implementation-record)
for measured results and current limits.
