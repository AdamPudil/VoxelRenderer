//! Offscreen GI contract tests; called inside the render suite's EGL context.
const std = @import("std");
const gl = @import("graphics/gl.zig");
const config = @import("lighting.zig");
const utils = @import("graphics/gl_utils.zig");
const Gi = @import("graphics/globalIllumination.zig").Cache;
const World = @import("world/world.zig").World;
const Block = @import("world/block.zig").Block;
const Voxel = @import("world/voxel.zig").Voxel;
const c = @cImport({
    @cInclude("GL/glew.h");
});

fn read(cache: *Gi, buffer: usize, comptime T: type, offset: usize) !T {
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[buffer]);
    var result: T = undefined;
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, @intCast(offset), @sizeOf(T), &result);
    return result;
}
fn find(cache: *Gi, key: [4]i32) !usize {
    var h: u32 = @as(u32, @bitCast(key[0])) *% 0x8da6b343 ^ @as(u32, @bitCast(key[1])) *% 0xd8163841 ^
        @as(u32, @bitCast(key[2])) *% 0xcb1ab31f ^ @as(u32, @bitCast(key[3])) *% 0x9e3779b9;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    for (0..16) |i| {
        const slot = (h +% @as(u32, @intCast(i))) & (config.face_cache_entries - 1);
        const stamp = try read(cache, 0, u32, slot * 4);
        if (stamp < cache.clock.valid_from) continue;
        const actual = try read(cache, 1, [4]i32, slot * 16);
        if (std.mem.eql(i32, &key, &actual)) return slot;
    }
    return error.GiFaceNotCached;
}
fn frame(cache: *Gi, world: *World, eye: [3]f32, probe: [3]i32, width: c_int) ![8]u32 {
    try world.render(eye);
    world.bindGpuTextures();
    try cache.begin(world);
    gl.uniform1i(gl.getUniformLocation(cache.program, "uIconMode"), 0);
    gl.uniform3i(gl.getUniformLocation(cache.program, "uProbeOrigin"), probe[0], probe[1], probe[2]);
    c.glViewport(0, 0, width, 1);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    cache.update();
    const counters = try cache.counters();
    if (counters[4] > config.gi_ray_budget) return error.GiRayBudgetExceeded;
    if (counters[1] -% counters[0] > config.gi_queue_capacity) return error.GiQueueOverflow;
    if (c.glGetError() != c.GL_NO_ERROR) return error.GiOpenGlError;
    return counters;
}

