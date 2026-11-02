//! Bounded asynchronous GPU face lighting. The primary draw only looks up and
//! queues faces; three small offscreen draws snapshot and execute queued jobs.
const std = @import("std");
const gl = @import("gl.zig");
const config = @import("../lighting.zig");
const World = @import("../world/world.zig").World;
const wc = @import("../world/worldConstants.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});
const Clock = @import("lightingCache.zig").Clock;
const LightUniforms = @import("pointLights.zig").Uniforms;
const formats = [_]c_uint{ c.GL_R32UI, c.GL_RGBA32I, c.GL_RGBA32F, c.GL_RGBA32F, c.GL_RGBA32F, c.GL_R32UI, c.GL_R32UI, c.GL_R32UI };
pub const bytes_per_entry = 88; // stamp + key + three RGB accumulators + state + dependency
pub const queue_words = 8 + config.gi_queue_capacity + config.gi_max_jobs;
pub const memory_bytes = config.face_cache_entries * bytes_per_entry + queue_words * 4;

pub const Cache = struct {
    buffers: [8]c_uint = .{0} ** 8,
    textures: [8]c_uint = .{0} ** 8,
    program: c_uint = 0,
    worker: c_uint = 0,
    framebuffer: c_uint = 0,
    color: c_uint = 0,
    clock: Clock = .{},
    lights: LightUniforms = .{},
    jobs: u32 = 0,
    maintenance: u32 = 0,

    pub fn init(program: c_uint, features: config.Features, extra_rays: u32) !Cache {
        if (gl.getUniformLocation(program, "uGiFrame") < 0) return .{};
        comptime {
            std.debug.assert(std.math.isPowerOfTwo(config.gi_queue_capacity));
            std.debug.assert(std.math.isPowerOfTwo(config.face_cache_entries));
            std.debug.assert(std.math.isPowerOfTwo(config.gi_samples) and config.gi_samples > 1);
            std.debug.assert(config.gi_max_batch > 0 and config.gi_max_jobs > 0);
            std.debug.assert(config.gi_max_jobs <= config.gi_queue_capacity);
        }
        var limit: c_int = 0;
        c.glGetIntegerv(c.GL_MAX_TEXTURE_BUFFER_SIZE, &limit);
        if (limit < config.face_cache_entries * 4) return error.GiTextureBufferTooSmall;
        c.glGetIntegerv(c.GL_MAX_FRAGMENT_IMAGE_UNIFORMS, &limit);
        if (limit < 8) return error.GiRequiresEightImageUnits;
        const direct_cost = (if (features.sky_lighting) 1 + extra_rays else @as(u32, 0)) +
            (if (features.point_lights) @as(u32, config.max_lights) else 0);
        const cost = @max(@max(direct_cost, config.gi_max_batch), 1);
        var self = Cache{ .program = program, .jobs = @min(config.gi_max_jobs, config.gi_ray_budget / cost) };
        if (self.jobs == 0) return error.GiRayBudgetTooSmall;
        errdefer self.deinit();
        self.worker = try @import("gl_utils.zig").createLightingProgram("src/graphics/shaders/gi/update", features, extra_rays);
        self.lights = LightUniforms.init(self.worker);
        try gl.genBuffers(8, &self.buffers[0]);
        gl.genTextures(8, &self.textures[0]);
        const lengths = [_]usize{ config.face_cache_entries * 4, config.face_cache_entries * 16, config.face_cache_entries * 16, config.face_cache_entries * 16, config.face_cache_entries * 16, config.face_cache_entries * 16, queue_words * 4, config.face_cache_entries * 4 };
        for (lengths, 0..) |length, i| {
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[i]);
            if (i == 0 or i == 5 or i == 6) {
                const zeros = try std.heap.page_allocator.alloc(u8, length);
                defer std.heap.page_allocator.free(zeros);
                @memset(zeros, 0);
                try gl.bufferData(c.GL_TEXTURE_BUFFER, @intCast(length), zeros.ptr, c.GL_DYNAMIC_DRAW);
            } else try gl.bufferData(c.GL_TEXTURE_BUFFER, @intCast(length), null, c.GL_DYNAMIC_DRAW);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.textures[i]);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, formats[i], self.buffers[i]);
        }
        var old_fbo: c_int = 0;
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &old_fbo);
        c.__glewGenFramebuffers.?(1, &self.framebuffer);
        c.__glewBindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, self.framebuffer);
        defer c.__glewBindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, @intCast(old_fbo));
        gl.genTextures(1, &self.color);
        gl.bindTexture(c.GL_TEXTURE_2D, self.color);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8, @max(config.gi_maintenance_slots, config.gi_max_jobs), 1, 0, c.GL_RED, c.GL_UNSIGNED_BYTE, null);
        c.__glewFramebufferTexture2D.?(c.GL_DRAW_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.color, 0);
        if (c.__glewCheckFramebufferStatus.?(c.GL_DRAW_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.GiFramebufferIncomplete;
        std.debug.print("GI: {d} MiB cache, {d} queued faces, <= {d} jobs / {d} rays per frame, {d} hemisphere samples, one bounce\n", .{ memory_bytes / (1024 * 1024), config.gi_queue_capacity, self.jobs, self.jobs * cost, config.gi_samples });
        return self;
    }

    pub fn deinit(self: *Cache) void {
        if (self.worker != 0) gl.deleteProgram(self.worker);
        gl.deleteTextures(8, &self.textures[0]);
        gl.deleteBuffers(8, &self.buffers[0]) catch {};
        if (self.framebuffer != 0) c.__glewDeleteFramebuffers.?(1, &self.framebuffer);
        if (self.color != 0) gl.deleteTextures(1, &self.color);
        self.* = .{};
    }

    fn bind(self: *Cache, program: c_uint) void {
        gl.useProgram(program);
        for (self.textures, formats, 0..) |texture, format, i|
            c.__glewBindImageTexture.?(@intCast(i), texture, 0, c.GL_FALSE, 0, c.GL_READ_WRITE, format);
        c.__glewUniform1ui.?(gl.getUniformLocation(program, "uGiFrame"), self.clock.frame);
        c.__glewUniform1ui.?(gl.getUniformLocation(program, "uGiValidFrom"), self.clock.valid_from);
    }

    /// World upload/edit hooks already advance gpu_revision. Selection is anchored
    /// to the streamed region, not the camera, so mere camera movement is stable.
    pub fn begin(self: *Cache, world: *World) !void {
        if (self.worker == 0) return;
        gl.useProgram(self.worker);
        const origin = world.gpu_region_origin_chunk;
        const center = [3]f32{
            @floatFromInt((origin[0] + wc.STREAM_CHUNKS_XZ / 2) * wc.CHUNK_VOXEL_CNT),
            @floatFromInt((origin[1] + wc.STREAM_CHUNKS_Y / 2) * wc.CHUNK_VOXEL_CNT),
            @floatFromInt((origin[2] + wc.STREAM_CHUNKS_XZ / 2) * wc.CHUNK_VOXEL_CNT),
        };
        self.lights.upload(world.scene_lights.items, world.block_lights.items, center);
        const old_valid = self.clock.valid_from;
        const wrap = self.clock.advance(world.gpu_revision, self.lights.revision);
        barrier();
        c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
        if (wrap) {
            const zeros = try std.heap.page_allocator.alloc(u32, config.face_cache_entries);
            defer std.heap.page_allocator.free(zeros);
            @memset(zeros, 0);
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[0]);
            c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(zeros.len * 4), zeros.ptr);
        }
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[6]);
        const zeros = [_]u32{0} ** 8;
        if (wrap or old_valid != self.clock.valid_from or self.clock.frame == 1)
            c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, 32, &zeros)
        else
            c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 16, 16, &zeros);
        self.bind(self.worker);
        const names = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
        for (names, 0..) |name, i| gl.uniform1i(gl.getUniformLocation(self.worker, name), @intCast(i));
        gl.uniform3i(gl.getUniformLocation(self.worker, "uRegionOriginChunk"), origin[0], origin[1], origin[2]);
        gl.uniform3i(gl.getUniformLocation(self.worker, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
        gl.uniform1i(gl.getUniformLocation(self.worker, "uGiJobs"), @intCast(self.jobs));
        c.__glewUniform1ui.?(gl.getUniformLocation(self.worker, "uGiMaintenanceStart"), self.maintenance);
        self.runPasses(true);
        self.maintenance = (self.maintenance + config.gi_maintenance_slots) & (config.face_cache_entries - 1);
        self.bind(self.program);
    }

    pub fn update(self: *Cache) void {
        if (self.worker == 0) return;
        barrier(); // publish primary misses before snapshotting work
        self.bind(self.worker);
        self.runPasses(false);
        self.bind(self.program);
    }

    fn runPasses(self: *Cache, maintenance_only: bool) void {
        var viewport: [4]c_int = undefined;
        var framebuffer: c_int = 0;
        c.glGetIntegerv(c.GL_VIEWPORT, &viewport);
        c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &framebuffer);
        const depth = c.glIsEnabled(c.GL_DEPTH_TEST);
        const blend = c.glIsEnabled(c.GL_BLEND);
        const scissor = c.glIsEnabled(c.GL_SCISSOR_TEST);
        c.glDisable(c.GL_DEPTH_TEST);
        c.glDisable(c.GL_BLEND);
        c.glDisable(c.GL_SCISSOR_TEST);
        c.__glewBindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, self.framebuffer);
        if (maintenance_only) {
            c.glViewport(0, 0, config.gi_maintenance_slots, 1);
            gl.uniform1i(gl.getUniformLocation(self.worker, "uGiPass"), 3);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            barrier();
        } else for (0..3) |pass| {
            c.glViewport(0, 0, if (pass == 0) 1 else @intCast(self.jobs), 1);
            gl.uniform1i(gl.getUniformLocation(self.worker, "uGiPass"), @intCast(pass));
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            barrier();
        }
        c.__glewBindFramebuffer.?(c.GL_DRAW_FRAMEBUFFER, @intCast(framebuffer));
        c.glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        if (depth != 0) c.glEnable(c.GL_DEPTH_TEST);
        if (blend != 0) c.glEnable(c.GL_BLEND);
        if (scissor != 0) c.glEnable(c.GL_SCISSOR_TEST);
    }

    /// Explicit diagnostic readback only (tests/profiling), never in the frame path.
    pub fn counters(self: *Cache) ![8]u32 {
        barrier();
        c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
        var result: [8]u32 = undefined;
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[6]);
        c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, 32, &result);
        return result;
    }
};
fn barrier() void {
    c.__glewMemoryBarrier.?(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
}
