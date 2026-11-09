//! GPU checks for packed hierarchy traversal, ring independence and cache identity.
const std = @import("std");
const gl = @import("graphics/gl.zig");
const World = @import("world/world.zig").World;
const Block = @import("world/block.zig").Block;
const Chunk = @import("world/worldChunk.zig").Chunk;
const Voxel = @import("world/voxel.zig").Voxel;
const Policy = @import("graphics/renderPolicy.zig").Uniforms;
const Ring = @import("rendering.zig").Ring;
const wc = @import("world/worldConstants.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});

fn query(program: c_uint, position: [3]i32, normal: [3]f32, mode: i32) ![4]u8 {
    gl.uniform3i(gl.getUniformLocation(program, "uQuery"), position[0], position[1], position[2]);
    try gl.uniform3f(gl.getUniformLocation(program, "uNormal"), normal[0], normal[1], normal[2]);
    gl.uniform1i(gl.getUniformLocation(program, "uProbeMode"), mode);
    c.glViewport(0, 0, 1, 1);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    var pixel: [4]u8 = undefined;
    c.glReadPixels(0, 0, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixel);
    return pixel;
}
fn expectSize(program: c_uint, pos: [3]i32, mode: i32, size: u32, occupied: bool) !void {
    const pixel = try query(program, pos, .{ 0, 1, 0 }, mode);
    const want: u8 = @intFromFloat(@round(@as(f32, @floatFromInt(size)) * 255 / 256));
    if (pixel[0] != want or pixel[1] != @as(u8, if (occupied) 255 else 0)) {
        std.debug.print("Hierarchy query {any} mode={d}: got {any}, size={d} occupied={}\n", .{ pos, mode, pixel, size, occupied });
        return error.HierarchyQueryMismatch;
    }
}
fn checkSkyTraversal(program: c_uint, position: [3]i32) !void {
    // Integer ownership, negative coordinates and fractional starts must match
    // the general DDA, including its endpoint and loaded-region behavior.
    for ([_][3]f32{ .{ 0, 0, 0 }, .{ 0.5, 0.5, 0.5 }, .{ -0.001, -0.001, -0.001 }, .{ 0.999, 0.999, 0.999 } }) |offset| {
        const pixel = try query(program, position, offset, 11);
        if (pixel[0] != pixel[1]) {
            std.debug.print("Vertical sky mismatch at {any} + {any}: {any}\n", .{ position, offset, pixel });
            return error.VerticalSkyTraversalMismatch;
        }
    }
}
fn bind(world: *World, program: c_uint) !void {
    try world.render(.{ 0, 32, 0 });
    while (world.terrain_build_active) try world.render(.{ 0, 32, 0 });
    world.bindGpuTextures();
    const names = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
    for (names, 0..) |name, unit| gl.uniform1i(gl.getUniformLocation(program, name), @intCast(unit));
    const p = world.gpu_region_origin_chunk;
    gl.uniform3i(gl.getUniformLocation(program, "uRegionOriginChunk"), p[0], p[1], p[2]);
    gl.uniform3i(gl.getUniformLocation(program, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
}

pub fn runLightingRings(a: std.mem.Allocator) !void {
    const config = @import("lighting.zig");
    const rendering = @import("rendering.zig");
    const utils = @import("graphics/gl_utils.zig");
    const features = config.Features{ .mode = .direct, .face_shading = false, .direct_geometry_ring_count = 2 };
    const bounded = try utils.createLightingProgram("src/graphics/shaders/tests/hierarchy_probe", features, 0);
    defer gl.deleteProgram(bounded);
    var unlimited_features = features;
    unlimited_features.direct_geometry_ring_count = 0;
    const unlimited = try utils.createLightingProgram("src/graphics/shaders/tests/hierarchy_probe", unlimited_features, 0);
    defer gl.deleteProgram(unlimited);
    var world = try World.init(a);
    defer world.deinit() catch {};
    const lamp = [_]config.PointLight{.{ .position = .{ 0, 32, 0 }, .radius = 256, .intensity = 1, .color = .{ 1, 0, 0 } }};
    for ([_]c_uint{ bounded, unlimited }) |program| {
        gl.useProgram(program);
        try bind(&world, program);
        var policy = Policy.init(program);
        try policy.upload(rendering.terrain_settings, .{ 0, 0, 0 });
        var lights = @import("graphics/pointLights.zig").Uniforms.init(program);
        lights.upload(&lamp, &.{}, .{ 0, 0, 0 });
    }
    // Geometry rings 0/1 end at 768, plus the 16-voxel policy guard.
    // Negative cells own [x,x+1), so -785 still touches the guarded boundary.
    for ([_]i32{ -785, -384, 0, 384, 768, 784 }) |x| {
        gl.useProgram(unlimited);
        const reference = try query(unlimited, .{ x, 0, 0 }, .{ 0, 1, 0 }, 12);
        gl.useProgram(bounded);
        const actual = try query(bounded, .{ x, 0, 0 }, .{ 0, 1, 0 }, 12);
        if (!std.mem.eql(u8, &reference, &actual)) return error.NearRingLightingChanged;
    }
    gl.useProgram(bounded);
    var cache = try @import("graphics/lightingCache.zig").Cache.init(bounded);
    defer cache.deinit();
    cache.population_budget = config.face_cache_entries;
    try cache.begin(world.gpu_revision, 1);
    for ([_][3]i32{ .{ 785, 0, 0 }, .{ -786, 0, 0 }, .{ 0, 1000, 785 }, .{ 0, -1000, -786 }, .{ 600, 0, 600 } }) |position| {
        for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } }) |normal| {
            const diff = @max((normal[0] + normal[1] + 0.8 * normal[2]) / @sqrt(@as(f32, 2.64)), 0);
            const tint: f32 = if (normal[0] != 0) 0.8 else if (normal[1] != 0) 1.2 else 1;
            const expected: i32 = @intFromFloat(@round(128 * (0.25 + diff * 0.75) * tint));
            const pixel = try query(bounded, position, normal, 12);
            for (pixel[0..3]) |channel| if (@abs(@as(i32, channel) - expected) > 1) return error.DistantFaceShadingMismatch;
            if (pixel[3] != 255) return error.DistantOpacityChanged;
        }
    }
    const stamps = try a.alloc(u32, config.face_cache_entries);
    defer a.free(stamps);
    cache.end();
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(stamps.len * 4), stamps.ptr);
    for (stamps) |stamp| if (stamp == cache.clock.frame) return error.DistantLightingCachePopulated;
    const matte = try query(bounded, .{ 785, 0, 0 }, .{ 0, -1, 0 }, 12);
    const emissive = try query(bounded, .{ 785, 0, 0 }, .{ 0, -1, 0 }, 13);
    if (emissive[0] <= matte[0] or emissive[3] != matte[3]) return error.DistantEmissionLost;
    gl.uniform1i(gl.getUniformLocation(bounded, "uIconMode"), 1);
    const icon = try query(bounded, .{ 785, 0, 0 }, .{ 0, -1, 0 }, 12);
    gl.uniform1i(gl.getUniformLocation(bounded, "uIconMode"), 0);
    if (!std.mem.eql(u8, &icon, &.{ 128, 128, 128, 255 })) return error.LightingCutoffAffectedIcon;
    // Move the ring focus: the same distant surface must resume full lighting.
    for ([_]c_uint{ bounded, unlimited }) |program| {
        gl.useProgram(program);
        var policy = Policy.init(program);
        try policy.upload(rendering.terrain_settings, .{ 785, 0, 0 });
    }
    gl.useProgram(unlimited);
    const moved_reference = try query(unlimited, .{ 785, 0, 0 }, .{ 0, 1, 0 }, 12);
    gl.useProgram(bounded);
    try cache.begin(world.gpu_revision, 1);
    const moved = try query(bounded, .{ 785, 0, 0 }, .{ 0, 1, 0 }, 12);
    cache.end();
    if (!std.mem.eql(u8, &moved_reference, &moved)) return error.MovingLightingCutoffMismatch;
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(stamps.len * 4), stamps.ptr);
    if (std.mem.indexOfScalar(u32, stamps, cache.clock.frame) == null) return error.NearLightingCacheNotPopulated;
    try cache.begin(world.gpu_revision, 1);
    const warm = try query(bounded, .{ 785, 0, 0 }, .{ 0, 1, 0 }, 12);
    cache.end();
    if (!std.mem.eql(u8, &moved, &warm)) return error.LightingCutoffCacheMismatch;
    // Compile the application configuration with its full nine sky samples.
    for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel" }) |path| {
        const program = try utils.createLightingProgram(path, features, config.sky_extra_ray_count);
        gl.deleteProgram(program);
    }
    if (c.glGetError() != c.GL_NO_ERROR) return error.LightingRingGlError;
    std.debug.print("Lighting cutoff: near direct parity, signed/radial boundaries, six face normals, no distant cache writes, emission and moving focus passed\n", .{});
}