pub fn run(a: std.mem.Allocator) !void {
    // Independent toggles must compile for both renderer profiles and the worker.
    for (0..16) |mask| {
        const features = config.Features{ .mode = .global_illumination, .sky_lighting = mask & 1 != 0, .point_lights = mask & 2 != 0, .normal_probes = mask & 4 != 0, .indirect = mask & 8 != 0 };
        for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel", "src/graphics/shaders/gi/update" }) |path| {
            const program = try utils.createLightingProgram(path, features, 8);
            defer gl.deleteProgram(program);
            if (mask & 2 == 0 and gl.getUniformLocation(program, "uLightCount") != -1) return error.GiDisabledPointStagePresent;
        }
    }
    const features = config.Features{ .mode = .global_illumination, .face_shading = false, .sky_lighting = false, .diagnostics = true };
    const program = try utils.createLightingProgram("src/graphics/shaders/tests/lighting_probe", features, 8);
    defer gl.deleteProgram(program);
    var cache = try Gi.init(program, features, 8);
    defer cache.deinit();
    var world = try World.init(a);
    defer world.deinit() catch {};
    var white = Block.initMono(0, Voxel.rgb(255, 255, 255));
    var red = Block.initMono(0, Voxel.rgb(255, 20, 20));
    var empty = Block.initEmpty(0);
    try world.setBlock(.{ 0, 6, 0 }, &white);
    try world.setBlock(.{ 0, 8, 0 }, &red);
    try world.scene_lights.append(.{ .position = .{ 8, 120, 8 }, .color = .{ 1, 1, 1 }, .intensity = 0.2 });
    const eye = [3]f32{ 8, 120, 8 };
    const probe = [3]i32{ 7, 112, 7 };
    var last_samples: f32 = 0;
    var progressive_frames: u32 = 0;
    var converged = false;
    var slot: usize = 0;
    var generation: u32 = 0;
    var timer = try std.time.Timer.start();
    for (0..160) |i| {
        _ = try frame(&cache, &world, .{ eye[0] + @as(f32, @floatFromInt(i % 3)) * 0.1, eye[1], eye[2] }, probe, 1);
        if (i == 0) generation = cache.clock.valid_from;
        if (generation != cache.clock.valid_from) return error.GiCameraInvalidated;
        slot = try find(&cache, .{ 7, 111, 7, 3 });
        const sum = try read(&cache, 3, [4]f32, slot * 16);
        if (sum[3] < last_samples) return error.GiAccumulationReset;
        if (sum[3] > last_samples) progressive_frames += 1;
        last_samples = sum[3];
        const state = try read(&cache, 5, [4]u32, slot * 16);
        if (state[2] == 3) {
            converged = true;
            break;
        }
    }
    if (!converged or last_samples != config.gi_samples or progressive_frames < 3) return error.GiDidNotRefine;
    const direct = try read(&cache, 2, [4]f32, slot * 16);
    const result = try read(&cache, 4, [4]f32, slot * 16);
    if (result[0] < direct[0] + 0.005 or result[0] < result[1] + 0.005) return error.GiColorBounceMissing;
    const final_sum = try read(&cache, 3, [4]f32, slot * 16);
    const warm = try frame(&cache, &world, eye, probe, 1);
    if (warm[4] != 0 or warm[5] == 0) return error.GiConvergedFaceRetraced;
    if (!std.mem.eql(f32, &final_sum, &try read(&cache, 3, [4]f32, slot * 16))) return error.GiConvergedSumChanged;
    std.debug.print("GI one-bounce: direct={any}, final={any}, {d} refinement frames, {d:.2} ms including diagnostic readbacks; warm rays={d}\n", .{ direct, result, progressive_frames, @as(f64, @floatFromInt(timer.read())) / 1e6, warm[4] });

    // Light and nonlocal geometry edits invalidate before any old value is read.
    world.scene_lights.items[0].color = .{ 0, 0, 1 };
    _ = try frame(&cache, &world, eye, probe, 1);
    if (cache.clock.valid_from == generation) return error.GiLightChangeStale;
    generation = cache.clock.valid_from;
    try world.setBlock(.{ 0, 7, 0 }, &white);
    _ = try frame(&cache, &world, eye, probe, 1);
    if (cache.clock.valid_from == generation) return error.GiGeometryChangeStale;
    slot = try find(&cache, .{ 7, 111, 7, 3 });
    const blocked = try read(&cache, 2, [4]f32, slot * 16);
    if (blocked[2] > 0.001) return error.GiOccluderIgnored;
    try world.setBlock(.{ 0, 7, 0 }, &empty);
    _ = try frame(&cache, &world, eye, probe, 1);
    slot = try find(&cache, .{ 7, 111, 7, 3 });
    const reopened = try read(&cache, 2, [4]f32, slot * 16);
    if (reopened[2] < 0.01 or reopened[0] > 0.001) return error.GiRemovalOrLightColorStale;
    // Force wraparound and a streaming change; neither may resurrect old slots.
    cache.clock.frame = std.math.maxInt(u32);
    _ = try frame(&cache, &world, eye, probe, 1);
    if (cache.clock.frame != 1 or cache.clock.valid_from != 1) return error.GiWrapFailed;
    generation = cache.clock.valid_from;
    _ = try frame(&cache, &world, .{ 8192, 120, 8192 }, probe, 1);
    _ = try frame(&cache, &world, eye, probe, 1);
    if (cache.clock.valid_from == generation) return error.GiStreamingStale;
    // Many new visible faces: queue/ray work remains bounded and progresses.
    _ = try frame(&cache, &world, eye, .{ -128, 112, 7 }, 512);
    const busy = try frame(&cache, &world, eye, .{ -128, 112, 7 }, 512);
    std.debug.print("GI busy frame: rays<={d}, hits={d}, misses={d}, deferred={d}, queued={d}\n", .{ busy[4], busy[5], busy[6], busy[7], busy[1] -% busy[0] });
    var deferred: u32 = 0;
    var peak_queue: u32 = 0;
    for (0..24) |row| {
        const pressure = try frame(&cache, &world, eye, .{ -128, 112, @as(i32, @intCast(row)) + 32 }, 512);
        deferred += pressure[7];
        peak_queue = @max(peak_queue, pressure[1] -% pressure[0]);
    }
    if (deferred == 0) return error.GiQueuePressureNotExercised;
    std.debug.print("GI queue pressure: peak={d}/{d}, deferred attempts={d}, ray budget held\n", .{ peak_queue, config.gi_queue_capacity, deferred });
    try checkSkyAndCamera(a);
    std.debug.print("GI cache, progressive sampling, color bleed, edits, streaming and budgets passed\n", .{});
}

