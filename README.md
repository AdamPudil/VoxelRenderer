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

Run from the repository root:

```sh
zig build run -- --gpu-info
zig build run -- --shader=thinkpad
zig build run -- --shader=desktop
```

Startup prints the active OpenGL renderer (GPU), vendor, OpenGL version, GLSL
version, and selected shader paths. `--gpu-info` creates a hidden context and
compiles/links the selected shaders, then exits before generating the world.
It needs a working graphical session and GPU driver. These are the capabilities
of the active context, not a list of all installed GPUs or their VRAM sizes.

The default `--shader=auto` selects the desktop profile for a renderer containing
`RTX 3060` when OpenGL 4.6 is available; other renderers use the existing ThinkPad
profile. Selection does not switch GPUs on machines with multiple adapters.

- `thinkpad`: existing `src/graphics/shaders/voxel.vs` (GLSL 3.30) and
  `voxel.fs` (GLSL 4.20), requiring an OpenGL 4.2 context.
- `desktop`: separate `src/graphics/shaders/desktop/voxel.vs` and `voxel.fs`
  entry points targeting GLSL 4.60, requiring OpenGL 4.6.

Startup requests OpenGL 4.6, falling back to 4.2. An explicitly selected desktop
profile fails with a diagnostic if 4.6 is unavailable. Shader compilation errors
are reported rather than silently switching profiles.

The desktop profile initially shares traversal and world-data code with the
ThinkPad profile. It is a starting point for separate desktop shader development;
it does not yet introduce RTX-specific acceleration, increase the VRAM budget,
or promise faster rendering. Changing the GLSL version alone is not an optimization.

## Block models, icons and building

Run `zig build run` from the repository root. Startup creates missing
sample `.block` descriptors and MagicaVoxel `.vox` models in `assets/blocks`:
red, green, blue, white, black, yellow, orange, purple, cyan, pink, gray, brown,
lighter red/green/blue variants, coarse checkerboard, fine checkerboard, and an
open frame, gold, copper, iron, mirror, and eight glass variants (30 entries total).
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
and total internal reflection, and writes previews to `/tmp/voxel-block-smoke/`.
Normal builds continue to use GL, GLFW and GLEW. PNG loading uses the vendored
[stb_image](https://github.com/nothings/stb) implementation and existing PNG writer.

## Startup building

A matte gray building starts at block X=0, Z=0 and extends through X/Z=15:
a **16×16-block exterior**, one-block walls, and a **14×14×4-block clear interior**.
The reddish-brown floor occupies Y=-1 (top at world Y=0); walls occupy Y=0–3
and the gray roof Y=4. A 2-wide, 3-high doorway is centered on the negative-Z
side. The default camera starts inside. The building uses ordinary editable,
opaque, nonreflective blocks and is recreated on startup, like the rest of the
unsaved world.