pub fn run(a: std.mem.Allocator) !void {
    const program = try @import("graphics/gl_utils.zig").createLightingProgram("src/graphics/shaders/tests/hierarchy_probe", .{ .face_shading = false, .point_lights = true, .sky_lighting = true }, 0);
    defer gl.deleteProgram(program);
    gl.useProgram(program);
    var policy = Policy.init(program);
    var world = try World.init(a);
    defer world.deinit() catch {};
    const white = Voxel.rgb(255, 255, 255);
    try world.chunks.put(.{ .x = -1, .y = -1, .z = -1 }, Chunk.initMono(0, white));
    const mono = Block.initMono(1, white);
    // A uniform 64-cube embedded in a mixed chunk, aligned across negative X.
    for (0..4) |z| for (0..4) |y| for (0..4) |x|
        try world.setBlock(.{ @as(i32, @intCast(x)) - 4, @intCast(y), @intCast(z) }, &mono);
    try world.setBlock(.{ 1, 0, 0 }, &mono);
    var detailed = try Block.initVoxel(a, 2);
    defer detailed.deinit(a);
    const vb = detailed.blockData.voxel;
    vb.setPaletteEntry(1, white);
    for (0..4) |z| for (0..4) |y| for (0..4) |x| vb.setVoxel(x, y, z, 1);
    vb.setVoxel(15, 15, 15, 1); // thin detail must survive every coarse policy
    try world.setBlock(.{ 0, 0, 0 }, &detailed);
    try bind(&world, program);
    for ([_]i32{ -257, -256, -17, -16, -1, 0, 1, 15, 16, 63, 64, 255, 256 }) |position| {
        try checkSkyTraversal(program, .{ position, -32, 0 });
        try checkSkyTraversal(program, .{ 0, position, 0 });
    }
    try expectSize(program, .{ -1, -1, -1 }, 0, 256, true);
    try expectSize(program, .{ -1, 63, 63 }, 0, 64, true);
    try expectSize(program, .{ 31, 0, 0 }, 0, 16, true);
    try expectSize(program, .{ 3, 3, 3 }, 0, 4, true);
    try expectSize(program, .{ 15, 15, 15 }, 0, 1, true);
    try expectSize(program, .{ 14, 15, 15 }, 0, 1, false);
    try expectSize(program, .{ 4, 4, 4 }, 0, 4, false);
    try expectSize(program, .{ -65, 0, 0 }, 0, 64, false);
    // Compare complete hit maps against the original traversal, including rays
    // crossing 4/16/64/256 boundaries in both directions and negative space.
    const edge = 96;
    const reference_pixels = try a.alloc(u8, edge * edge * 4);
    defer a.free(reference_pixels);
    const hierarchy_pixels = try a.alloc(u8, edge * edge * 4);
    defer a.free(hierarchy_pixels);
    for ([_][3]f32{ .{ -80, 80, 80 }, .{ 80, 80, 80 }, .{ -0.5, 80, -0.5 }, .{ -128, -0.5, 128 } }) |eye| {
        gl.uniform1i(gl.getUniformLocation(program, "uProbeMode"), 5);
        try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), edge, edge);
        try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
        try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), -eye[0], -eye[1], -eye[2]);
        c.glViewport(0, 0, edge, edge);
        gl.uniform1i(gl.getUniformLocation(program, "uHierarchyReference"), 1);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glReadPixels(0, 0, edge, edge, c.GL_RGBA, c.GL_UNSIGNED_BYTE, reference_pixels.ptr);
        gl.uniform1i(gl.getUniformLocation(program, "uHierarchyReference"), 0);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glReadPixels(0, 0, edge, edge, c.GL_RGBA, c.GL_UNSIGNED_BYTE, hierarchy_pixels.ptr);
        if (!std.mem.eql(u8, reference_pixels, hierarchy_pixels)) return error.HierarchyReferenceMismatch;
    }
    const exact = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = 1 }};
    for (@import("rendering.zig").cell_sizes) |size| {
        const coarse = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = size }};
        try policy.upload(.{ .geometry_rings = &coarse, .lighting_rings = &coarse, .interaction_radius_voxels = 0, .hysteresis_voxels = 0, .transition_width_voxels = 0 }, .{ 1024, 32, 1024 });
        try expectSize(program, .{ 15, 15, 15 }, 1, 1, true);
        try expectSize(program, .{ 14, 15, 15 }, 1, 1, false);
        try expectSize(program, .{ -1, -1, -1 }, 2, size, true);
        // The wall remains an exact shadow occluder under every ring setting.
        const shadow = try query(program, .{ -70, 30, 30 }, .{ 1, 0, 0 }, 3);
        if (shadow[0] != 0) return error.CoarseShadowLeak;
    }
    // Geometry LOD can replace mixed material only on completely occupied nodes.
    vb.clearAll();
    vb.setPaletteEntry(2, Voxel.rgb(32, 32, 32));
    for (0..16) |z| for (0..16) |y| for (0..16) |x| vb.setVoxel(x, y, z, if (x % 2 == 0) 1 else 2);
    try world.setBlock(.{ 0, 0, 0 }, &detailed);
    try bind(&world, program);
    const coarse = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = 16 }};
    try policy.upload(.{ .geometry_rings = &coarse, .lighting_rings = &exact, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ 1024, 0, 1024 });
    try expectSize(program, .{ 1, 15, 1 }, 1, 16, true);
    try expectSize(program, .{ 1, 15, 1 }, 0, 1, true);
    try expectSize(program, .{ 1, 15, 1 }, 2, 1, true);
    try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &coarse, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ 1024, 0, 1024 });
    try expectSize(program, .{ 1, 15, 1 }, 1, 1, true);
    try expectSize(program, .{ 1, 15, 1 }, 2, 16, true);
    // Crossing from one coarse geometry level to another must start from the
    // already-visible child, not jump back to the finest material at weight zero.
    const transition_rings = [_]Ring{ .{ .outer_radius_voxels = 100, .cell_size_voxels = 4 }, .{ .outer_radius_voxels = 8192, .cell_size_voxels = 16 } };
    try policy.upload(.{ .geometry_rings = &transition_rings, .lighting_rings = &exact, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ -99.999, 0, 1 });
    const geometry_before = try query(program, .{ 1, 15, 1 }, .{ 0, 1, 0 }, 1);
    try policy.upload(.{ .geometry_rings = &transition_rings, .lighting_rings = &exact, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ -100.001, 0, 1 });
    const geometry_after = try query(program, .{ 1, 15, 1 }, .{ 0, 1, 0 }, 1);
    if (@abs(@as(i32, geometry_before[2]) - geometry_after[2]) > 1) return error.GeometryTransitionPop;
    try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &coarse, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ 1024, 0, 1024 });
    // Editing invalidates the occupied patch and its ancestors immediately.
    _ = try world.removeVoxel(.{ 2, 15, 2 });
    try bind(&world, program);
    try expectSize(program, .{ 1, 15, 1 }, 2, 1, true);
    try expectSize(program, .{ 2, 15, 2 }, 1, 1, false);
    // A fully transparent glass voxel and tiny emitter must force descent.
    for ([_]bool{ false, true }) |emission| {
        var special = white;
        if (emission) special.luminescence = 255 else {
            special.opacity = 0;
            special.refractive_index = Voxel.encodeIor(1.5);
        }
        vb.setPaletteEntry(3, special);
        vb.setVoxel(1, 15, 1, 3);
        try world.setBlock(.{ 0, 0, 0 }, &detailed);
        try bind(&world, program);
        try policy.upload(.{ .geometry_rings = &coarse, .lighting_rings = &coarse, .interaction_radius_voxels = 0, .hysteresis_voxels = 0 }, .{ 1024, 0, 1024 });
        try expectSize(program, .{ 1, 15, 1 }, 1, 1, true);
        try expectSize(program, .{ 1, 15, 1 }, 2, 1, true);
    }
    // Cache entries at the same origin/face but different levels must not alias.
    var cache = try @import("graphics/lightingCache.zig").Cache.init(program);
    defer cache.deinit();
    world.bindGpuTextures();
    if (cache.frame_loc < 0 or cache.budget_loc < 0) return error.HierarchyCacheNotCompiled;
    var lights = @import("graphics/pointLights.zig").Uniforms.init(program);
    try world.scene_lights.append(.{ .position = .{ -230, 50, -230 }, .color = .{ 1, 0, 0 }, .radius = 512, .intensity = 0.3 });
    lights.upload(world.scene_lights.items, world.block_lights.items, .{ 0, 32, 0 });
    for (@import("rendering.zig").cell_sizes) |size| {
        const rings = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = size }};
        try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &rings, .hysteresis_voxels = 0, .transition_width_voxels = 0 }, .{ 1024, 0, 1024 });
        c.__glewUniform1ui.?(cache.frame_loc, 0);
        const reference = try query(program, .{ -256, -1, -256 }, .{ 0, 1, 0 }, 4);
        for (0..3) |_| {
            try cache.begin(world.gpu_revision, lights.revision);
            const cached = try query(program, .{ -256, -1, -256 }, .{ 0, 1, 0 }, 4);
            cache.end();
            if (!std.mem.eql(u8, &reference, &cached)) return error.HierarchyCacheAlias;
        }
    }
    const saved_light = world.scene_lights.items[0];
    world.scene_lights.items[0] = .{ .position = .{ -238, 1, -238 }, .color = .{ 1, 0, 0 }, .radius = 32, .intensity = 0.2 };
    lights.upload(world.scene_lights.items, world.block_lights.items, .{ 0, 32, 0 });
    c.__glewUniform1ui.?(cache.frame_loc, 0);
    try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &transition_rings, .hysteresis_voxels = 0 }, .{ -339.999, 0, -239 });
    const lighting_before = try query(program, .{ -240, -1, -240 }, .{ 0, 1, 0 }, 4);
    try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &transition_rings, .hysteresis_voxels = 0 }, .{ -340.001, 0, -239 });
    const lighting_after = try query(program, .{ -240, -1, -240 }, .{ 0, 1, 0 }, 4);
    for (lighting_before, lighting_after) |before, after| if (@abs(@as(i32, before) - after) > 1) return error.LightingTransitionPop;
    world.scene_lights.items[0] = saved_light;
    lights.upload(world.scene_lights.items, world.block_lights.items, .{ 0, 32, 0 });

    // Identical fixed surface view, cold and warm, with the same exact visibility.
    // Report software-GPU timings and populated cells, not an assumed speedup.
    const bench_size = 128;
    const pixels = try a.alloc(u8, bench_size * bench_size * 4);
    defer a.free(pixels);
    const baseline = try a.alloc(u8, pixels.len);
    defer a.free(baseline);
    const stamps = try a.alloc(u32, @import("lighting.zig").face_cache_entries);
    defer a.free(stamps);
    for ([_]u32{ 1, 256 }) |size| {
        const rings = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = size }};
        try policy.upload(.{ .geometry_rings = &exact, .lighting_rings = &rings, .hysteresis_voxels = 0, .transition_width_voxels = 0 }, .{ 1024, 0, 1024 });
        gl.uniform3i(gl.getUniformLocation(program, "uQuery"), -256, -1, -256);
        gl.uniform1i(gl.getUniformLocation(program, "uProbeMode"), 6);
        c.glViewport(0, 0, bench_size, bench_size);
        // Warm up driver specialization before measuring a fresh revision.
        try cache.begin(world.gpu_revision + size + 1000, lights.revision);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        cache.end();
        c.glFinish();
        var timer = try std.time.Timer.start();
        try cache.begin(world.gpu_revision + size + 2000, lights.revision);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        cache.end();
        c.glFinish();
        var uploaded_budget: c_uint = 0;
        c.__glewGetUniformuiv.?(program, cache.budget_loc, &uploaded_budget);
        if (uploaded_budget != cache.population_budget) return error.IncorrectCacheBudget;
        const draw_error = c.glGetError();
        if (draw_error != c.GL_NO_ERROR) {
            std.debug.print("Hierarchy draw GL error {x}\n", .{draw_error});
            return error.HierarchyGlError;
        }
        const cold_ms = @as(f64, @floatFromInt(timer.read())) / 1e6;
        for (0..4) |_| {
            try cache.begin(world.gpu_revision + size + 2000, lights.revision);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
        }
        c.glFinish();
        timer.reset();
        for (0..10) |_| {
            try cache.begin(world.gpu_revision + size + 2000, lights.revision);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
        }
        c.glFinish();
        const warm_ms = @as(f64, @floatFromInt(timer.read())) / 1e7;
        c.glReadPixels(0, 0, bench_size, bench_size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
        c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
        c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(stamps.len * 4), stamps.ptr);
        var uploaded_frame: c_uint = 0;
        c.__glewGetUniformuiv.?(program, cache.frame_loc, &uploaded_frame);
        if (uploaded_frame != cache.clock.frame) return error.IncorrectCacheFrame;
        var entries: usize = 0;
        for (stamps) |stamp| if (stamp >= cache.clock.valid_from and stamp <= cache.clock.frame) {
            entries += 1;
        };
        var error_sum: usize = 0;
        if (size == 1) {
            if (entries == 0) return error.FineLightingNotCached;
            @memcpy(baseline, pixels);
        } else {
            for (baseline, pixels) |before, after| error_sum += @abs(@as(i32, before) - @as(i32, after));
            if (entries != 1) return error.CoarseLightingNotShared;
        }
        std.debug.print("Hierarchy lighting 128x128 size={d}: cold={d:.2} ms warm={d:.2} ms entries={d}, mean RGB byte difference={d:.2}\n", .{ size, cold_ms, warm_ms, entries, @as(f64, @floatFromInt(error_sum)) / (bench_size * bench_size * 3) });
    }
    // With a zero population budget, fallback lighting still matches and writes
    // no entries; subsequent frames may resume population without stale reuse.
    cache.population_budget = 0;
    try cache.begin(world.gpu_revision + 9999, lights.revision);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    cache.end();
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(stamps.len * 4), stamps.ptr);
    for (stamps) |stamp| if (stamp == cache.clock.frame) return error.CachePopulationBudgetExceeded;
    // An upload may span frames. Neither half of its geometry/light snapshot
    // becomes visible before completion; edits during upload remain queued.
    const old_revision = world.gpu_revision;
    const old_lights = world.block_lights.items.len;
    var lamp = Block.initMono(7, white);
    lamp.light = .{};
    try world.setBlock(.{ 32, 0, 32 }, &lamp);
    world.upload_budget_bytes = 1024;
    try bind(&world, program);
    if (!world.upload_active or world.gpu_revision != old_revision or world.last_upload_bytes > 1024 or world.block_lights.items.len != old_lights) return error.PartialUploadPublished;
    try expectSize(program, .{ 512, 0, 512 }, 0, 256, false);
    try world.setBlock(.{ 33, 0, 32 }, &mono);
    world.upload_budget_bytes = 65536;
    var frames: usize = 0;
    while (world.upload_active and frames < 1000) : (frames += 1) {
        try bind(&world, program);
        if (world.last_upload_bytes > world.upload_budget_bytes) return error.UploadBudgetExceeded;
    }
    if (world.upload_active or world.gpu_revision != old_revision + 1 or world.block_lights.items.len != old_lights + 1) return error.UploadNeverPublished;
    try expectSize(program, .{ 512, 0, 512 }, 0, 16, true);
    try expectSize(program, .{ 528, 0, 512 }, 0, 16, false);
    world.upload_budget_bytes = std.math.maxInt(usize);
    try bind(&world, program);
    try expectSize(program, .{ 528, 0, 512 }, 0, 16, true);
    if (world.gpu_revision != old_revision + 2) return error.EditDuringUploadLost;
    try runTerrain(a, program, true);
    try runTerrain(a, program, false);
    try benchmarkTerrain(a, program);
    try runMovingTerrain(a);
    std.debug.print("Hierarchy: all five levels, negative bounds, thin detail, exact shadows, edits, glass/emission, independent rings and cache levels passed\n", .{});
}

