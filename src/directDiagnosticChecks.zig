//! Integration checks run by test-profile-gpu. Only tests synchronize with GL.
const std = @import("std");
const gl = @import("graphics/gl.zig");
const utils = @import("graphics/gl_utils.zig");
const diagnostic = @import("graphics/directDiagnostics.zig");
const World = @import("world/world.zig").World;
const c = @cImport({
    @cInclude("GL/glew.h");
});
const side = 32;
const Image = [side * side * 4]u8;
fn configure(world: *World, program: c_uint) !void {
    gl.useProgram(program);
    world.bindGpuTextures();
    const samplers = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
    for (samplers, 0..) |name, unit| gl.uniform1i(gl.getUniformLocation(program, name), @intCast(unit));
    const p = world.gpu_region_origin_chunk;
    gl.uniform3i(gl.getUniformLocation(program, "uRegionOriginChunk"), p[0], p[1], p[2]);
    const wc = @import("world/worldConstants.zig");
    gl.uniform3i(gl.getUniformLocation(program, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
    try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), side, side);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), 8, 8, 40);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), 0, 0, -1);
    var lights = @import("graphics/pointLights.zig").Uniforms.init(program);
    lights.upload(&.{.{ .position = .{ 8, 24, 48 }, .radius = 256 }}, &.{}, .{ 8, 8, 40 });
    c.glViewport(0, 0, side, side);
}
fn pixels() Image {
    var image: Image = undefined;
    c.glReadPixels(0, 0, side, side, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &image);
    return image;
}
pub fn run() !void {
    const a = std.heap.page_allocator;
    var world = try World.init(a);
    defer world.deinit() catch {};
    const block = @import("world/block.zig").Block.initMono(0, @import("world/voxel.zig").Voxel.rgb(200, 180, 140));
    try world.setBlock(.{ 0, 0, 0 }, &block);
    try world.render(.{ 8, 8, 40 });
    for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel" }) |path| {
        const features = @import("lighting.zig").featuresForMode(.direct);
        const reference = try utils.createLightingProgram(path, features, 8);
        defer gl.deleteProgram(reference);
        if (gl.getUniformLocation(reference, "uDiagnosticStride") != -1 or gl.getUniformLocation(reference, "uDirectDiagnostics") != -1) return error.DiagnosticsNotCompiledOut;
        var reference_cache = try @import("graphics/lightingCache.zig").Cache.init(reference);
        defer reference_cache.deinit();
        try configure(&world, reference);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        const expected = pixels();
        const program = try utils.createDiagnosticProgram(path, features, 8, true);
        defer gl.deleteProgram(program);
        var counters = try diagnostic.Diagnostics.init(program, 1, null);
        defer counters.deinit();
        var cache = try @import("graphics/lightingCache.zig").Cache.init(program);
        defer cache.deinit();
        for (1..5) |frame| {
            try configure(&world, program);
            const revision: u64 = if (frame < 3) 1 else 2;
            cache.population_budget = if (frame == 4) 0 else @import("lighting.zig").face_cache_entries;
            // Frame 4 forces invalidation with a read-only population window.
            try cache.begin(revision, if (frame == 4) 2 else 1);
            try counters.begin(.{ .frame = frame, .geometry = revision, .lights = 1, .cache_frame = cache.clock.frame, .valid_from = cache.clock.valid_from });
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
            try counters.end();
            const actual = pixels();
            if (!std.mem.eql(u8, &expected, &actual)) return error.DiagnosticImageChanged;
            c.glFinish();
            try counters.collect();
            const counts = counters.last_counts;
            if (counts[0] != side * side or counts[11] != side * side) return error.DiagnosticPixelCount;
            if (counts[1] == 0 or counts[1] != counts[2] + counts[3] or counts[10] != counts[3]) return error.DiagnosticCacheAccounting;
            if (frame == 2) {
                if (counts[2] == 0 or counts[10] >= counts[1]) return error.DiagnosticWarmCache;
            } else {
                if (counts[10] == 0 or counts[13] == 0 or counts[14] == 0 or counts[17] == 0 or counts[18] == 0) return error.DiagnosticMissingLightingWork;
                if (frame == 4 and (counts[9] == 0 or counts[4] != 0)) return error.DiagnosticPopulationWindow;
            }
        }
        // Sampling must leave output identical and count a strict subset.
        counters.stride = 16;
        try counters.begin(.{ .frame = 5 });
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        try counters.end();
        const sampled = pixels();
        if (!std.mem.eql(u8, &expected, &sampled)) return error.SampledImageChanged;
        c.glFinish();
        try counters.collect();
        if (counters.last_counts[0] == 0 or counters.last_counts[0] >= side * side) return error.DiagnosticSampling;
        // Force GPU low-word overflow without tracing billions of rays.
        counters.stride = 1;
        try counters.begin(.{ .frame = 6 });
        var carry_values = [_]u32{0} ** (64 * diagnostic.names.len * 2);
        for (0..64) |shard| carry_values[shard * diagnostic.names.len * 2] = std.math.maxInt(u32);
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, counters.buffers[counters.active.?]);
        c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @sizeOf(@TypeOf(carry_values)), &carry_values);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        try counters.end();
        c.glFinish();
        try counters.collect();
        if (counters.last_counts[0] != @as(u64, std.math.maxInt(u32)) * 64 + side * side) return error.DiagnosticGpuCarry;
        // Exercise carry aggregation independently of impractically many rays.
        var values = [_]u32{0} ** (64 * diagnostic.names.len * 2);
        values[0] = 7;
        values[1] = 1;
        values[diagnostic.names.len * 2] = 9;
        if (diagnostic.aggregate(&values)[0] != (@as(u64, 1) << 32) + 16) return error.DiagnosticCarry;
        if (c.glGetError() != c.GL_NO_ERROR) return error.DiagnosticOpenGLError;
    }
    std.debug.print("Direct diagnostics: both shader profiles, exact image parity, cold/warm/invalidation, budget rejection, sampling and carry passed.\n", .{});
}
