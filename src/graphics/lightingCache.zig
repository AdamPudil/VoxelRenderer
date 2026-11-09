//! Persistent GPU voxel-face illumination cache. Full coordinate keys prevent
//! collision aliasing. Current-frame writes are never read until the next draw.
const std = @import("std");
const gl = @import("gl.zig");
const settings = @import("../lighting.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});

pub const Clock = struct {
    frame: u32 = 0,
    valid_from: u32 = 1,
    geometry: u64 = 0,
    lights: u64 = 0,

    /// Returns true only when the stamp buffer needs clearing after wraparound.
    pub fn advance(self: *Clock, geometry: u64, lights: u64) bool {
        const wrap = self.frame == std.math.maxInt(u32);
        const first = self.frame == 0 or wrap;
        self.frame = if (first) 1 else self.frame + 1;
        if (first or geometry != self.geometry or lights != self.lights) self.valid_from = self.frame;
        self.geometry = geometry;
        self.lights = lights;
        return wrap;
    }
};

pub const Cache = struct {
    buffers: [3]c_uint = .{ 0, 0, 0 },
    textures: [3]c_uint = .{ 0, 0, 0 },
    frame_loc: c_int = -1,
    valid_from_loc: c_int = -1,
    budget_loc: c_int = -1,
    population_budget: u32 = settings.face_cache_entries,
    clock: Clock = .{},

    pub fn init(program: c_uint) !Cache {
        var self = Cache{ .frame_loc = gl.getUniformLocation(program, "uLightingCacheFrame"), .valid_from_loc = gl.getUniformLocation(program, "uLightingCacheValidFrom") };
        self.budget_loc = gl.getUniformLocation(program, "uLightingCacheBudget");
        if (self.frame_loc < 0) return self;
        comptime std.debug.assert(std.math.isPowerOfTwo(settings.face_cache_entries));
        var limit: c_int = 0;
        c.glGetIntegerv(c.GL_MAX_TEXTURE_BUFFER_SIZE, &limit);
        if (limit < settings.face_cache_entries) {
            std.debug.print("Lighting face cache disabled: {d} entries exceed GPU texture-buffer limit {d}\n", .{ settings.face_cache_entries, limit });
            return .{}; // default frame=0 keeps the original lighting path
        }
        errdefer self.deinit();
        try gl.genBuffers(3, &self.buffers[0]);
        gl.genTextures(3, &self.textures[0]);
        const formats = [_]c_uint{ c.GL_R32UI, c.GL_RGBA32I, c.GL_RGBA32F };
        for (0..3) |i| {
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[i]);
            if (i == 0) {
                try self.clearStamps();
            } else {
                try gl.bufferData(c.GL_TEXTURE_BUFFER, settings.face_cache_entries * 16, null, c.GL_DYNAMIC_DRAW);
            }
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.textures[i]);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, formats[i], self.buffers[i]);
        }
        // Reference draws can run before begin(). Keep the shader image
        // resources valid even while its frame uniform disables cache access.
        self.bindImages();
        return self;
    }

    fn bindImages(self: *const Cache) void {
        const formats = [_]c_uint{ c.GL_R32UI, c.GL_RGBA32I, c.GL_RGBA32F };
        for (self.textures, 0..) |texture, i| c.__glewBindImageTexture.?(@intCast(i), texture, 0, c.GL_FALSE, 0, c.GL_READ_WRITE, formats[i]);
    }

    fn clearStamps(self: *Cache) !void {
        const zeros = try std.heap.page_allocator.alloc(u32, settings.face_cache_entries);
        defer std.heap.page_allocator.free(zeros);
        @memset(zeros, 0);
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[0]);
        try gl.bufferData(c.GL_TEXTURE_BUFFER, @intCast(zeros.len * 4), zeros.ptr, c.GL_DYNAMIC_DRAW);
    }

    pub fn deinit(self: *Cache) void {
        gl.deleteTextures(3, &self.textures[0]);
        gl.deleteBuffers(3, &self.buffers[0]) catch {};
        self.* = .{};
    }

    /// Call with the owning program bound, after world and light uploads. Geometry
    /// and light revisions invalidate in O(1); no buffer clears/uploads per frame.
    pub fn begin(self: *Cache, geometry_revision: u64, light_revision: u64) !void {
        if (self.frame_loc < 0) return;
        if (self.clock.advance(geometry_revision, light_revision)) {
            c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
            try self.clearStamps();
        }
        self.bindImages();
        c.__glewUniform1ui.?(self.budget_loc, @min(self.population_budget, settings.face_cache_entries));
        c.__glewUniform1ui.?(self.frame_loc, self.clock.frame);
        c.__glewUniform1ui.?(self.valid_from_loc, self.clock.valid_from);
    }

    /// Publication barrier only. Direct illumination is evaluated during the world draw.
    pub fn end(self: *const Cache) void {
        if (self.frame_loc < 0) return;
        c.__glewMemoryBarrier.?(c.GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
    }
};

test "cache survives camera frames and invalidates on geometry, lights and wrap" {
    var clock = Clock{};
    try std.testing.expect(!clock.advance(7, 3));
    try std.testing.expectEqual(@as(u32, 1), clock.valid_from);
    try std.testing.expect(!clock.advance(7, 3));
    try std.testing.expectEqual(@as(u32, 1), clock.valid_from);
    try std.testing.expect(!clock.advance(8, 3));
    try std.testing.expectEqual(@as(u32, 3), clock.valid_from);
    try std.testing.expect(!clock.advance(8, 4));
    try std.testing.expectEqual(@as(u32, 4), clock.valid_from);
    clock.frame = std.math.maxInt(u32);
    try std.testing.expect(clock.advance(8, 4));
    try std.testing.expectEqual(@as(u32, 1), clock.frame);
    try std.testing.expectEqual(@as(u32, 1), clock.valid_from);
}