fn runTerrain(a: std.mem.Allocator, program: c_uint, incremental: bool) !void {
    const rendering = @import("rendering.zig");
    const generator = @import("world/generation/terrainGenerator.zig");
    const terrain = @import("world/terrainHierarchy.zig");
    const streaming = @import("world/generation/terrainStreaming.zig");
    var policy_probe = Policy.init(program);
    var shared_focus = rendering.FocusState{};
    for ([_]f32{ 0, 16, 17 }) |movement| {
        const shared = try shared_focus.resolve(rendering.terrain_settings, .{ movement, 0, 0 });
        try policy_probe.uploadSnapshot(&shared);
        for (rendering.cell_sizes[1..]) |side| for ([_]i32{ 384, 400, 416, 432, 768, 800, 1280, 1312, 1792, 1824, 8192 }) |boundary| {
            const origin = [3]i32{ rendering.aligned(boundary, side), 0, 0 };
            const pixel = try query(program, origin, .{ @floatFromInt(side), 0, 0 }, 9);
            const weight = rendering.geometryWeight(&shared, origin, side);
            const want: i32 = @intFromFloat(@round(weight * 255));
            if (@abs(want - @as(i32, pixel[0])) > 1) return error.CpuGpuPolicyMismatch;
            if (weight < 1 and !shared.needsSplit(origin[0], origin[2], side)) return error.MissingTransitionDemand;
        };
    }
    var world = try World.init(a);
    world.incremental_uploads = incremental;
    defer world.deinit() catch {};
    try world.enableTerrain(.{ .flat = true });
    var focus = rendering.FocusState{};
    const fine = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = 1 }};
    const snapshot = try focus.resolve(.{ .geometry_rings = &fine }, .{ 0, 32, 0 });
    world.updateTerrain(snapshot, .{ 0, 32, 0 });
    const stream = world.terrain_stream.?;
    const batch = try a.create(streaming.Batch);
    batch.* = .{ .request = stream.request.?, .config_revision = 1, .coarse = false };
    stream.resident = batch;
    for (rendering.cell_sizes, 0..) |side, i| {
        const x = (@as(i32, @intCast(i)) - 2) * 256;
        var sampler = try generator.Sampler.init(a, .{ .flat = true, .base_height = @intCast(side + @max(side / 2, 1)) });
        defer sampler.deinit();
        var builder = try terrain.Builder.init(a, x, 0, snapshot, side, 2 * 1024 * 1024);
        defer builder.deinit();
        while (!try builder.advance(&sampler, 4096, std.time.ns_per_s)) {}
        const index: usize = @intCast((@divFloor(x, 256) - batch.request.origin[0]) - batch.request.origin[1] * streaming.window_side);
        batch.tiles[index] = try builder.finish(1);
        batch.ready[index] = true;
    }
    // Exercise the outer corners beyond the previous 16-chunk window. Alternate
    // signed heights to catch incorrect X/Y/Z strides in packed chunk headers.
    const edges = [_]usize{ 0, streaming.window_side - 1 };
    for (edges) |rz| for (edges) |rx| {
        const x = (batch.request.origin[0] + @as(i32, @intCast(rx))) * 256;
        const z = (batch.request.origin[1] + @as(i32, @intCast(rz))) * 256;
        var sampler = try generator.Sampler.init(a, .{ .flat = true, .base_height = if (rx == rz) 256 else -256 });
        defer sampler.deinit();
        var builder = try terrain.Builder.init(a, x, z, snapshot, 256, 1024);
        defer builder.deinit();
        while (!try builder.advance(&sampler, 4096, std.time.ns_per_s)) {}
        const index = rx + rz * streaming.window_side;
        batch.tiles[index] = try builder.finish(1);
        batch.ready[index] = true;
    };
    var policy = Policy.init(program);
    try policy.uploadSnapshot(&snapshot);
    try bind(&world, program);
    for (edges) |rz| for (edges) |rx| {
        const tile = &batch.tiles[rx + rz * streaming.window_side];
        const height = tile.nodes[0].height;
        try expectSize(program, .{ tile.x + 10, height - 1, tile.z + 10 }, 0, 256, true);
        try expectSize(program, .{ tile.x + 10, height, tile.z + 10 }, 0, 256, false);
        const eye = [3]f32{ 0.5, 1600.5, 0.5 };
        const direction = [3]f32{ @as(f32, @floatFromInt(tile.x)) + 10, @as(f32, @floatFromInt(height)) - 1602, @as(f32, @floatFromInt(tile.z)) + 10 };
        const hit = referenceTerrainHit(batch, eye, direction, 8192) orelse return error.MissingDistantTerrainReference;
        try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
        const pixel = try query(program, .{ 0, 0, 0 }, direction, 10);
        var expected = [4]u8{ 0, 0, 0, 255 };
        for (0..3) |axis| expected[axis] = @intCast(@mod(hit[axis], 251));
        if (!std.mem.eql(u8, &expected, &pixel)) {
            std.debug.print("Distant terrain ray target=({d},{d}) height={d}: reference={any}, expected={any}, got={any}\n", .{ tile.x, tile.z, height, hit, expected, pixel });
            return error.DistantTerrainRayMismatch;
        }
    };
    for (rendering.cell_sizes, 0..) |side, i| {
        const x = (@as(i32, @intCast(i)) - 2) * 256 + 10;
        const height: i32 = @intCast(if (side == 1) 2 else side);
        for ([_]i32{ 0, 1 }) |mode| {
            try expectSize(program, .{ x, height - 1, 10 }, mode, side, true);
            try expectSize(program, .{ x, height, 10 }, mode, side, false);
        }
        const shadow = try query(program, .{ x, height + 4, 10 }, .{ 0, -1, 0 }, 3);
        if (shadow[0] != 0) return error.TerrainShadowLeak;
        const sky = try query(program, .{ x, height + 4, 10 }, .{ 0, 1, 0 }, 3);
        if (sky[0] != 255) return error.TerrainSkyOccluded;
        try checkSkyTraversal(program, .{ x, height, 10 });
        try checkSkyTraversal(program, .{ x, height - 1, 10 });
    }
    // Compare primary hit positions and shadow decisions with an independent
    // unit-voxel DDA over the specified published column union.
    const origins = [_][3]f32{
        .{ -512, 3, 10 },        .{ 0, 10, 10 },           .{ 256, 40, 0 },         .{ 256, 40, 256 },
        .{ -512.5, 3.5, 10.5 },  .{ -255.5, 3.5, 10.5 },   .{ -0.5, 10.5, 10.5 },   .{ 0.5, 10.5, 10.5 },
        .{ 255.5, 40.5, 10.5 },  .{ 256.5, 40.5, 10.5 },   .{ 511.5, 100.5, 10.5 }, .{ 512.5, 100.5, 10.5 },
        .{ -100.5, 90.5, -0.5 }, .{ -100.5, 90.5, 256.5 },
    };
    for (origins) |eye| for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, -1, 0 }, .{ 1, -1, 1 }, .{ -1, -1, -1 }, .{ 0, -1, 1 } }) |direction| {
        try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
        const expected = referenceTerrainHit(batch, eye, direction, 512);
        const pixel = try query(program, .{ 0, 0, 0 }, direction, 7);
        var encoded = [4]u8{ 0, 0, 0, 0 };
        if (expected) |hit| {
            for (0..3) |axis| encoded[axis] = @intCast(@mod(hit[axis], 251));
            encoded[3] = 255;
        }
        if (!std.mem.eql(u8, &encoded, &pixel)) {
            std.debug.print("Terrain ray eye={any} dir={any}: expected {any}, got {any}\n", .{ eye, direction, encoded, pixel });
            return error.TerrainRayMismatch;
        }
        const visibility = try query(program, .{ 0, 0, 0 }, direction, 8);
        if (visibility[0] != @as(u8, if (expected == null) 255 else 0)) return error.TerrainVisibilityMismatch;
    };
    // Exact edits override terrain including explicit air, and cannot disappear
    // when the base is replaced. A stale staged edit snapshot is never published.
    const initial_roots = world.terrain_build_roots;
    const empty = Block.initEmpty(0);
    try world.setBlock(.{ -32, 0, 0 }, &empty);
    world.upload_budget_bytes = 1024;
    const revision = world.gpu_revision;
    try bind(&world, program);
    try expectSize(program, .{ -512, 1, 0 }, 0, 1, true);
    try world.setBlock(.{ -31, 0, 0 }, &empty);
    try bind(&world, program); // abort obsolete edit snapshot
    if (world.gpu_revision != revision) return error.StaleTerrainEditPublished;
    if (world.upload_active or world.last_upload_bytes != 0) return error.StaleTerrainUploadContinued;
    try expectSize(program, .{ -512, 1, 0 }, 0, 1, true);
    world.upload_budget_bytes = std.math.maxInt(usize);
    try bind(&world, program); // complete newest snapshot
    try expectSize(program, .{ -512, 1, 0 }, 0, 16, false);
    try expectSize(program, .{ -496, 1, 0 }, 0, 16, false);
    try expectSize(program, .{ -480, 1, 0 }, 0, 1, true);
    const stable = world.gpu_revision;
    try bind(&world, program);
    if (world.gpu_revision != stable or world.last_upload_bytes != 0) return error.StationaryTerrainUploaded;
    // A new focus invalidates an in-flight transfer even when no upload budget
    // remains. Keep the old GPU geometry while waiting for the new worker result.
    try world.setBlock(.{ -30, 0, 0 }, &empty);
    world.upload_budget_bytes = 1024;
    try bind(&world, program);
    if (!world.upload_active) return error.ExpectedPendingTerrainUpload;
    const moved = try focus.resolve(.{ .geometry_rings = &fine }, .{ 20, 32, 0 });
    world.updateTerrain(moved, moved.focus);
    world.upload_budget_bytes = 0;
    try bind(&world, program);
    if (world.upload_active or world.last_upload_bytes != 0) return error.StaleTerrainUploadContinued;
    if (world.gpu_revision != stable) return error.StaleTerrainFocusPublished;
    try expectSize(program, .{ -480, 1, 0 }, 0, 1, true);
    // Complete the new request with the same tiles: the all-fine demand has not
    // changed shape. The pending edit must appear only with this replacement.
    const replacement = try a.create(streaming.Batch);
    replacement.* = .{ .request = stream.request.?, .config_revision = 1, .coarse = false };
    for (&batch.tiles, batch.ready, 0..) |tile, ready, i| if (ready) {
        replacement.tiles[i] = tile.retain();
        replacement.ready[i] = true;
    };
    stream.completed = replacement;
    world.upload_budget_bytes = std.math.maxInt(usize);
    try bind(&world, program);
    if (world.gpu_revision != stable + 1) return error.TerrainReplacementNeverPublished;
    try expectSize(program, .{ -480, 1, 0 }, 0, 16, false);
    if (world.gpu_residency) |*resident| {
        if (resident.last_stats.new_tiles != 0 or resident.last_stats.payload_bytes != 65536 or resident.last_stats.metadata_bytes != 262144) return error.EditUploadedUnchangedTerrain;
        if (!std.mem.eql(?u32, &initial_roots, &world.terrain_build_roots)) return error.RetainedTerrainRelocated;
    }
    // Voxel payload relocation spans the bitmap, palette, index and header pools.
    var lamp = try Block.initVoxel(a, 900);
    defer lamp.deinit(a);
    var emissive = Voxel.rgb(40, 100, 200);
    emissive.luminescence = 255;
    lamp.blockData.voxel.setPaletteEntry(1, emissive);
    lamp.blockData.voxel.setVoxel(1, 2, 3, 1);
    var glass = Voxel.rgb(180, 220, 255);
    glass.opacity = 0;
    glass.refractive_index = Voxel.encodeIor(1.5);
    lamp.blockData.voxel.setPaletteEntry(2, glass);
    lamp.blockData.voxel.setVoxel(9, 2, 3, 2);
    lamp.light = .{ .position = .{ 1.5, 2.5, 3.5 } };
    try world.setBlock(.{ -32, 2, 0 }, &lamp);
    try bind(&world, program);
    try expectSize(program, .{ -511, 34, 3 }, 0, 1, true);
    try expectSize(program, .{ -512, 34, 3 }, 0, 1, false);
    for ([_]i32{ 0, 1 }) |mode| {
        try expectSize(program, .{ -508, 34, 3 }, mode, if (@import("build_options").terrain_overlay_skips) 4 else 1, false);
        try expectSize(program, .{ -503, 34, 3 }, mode, 1, true); // clear glass is occupied
    }
    if (world.block_lights.items.len != 1 or world.block_lights.items[0].position[0] != -510.5) return error.IncrementalLampPublication;
    const old_header = if (world.gpu_residency) |*resident| resident.records.get(.{ .kind = .block, .coord = .{ -32, 2, 0 }, .version = world.edited_blocks.get(.{ -32, 2, 0 }).? }).?.header else [_]u32{0} ** 4;
    const other = Block.initMono(901, Voxel.rgb(200, 20, 10));
    try world.setBlock(.{ -31, 2, 0 }, &other);
    try bind(&world, program);
    try expectSize(program, .{ -511, 34, 3 }, 0, 1, true);
    try expectSize(program, .{ -496, 34, 3 }, 0, 16, true);
    try benchmarkOverlaySkips(a, &world, program);
    if (world.gpu_residency) |*resident| {
        const record = resident.records.get(.{ .kind = .block, .coord = .{ -32, 2, 0 }, .version = world.edited_blocks.get(.{ -32, 2, 0 }).? }).?;
        if (!std.mem.eql(u32, &old_header, &record.header) or resident.last_stats.payload_bytes != 65536) return error.UnchangedEditReuploaded;
    }
    try world.setBlock(.{ -32, 2, 0 }, &empty);
    try bind(&world, program);
    if (world.block_lights.items.len != 0) return error.RemovedIncrementalLampRetained;
    try expectSize(program, .{ -511, 34, 3 }, 0, 16, false);
    std.debug.print("Terrain: all five proxy levels, primary/shadow reference rays, sky spans, exact edits and atomic publication passed (incremental={})\n", .{incremental});
}

