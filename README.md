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
