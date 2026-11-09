//! Sampled direct lighting algorithm counters, asynchronously read after fences.
//! Shader disabled normally; 64 shards and 64-bit carry pairs bound contention
//! and avoid 32-bit overflow. Counts are raw sampled work, never hardware metrics.
const std = @import("std");
const gl = @import("gl.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});
pub const names = [_][]const u8{
    "sampled_fragments",    "cache_lookups",   "cache_hits",    "cache_misses",     "ownership_success",
    "same_frame_pending",   "ownership_lost",  "collisions",    "probe_exhaustion", "population_rejected",
    "lighting_evaluations", "primary_rays",    "optical_rays",  "point_rays",       "sky_rays",
    "primary_steps",        "optical_steps",   "point_steps",   "sky_steps",        "primary_nodes",
    "optical_nodes",        "point_nodes",     "sky_nodes",     "reserved",         "primary_exhausted",
    "optical_exhausted",    "point_exhausted", "sky_exhausted",
};
const shards = 64;
const words = shards * names.len * 2;
const slots = 8;
const zeroes = [_]u32{0} ** words;
const Writer = std.io.BufferedWriter(16384, std.fs.File.Writer);
pub const Snapshot = struct {
    frame: u64 = 0,
    geometry: u64 = 0,
    lights: u64 = 0,
    cache_frame: u32 = 0,
    valid_from: u32 = 0,
};
pub const Diagnostics = struct {
    buffers: [slots]c_uint = .{0} ** slots,
    textures: [slots]c_uint = .{0} ** slots,
    fences: [slots]c.GLsync = .{null} ** slots,
    snapshots: [slots]Snapshot = .{Snapshot{}} ** slots,
    active: ?usize = null,
    stride: u32 = 0,
    location: c_int = -1,
    skipped: u64 = 0,
    collected: u64 = 0,
    last_counts: [names.len]u64 = .{0} ** names.len,
    file: ?std.fs.File = null,
    writer: ?Writer = null,

    pub fn init(program: c_uint, stride: u32, path: ?[]const u8) !Diagnostics {
        var self = Diagnostics{};
        if (stride == 0) return self;
        if (!std.math.isPowerOfTwo(stride) or stride > 65536) return error.InvalidDiagnosticStride;
        self.location = gl.getUniformLocation(program, "uDiagnosticStride");
        if (self.location < 0) return error.DiagnosticShaderRequired;
        self.stride = stride;
        errdefer self.deinit();
        try gl.genBuffers(slots, &self.buffers[0]);
        gl.genTextures(slots, &self.textures[0]);
        for (0..slots) |slot| {
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[slot]);
            try gl.bufferData(c.GL_TEXTURE_BUFFER, @sizeOf(@TypeOf(zeroes)), &zeroes, c.GL_DYNAMIC_READ);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.textures[slot]);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.buffers[slot]);
        }
        // Keep an image bound for inactive icon/reference draws too.
        self.bind(0);
        if (path) |p| {
            self.file = try std.fs.cwd().createFile(p, .{});
            self.writer = .{ .unbuffered_writer = self.file.?.writer() };
            try self.writer.?.writer().writeAll("frame,geometry_revision,light_revision,cache_frame,cache_valid_from,stride,counter,count\n");
        }
        return self;
    }
    fn bind(self: *const Diagnostics, slot: usize) void {
        c.__glewBindImageTexture.?(3, self.textures[slot], 0, c.GL_FALSE, 0, c.GL_READ_WRITE, c.GL_R32UI);
    }
    pub fn begin(self: *Diagnostics, snapshot: Snapshot) !void {
        if (self.stride == 0) return;
        try self.collect();
        for (0..slots) |slot| {
            if (self.fences[slot] != null) continue;
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[slot]);
            // This slot's previous fence has completed; no in-flight overwrite.
            c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @sizeOf(@TypeOf(zeroes)), &zeroes);
            self.bind(slot);
            self.snapshots[slot] = snapshot;
            self.active = slot;
            c.__glewUniform1ui.?(self.location, self.stride);
            return;
        }
        self.skipped += 1;
        c.__glewUniform1ui.?(self.location, 0);
    }
    pub fn end(self: *Diagnostics) !void {
        const slot = self.active orelse return;
        c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
        self.fences[slot] = c.__glewFenceSync.?(c.GL_SYNC_GPU_COMMANDS_COMPLETE, 0) orelse return error.DiagnosticFenceFailed;
        self.active = null;
        c.__glewUniform1ui.?(self.location, 0);
    }
    /// Poll once, without flush, finish or waiting. Fence precedes every readback.
    pub fn collect(self: *Diagnostics) !void {
        if (self.stride == 0) return;
        for (0..slots) |slot| {
            const fence = self.fences[slot] orelse continue;
            const status = c.__glewClientWaitSync.?(fence, 0, 0);
            if (status == c.GL_WAIT_FAILED) return error.DiagnosticWaitFailed;
            if (status != c.GL_ALREADY_SIGNALED and status != c.GL_CONDITION_SATISFIED) continue;
            var values: [words]u32 = undefined;
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[slot]);
            c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @sizeOf(@TypeOf(values)), &values);
            self.last_counts = aggregate(&values);
            if (self.writer) |*writer| {
                const s = self.snapshots[slot];
                for (names, self.last_counts) |name, count| try writer.writer().print("{d},{d},{d},{d},{d},{d},{s},{d}\n", .{ s.frame, s.geometry, s.lights, s.cache_frame, s.valid_from, self.stride, name, count });
            }
            c.__glewDeleteSync.?(fence);
            self.fences[slot] = null;
            self.collected += 1;
        }
    }
    pub fn pendingCount(self: *const Diagnostics) usize {
        var count: usize = 0;
        for (self.fences) |f| count += @intFromBool(f != null);
        return count;
    }
    pub fn deinit(self: *Diagnostics) void {
        if (self.stride == 0) return;
        self.collect() catch |err| std.debug.print("Diagnostic collection failed: {s}\n", .{@errorName(err)});
        std.debug.print("Direct diagnostics: {d} collected, {d} skipped, {d} pending.\n", .{ self.collected, self.skipped, self.pendingCount() });
        for (self.fences) |f| if (f != null) {
            c.__glewDeleteSync.?(f);
        };
        gl.deleteTextures(slots, &self.textures[0]);
        gl.deleteBuffers(slots, &self.buffers[0]) catch {};
        if (self.writer) |*writer| writer.flush() catch |err| std.debug.print("Diagnostic CSV flush failed: {s}\n", .{@errorName(err)});
        if (self.file) |file| file.close();
        self.* = .{};
    }
};
pub fn aggregate(values: *const [words]u32) [names.len]u64 {
    var counts = [_]u64{0} ** names.len;
    for (0..shards) |shard| for (&counts, 0..) |*count, index| {
        const offset = (shard * names.len + index) * 2;
        count.* += @as(u64, values[offset]) | (@as(u64, values[offset + 1]) << 32);
    };
    return counts;
}