fn benchmarkOverlaySkips(a: std.mem.Allocator, world: *World, restore_program: c_uint) !void {
    const utils = @import("graphics/gl_utils.zig");
    const reference = try utils.createLightingProgram("src/graphics/shaders/tests/hierarchy_probe", .{ .face_shading = false, .terrain_overlay_skips = false }, 0);
    defer gl.deleteProgram(reference);
    const candidate = try utils.createLightingProgram("src/graphics/shaders/tests/hierarchy_probe", .{ .face_shading = false, .terrain_overlay_skips = true }, 0);
    defer gl.deleteProgram(candidate);
    defer gl.useProgram(restore_program);
    const programs = [_]c_uint{ reference, candidate };
    const reference_pixels = try a.alloc(u8, 96 * 96 * 4);
    defer a.free(reference_pixels);
    const pixels = try a.alloc(u8, reference_pixels.len);
    defer a.free(pixels);
    for (programs) |program| {
        gl.useProgram(program);
        try bind(world, program);
        try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), -512, 32, 0);
        try gl.uniform3f(gl.getUniformLocation(program, "uNormal"), 1, 0, 0);
    }
    // Signed faces, voxel-group boundaries, diagonal/corner crossings and sky
    // traversal must agree with the previous per-voxel overlay lookup.
    for ([_][3]f32{ .{ -512, 34, 3 }, .{ -508, 34, 3 }, .{ -496, 34, 3 }, .{ -508.5, 34.5, 3.5 } }) |eye| {
        for ([_][3]f32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 1, 1, 1 }, .{ -1, -1, -1 }, .{ 0, 1, 0 } }) |direction| {
            for ([_]i32{ 7, 8 }) |mode| {
                var values: [2][4]u8 = undefined;
                for (programs, 0..) |program, i| {
                    gl.useProgram(program);
                    try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
                    values[i] = try query(program, .{ 0, 0, 0 }, direction, mode);
                }
                if (!std.mem.eql(u8, &values[0], &values[1])) return error.OverlaySkipRayMismatch;
            }
        }
    }
    for ([_]i32{ 14, 15 }) |mode| {
        for (programs, 0..) |program, i| {
            gl.useProgram(program);
            try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), -512, 32, 0);
            try gl.uniform3f(gl.getUniformLocation(program, "uNormal"), 1, 0, 0);
            gl.uniform1i(gl.getUniformLocation(program, "uProbeMode"), mode);
            c.glViewport(0, 0, 96, 96);
            for (0..4) |_| c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            c.glReadPixels(0, 0, 96, 96, c.GL_RGBA, c.GL_UNSIGNED_BYTE, if (i == 0) reference_pixels.ptr else pixels.ptr);
        }
        if (!std.mem.eql(u8, reference_pixels, pixels)) return error.OverlaySkipImageMismatch;
        var samples: [2][6]f64 = undefined;
        for (0..6) |round| {
            // Alternate order to reduce systematic warmup/order bias.
            for (0..2) |offset| {
                const i = (round + offset) % 2;
                gl.useProgram(programs[i]);
                c.glFinish();
                var timer = try std.time.Timer.start();
                for (0..8) |_| c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
                c.glFinish();
                samples[i][round] = @as(f64, @floatFromInt(timer.read())) / 1e6 / 8;
            }
        }
        for (&samples) |*values| std.mem.sort(f64, values, {}, std.sort.asc(f64));
        const before = (samples[0][2] + samples[0][3]) / 2;
        const after = (samples[1][2] + samples[1][3]) / 2;
        std.debug.print("Overlay skips {s} 96x96 incremental={}: baseline={d:.3} ms candidate={d:.3} ms ratio={d:.2}x; identical pixels (software EGL CPU+finish, median of 6 alternating 8-draw batches)\n", .{ if (mode == 14) "primary" else "shadow", world.incremental_uploads, before, after, before / after });
    }
    if (c.glGetError() != c.GL_NO_ERROR) return error.OverlaySkipGlError;
}