fn checkSkyAndCamera(a: std.mem.Allocator) !void {
    const features = config.Features{ .mode = .global_illumination, .point_lights = false, .diagnostics = true };
    const program = try utils.createLightingProgram("src/graphics/shaders/tests/lighting_probe", features, 8);
    defer gl.deleteProgram(program);
    var cache = try Gi.init(program, features, 8);
    defer cache.deinit();
    var world = try World.init(a);
    defer world.deinit() catch {};
    var white = Block.initMono(0, Voxel.rgb(255, 255, 255));
    var empty = Block.initEmpty(0);
    try world.setBlock(.{ -1, 6, -1 }, &white);
    const eye = [3]f32{ -8, 120, -8 };
    const probe = [3]i32{ -8, 112, -8 };
    var slot: usize = 0;
    for (0..32) |_| {
        _ = try frame(&cache, &world, eye, probe, 1);
        slot = try find(&cache, .{ -8, 111, -8, 3 });
        if ((try read(&cache, 5, [4]u32, slot * 16))[2] == 3) break;
    }
    if ((try read(&cache, 5, [4]u32, slot * 16))[2] != 3) return error.GiOpenSkyNotConverged;
    const value = try read(&cache, 4, [4]f32, slot * 16);
    for (0..3) |axis| if (@abs(value[axis] - config.sky_color[axis] * config.sky_intensity) > 0.0001) return error.GiSkyCountedTwice;
    // Eviction runs between draws and may reclaim only unqueued old entries.
    const valid_before_eviction = cache.clock.valid_from;
    cache.clock.frame += config.gi_retention_frames + 1;
    cache.maintenance = @intCast(slot);
    world.bindGpuTextures();
    try cache.begin(&world);
    if ((try read(&cache, 0, u32, slot * 4)) != 0) return error.GiOldFaceNotEvicted;
    if (cache.clock.valid_from != valid_before_eviction) return error.GiEvictionInvalidatedWorld;
    _ = try frame(&cache, &world, eye, probe, 1);
    slot = try find(&cache, .{ -8, 111, -8, 3 });
    if ((try read(&cache, 2, [4]f32, slot * 16))[2] < 0.6) return error.GiEvictedFaceNotRebuilt;
    try world.setBlock(.{ -1, 8, -1 }, &white);
    _ = try frame(&cache, &world, eye, probe, 1);
    slot = try find(&cache, .{ -8, 111, -8, 3 });
    if ((try read(&cache, 2, [4]f32, slot * 16))[2] > 0.001) return error.GiSkyRoofStale;
    try world.setBlock(.{ -1, 8, -1 }, &empty);
    _ = try frame(&cache, &world, eye, probe, 1);
    slot = try find(&cache, .{ -8, 111, -8, 3 });
    if ((try read(&cache, 2, [4]f32, slot * 16))[2] < 0.6) return error.GiSkyRemovalStale;

    // Exercise the real camera hit -> cached shade path on both shader profiles.
    const wc = @import("world/worldConstants.zig");
    for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel" }) |path| {
        const camera = try utils.createLightingProgram(path, features, 8);
        defer gl.deleteProgram(camera);
        var camera_cache = try Gi.init(camera, features, 8);
        defer camera_cache.deinit();
        var pixel: [4]u8 = undefined;
        var cold: [4]u8 = undefined;
        var max_rays: u32 = 0;
        var timer = try std.time.Timer.start();
        for (0..40) |i| {
            world.bindGpuTextures();
            try camera_cache.begin(&world);
            const names = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
            for (names, 0..) |name, unit| gl.uniform1i(gl.getUniformLocation(camera, name), @intCast(unit));
            const origin = world.gpu_region_origin_chunk;
            gl.uniform3i(gl.getUniformLocation(camera, "uRegionOriginChunk"), origin[0], origin[1], origin[2]);
            gl.uniform3i(gl.getUniformLocation(camera, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
            try gl.uniform2f(gl.getUniformLocation(camera, "uResolution"), 32, 32);
            try gl.uniform3f(gl.getUniformLocation(camera, "uCamPos"), eye[0], eye[1], eye[2]);
            try gl.uniform3f(gl.getUniformLocation(camera, "uCamDir"), 0, -1, 0);
            c.glViewport(0, 0, 32, 32);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            c.glReadPixels(10, 12, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixel);
            if (i == 0) cold = pixel;
            camera_cache.update();
            const counts = try camera_cache.counters();
            max_rays = @max(max_rays, counts[4]);
            if (counts[4] > config.gi_ray_budget) return error.GiCameraRayBudgetExceeded;
        }
        if (cold[2] != 0 or pixel[2] < 180) return error.GiCameraCacheNotDisplayed;
        std.debug.print("GI camera {s}: pending={any}, refined={any}, max rays/frame={d}, 40 frames {d:.2} ms (software EGL, includes readbacks)\n", .{ path, cold, pixel, max_rays, @as(f64, @floatFromInt(timer.read())) / 1e6 });
    }
}