fn referenceTerrainHit(batch: *const @import("world/generation/terrainStreaming.zig").Batch, eye: [3]f32, direction: [3]f32, reach: f32) ?[3]i32 {
    var cell: [3]i32 = undefined;
    var next: [3]f32 = undefined;
    var delta: [3]f32 = undefined;
    var step: [3]i32 = undefined;
    var norm: f32 = 0;
    for (direction) |d| norm += d * d;
    norm = @sqrt(norm);
    for (0..3) |axis| {
        const d = direction[axis] / norm;
        cell[axis] = @intFromFloat(@floor(eye[axis]));
        if (d < 0 and eye[axis] == @as(f32, @floatFromInt(cell[axis]))) cell[axis] -= 1;
        step[axis] = if (d > 0) 1 else if (d < 0) -1 else 0;
        next[axis] = if (d == 0) std.math.inf(f32) else (@as(f32, @floatFromInt(cell[axis] + @max(step[axis], 0))) - eye[axis]) / d;
        delta[axis] = if (d == 0) std.math.inf(f32) else @abs(1 / d);
    }
    var distance: f32 = 0;
    while (distance < reach) {
        if (batch.tile(cell[0], cell[2])) |tile| if (cell[1] < tile.at(cell[0], cell[2]).height) return cell;
        distance = @min(next[0], @min(next[1], next[2]));
        // Half-open ownership advances all axes tied at the same boundary.
        for (0..3) |axis| if (next[axis] == distance) {
            cell[axis] += step[axis];
            next[axis] += delta[axis];
        };
    }
    return null;
}

fn runMovingTerrain(a: std.mem.Allocator) !void {
    const rendering = @import("rendering.zig");
    var world = try World.init(a);
    defer world.deinit() catch {};
    try world.enableTerrain(.{});
    world.upload_budget_bytes = rendering.upload_bytes_per_frame;
    var focus = rendering.FocusState{};
    try world.startGenerator();
    for ([_][3]f32{ .{ 0, 128, 0 }, .{ 20, 128, 0 }, .{ -20, 128, 0 }, .{ 4097, 128, -1 } }, 0..) |position, step| {
        const snapshot = try focus.resolve(rendering.terrain_settings, position);
        world.updateTerrain(snapshot, position);
        var timer = try std.time.Timer.start();
        var frames: usize = 0;
        var complete = false;
        var uploaded: usize = 0;
        var worst_commit: u64 = 0;
        var worst_frame: u64 = 0;
        while (timer.read() < 30 * std.time.ns_per_s) {
            var commit_timer = try std.time.Timer.start();
            try world.render(position);
            worst_frame = @max(worst_frame, commit_timer.read());
            worst_commit = @max(worst_commit, world.last_commit_ns);
            frames += 1;
            uploaded += world.last_upload_bytes;
            if (world.last_upload_bytes > world.upload_budget_bytes) return error.TerrainUploadBudgetExceeded;
            if (world.terrain_stream.?.resident) |batch| {
                if (!batch.coarse and !world.upload_active and !world.terrain_build_active and batch.request.token == world.terrain_stream.?.submitted) {
                    complete = true;
                    std.debug.print("Terrain path {d}: latency={d:.2} ms worker={d:.2} ms frames={d} reused={d}/{d} cache={d} payload={d} uploaded={d} worst_commit={d:.2} ms worst_update={d:.2} ms\n", .{
                        step,                                                         @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms,
                        @as(f64, @floatFromInt(batch.build_ns)) / std.time.ns_per_ms, frames,
                        batch.reused_tiles,                                           batch.tiles.len,
                        batch.cache_bytes,                                            batch.bytes,
                        uploaded,                                                     @as(f64, @floatFromInt(worst_commit)) / std.time.ns_per_ms,
                        @as(f64, @floatFromInt(worst_frame)) / std.time.ns_per_ms,
                    });
                    break;
                }
            }
            std.Thread.sleep(std.time.ns_per_ms);
        }
        if (!complete) return error.TerrainWorkerTimeout;
        const x: i32 = @intFromFloat(@floor(position[0]));
        const z: i32 = @intFromFloat(@floor(position[2]));
        if (world.terrainSpawnHeight(x, z) == null) return error.TerrainSpawnNotReady;
        const revision = world.gpu_revision;
        const samples = world.terrain_stream.?.resident.?.stats.requested;
        for (0..3) |_| {
            world.updateTerrain(snapshot, position);
            try world.render(position);
            if (world.gpu_revision != revision or world.last_upload_bytes != 0) return error.StationaryTerrainUploaded;
        }
        if (world.terrain_stream.?.resident.?.stats.requested != samples) return error.StationaryTerrainGenerated;
    }
}

fn benchmarkTerrain(a: std.mem.Allocator, program: c_uint) !void {
    const rendering = @import("rendering.zig");
    const terrain = @import("world/terrainHierarchy.zig");
    const generator = @import("world/generation/terrainGenerator.zig");
    const streaming = @import("world/generation/terrainStreaming.zig");
    const edge = 96;
    const pixels = try a.alloc(u8, edge * edge * 4);
    defer a.free(pixels);
    for ([_]bool{ false, true }) |finest| {
        var world = try World.init(a);
        defer world.deinit() catch {};
        try world.enableTerrain(.{});
        var sampler = try generator.Sampler.init(a, .{});
        defer sampler.deinit();
        var focus = rendering.FocusState{};
        const rings = [_]Ring{
            .{ .outer_radius_voxels = 64, .cell_size_voxels = 1 },
            .{ .outer_radius_voxels = 128, .cell_size_voxels = 4 },
            .{ .outer_radius_voxels = 256, .cell_size_voxels = 16 },
            .{ .outer_radius_voxels = 512, .cell_size_voxels = 64 },
            .{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 },
        };
        const exact = [_]Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = 1 }};
        const snapshot = try focus.resolve(.{ .geometry_rings = if (finest) &exact else &rings, .interaction_radius_voxels = 0, .transition_width_voxels = 0, .hysteresis_voxels = 0 }, .{ -128, 0, -128 });
        world.updateTerrain(snapshot, .{ 0, 32, 0 });
        const batch = try a.create(streaming.Batch);
        batch.* = .{ .request = world.terrain_stream.?.request.?, .config_revision = 1, .coarse = false };
        world.terrain_stream.?.resident = batch;
        var timer = try std.time.Timer.start();
        var builder = try terrain.Builder.init(a, 0, 0, snapshot, 1, 2 * 1024 * 1024);
        defer builder.deinit();
        while (!try builder.advance(&sampler, 2048, 2 * std.time.ns_per_ms)) {}
        const index: usize = @intCast(-batch.request.origin[0] - batch.request.origin[1] * streaming.window_side);
        batch.tiles[index] = try builder.finish(1);
        batch.ready[index] = true;
        const generation_ns = timer.read();
        const center: f32 = @floatFromInt(try sampler.height(128, 128, 1));
        var uniforms = Policy.init(program);
        try uniforms.uploadSnapshot(&snapshot);
        try bind(&world, program);
        gl.uniform1i(gl.getUniformLocation(program, "uProbeMode"), 5);
        try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), edge, edge);
        c.glViewport(0, 0, edge, edge);
        var elapsed: u64 = 0;
        for ([_][3]f32{ .{ -64, center + 256, -64 }, .{ 128, center + 256, 384 } }) |eye| {
            try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
            try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), 128 - eye[0], center - eye[1], 128 - eye[2]);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            c.glFinish();
            timer.reset();
            for (0..3) |_| {
                c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
                c.glFinish();
            }
            elapsed += timer.read();
            c.glReadPixels(0, 0, edge, edge, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
        }
        std.debug.print("Terrain bounded 256x256 {s}: generation={d:.2} ms outputs={d} payload={d} bytes warm_gpu={d:.3} ms/view (96x96, two identical views, software EGL)\n", .{
            if (finest) "finest" else "mixed",                           @as(f64, @floatFromInt(generation_ns)) / std.time.ns_per_ms,
            sampler.stats.requested,                                     world.snapshotBytes(),
            @as(f64, @floatFromInt(elapsed)) / (6 * std.time.ns_per_ms),
        });
    }
}
