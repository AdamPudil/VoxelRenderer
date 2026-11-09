//! Stable geometry allocations and copy-on-write publication on one GL context.
//! A fence inserted at publication/cancellation covers ALL earlier draws (including
//! GI) and uploads. The next transaction waits by polling, never by blocking.
const std = @import("std");
const gl = @import("gl.zig");
const buffer_layout = @import("worldBufferLayout.zig");
const terrain = @import("../world/terrainHierarchy.zig");
const Light = @import("../lighting.zig").PointLight;
const c = @cImport({
    @cInclude("GL/glew.h");
});

pub const Handle = struct { base: u32, bytes: u32, generation: u64 };
const Span = struct { base: u32, bytes: u32, generation: u64 = 0, used: bool = false };
pub const Arena = struct {
    spans: std.ArrayList(Span),
    serial: u64 = 0,
    capacity: u32,
    pub fn init(a: std.mem.Allocator, capacity: u32) !Arena {
        var spans = std.ArrayList(Span).init(a);
        errdefer spans.deinit();
        try spans.append(.{ .base = 0, .bytes = capacity });
        return .{ .spans = spans, .capacity = capacity };
    }
    pub fn deinit(self: *Arena) void {
        self.spans.deinit();
    }
    pub fn reserve(self: *Arena, bytes: usize) !Handle {
        if (bytes == 0 or bytes > self.capacity) return error.GeometryCapacityExceeded;
        const length: u32 = @intCast(std.mem.alignForward(usize, bytes, 16));
        for (self.spans.items, 0..) |span, i| {
            if (span.used or span.bytes < length) continue;
            if (span.bytes > length) try self.spans.insert(i + 1, .{ .base = span.base + length, .bytes = span.bytes - length });
            self.serial = std.math.add(u64, self.serial, 1) catch return error.AllocationGenerationExhausted;
            self.spans.items[i] = .{ .base = span.base, .bytes = length, .generation = self.serial, .used = true };
            return .{ .base = span.base, .bytes = length, .generation = self.serial };
        }
        return error.GeometryCapacityExceeded;
    }
    pub fn release(self: *Arena, handle: Handle) !void {
        for (self.spans.items, 0..) |span, index| {
            if (span.base != handle.base) continue;
            if (!span.used or span.generation != handle.generation or span.bytes != handle.bytes) return error.StaleGeometryHandle;
            var i = index;
            self.spans.items[i].used = false;
            if (i > 0 and !self.spans.items[i - 1].used) {
                self.spans.items[i - 1].bytes += span.bytes;
                _ = self.spans.orderedRemove(i);
                i -= 1;
            }
            if (i + 1 < self.spans.items.len and !self.spans.items[i + 1].used) {
                self.spans.items[i].bytes += self.spans.items[i + 1].bytes;
                _ = self.spans.orderedRemove(i + 1);
            }
            return;
        }
        return error.StaleGeometryHandle;
    }
};
pub const Kind = enum { tile, block, overlay };
pub const Key = struct { kind: Kind, coord: [3]i32, version: u64, config: u64 = 0 };
pub const Record = struct {
    key: Key,
    ranges: [5]?Handle = .{null} ** 5,
    data: [5][]u8 = .{&.{}} ** 5,
    tile: ?terrain.Tile = null,
    header: [4]u32 = .{0} ** 4,
    light: ?Light = null,
    dependencies: std.ArrayList(*Record),
    published: bool = false,
    wanted: bool = true,
    payload_bytes: usize = 0,
    fn source(self: *const Record, pool: usize) []const u8 {
        if (pool == 4) if (self.tile) |tile| return std.mem.sliceAsBytes(tile.nodes);
        return self.data[pool];
    }
    pub fn base(self: *const Record, pool: usize) u32 {
        return if (self.ranges[pool]) |h| h.base else 0;
    }
};
pub const Stats = struct {
    payload_bytes: usize = 0,
    metadata_bytes: usize = 0,
    reused_bytes: usize = 0,
    new_tiles: usize = 0,
    reused_tiles: usize = 0,
};
pub const Residency = struct {
    allocator: std.mem.Allocator,
    arenas: [5]Arena,
    buffers: [5]c_uint = .{0} ** 5,
    textures: [5]c_uint = .{0} ** 5,
    header_buffers: [2]c_uint = .{0} ** 2,
    header_textures: [2]c_uint = .{0} ** 2,
    header_bytes: usize,
    active_header: usize = 0,
    published: bool = false,
    transaction: bool = false,
    fence: c.GLsync = null,
    records: std.AutoHashMap(Key, *Record),
    pending: std.ArrayList(*Record),
    record_cursor: usize = 0,
    pool_cursor: usize = 0,
    byte_cursor: usize = 0,
    header_cursor: usize = 0,
    staging_bytes: usize = 0,
    stats: Stats = .{},
    last_stats: Stats = .{},
    fn initCpu(a: std.mem.Allocator, header_bytes: usize, capacities: [5]u32) !Residency {
        var self = Residency{ .allocator = a, .arenas = undefined, .header_bytes = header_bytes, .records = std.AutoHashMap(Key, *Record).init(a), .pending = std.ArrayList(*Record).init(a) };
        var initialized: usize = 0;
        errdefer for (self.arenas[0..initialized]) |*arena| arena.deinit();
        for (capacities, 0..) |capacity, i| {
            self.arenas[i] = try Arena.init(a, capacity);
            initialized += 1;
        }
        return self;
    }
    pub fn init(a: std.mem.Allocator, header_bytes: usize, capacities: [5]u32) !Residency {
        var self = try initCpu(a, header_bytes, capacities);
        errdefer self.deinit();
        var limit: c_int = 0;
        c.glGetIntegerv(c.GL_MAX_TEXTURE_BUFFER_SIZE, &limit);
        // Pools 0/1 hold block/voxel headers; all remaining pools are scalar.
        for (capacities, 0..) |capacity, i| try buffer_layout.validate(capacity, i < 2, @intCast(@max(limit, 0)));
        try buffer_layout.validate(header_bytes, true, @intCast(@max(limit, 0)));
        try gl.genBuffers(5, &self.buffers[0]);
        gl.genTextures(5, &self.textures[0]);
        try gl.genBuffers(2, &self.header_buffers[0]);
        gl.genTextures(2, &self.header_textures[0]);
        for (self.buffers, self.textures, capacities, 0..) |buffer, texture, capacity, i| try allocateBuffer(buffer, texture, capacity, i < 2);
        for (self.header_buffers, self.header_textures) |buffer, texture| try allocateBuffer(buffer, texture, header_bytes, true);
        return self;
    }
    fn allocateBuffer(buffer: c_uint, texture: c_uint, bytes: usize, header: bool) !void {
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, buffer);
        try gl.bufferData(c.GL_TEXTURE_BUFFER, @intCast(buffer_layout.allocationBytes(bytes, header)), null, c.GL_DYNAMIC_DRAW);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, texture);
        try gl.texBuffer(c.GL_TEXTURE_BUFFER, buffer_layout.format(header), buffer);
    }
    fn deleteGl(self: *Residency) void {
        if (self.fence != null) c.__glewDeleteSync.?(self.fence);
        if (self.textures[0] != 0) gl.deleteTextures(5, &self.textures[0]);
        if (self.header_textures[0] != 0) gl.deleteTextures(2, &self.header_textures[0]);
        if (self.buffers[0] != 0) gl.deleteBuffers(5, &self.buffers[0]) catch {};
        if (self.header_buffers[0] != 0) gl.deleteBuffers(2, &self.header_buffers[0]) catch {};
    }
    pub fn deinit(self: *Residency) void {
        var it = self.records.valueIterator();
        while (it.next()) |record| self.destroy(record.*);
        self.records.deinit();
        self.pending.deinit();
        for (&self.arenas) |*arena| arena.deinit();
        self.deleteGl(); // GL defers object destruction until queued uses finish.
    }
    fn releaseSource(self: *Residency, record: *Record) void {
        for (&record.data) |*data| {
            self.staging_bytes -= data.len;
            self.allocator.free(data.*);
            data.* = &.{};
        }
        if (record.tile) |*tile| {
            self.staging_bytes -= tile.nodes.len * @sizeOf(terrain.Node);
            tile.deinit(self.allocator);
            record.tile = null;
        }
    }
    fn destroy(self: *Residency, record: *Record) void {
        self.releaseSource(record);
        for (record.ranges, &self.arenas) |range, *arena| if (range) |h| arena.release(h) catch unreachable;
        record.dependencies.deinit();
        self.allocator.destroy(record);
    }
    // There is no pending transaction while this fence is outstanding. Entries
    // not in the current publication are now unreachable and safe to recycle.
    pub fn poll(self: *Residency) !bool {
        if (self.fence == null) return true;
        const status = c.__glewClientWaitSync.?(self.fence, c.GL_SYNC_FLUSH_COMMANDS_BIT, 0);
        if (status == c.GL_TIMEOUT_EXPIRED) return false;
        if (status == c.GL_WAIT_FAILED) return error.GeometryFenceFailed;
        c.__glewDeleteSync.?(self.fence);
        self.fence = null;
        self.reclaimRetired(true);
        return true;
    }
    fn reclaimRetired(self: *Residency, completed: bool) void {
        if (!completed) return;
        std.debug.assert(!self.transaction);
        // Hash-map removal leaves tombstones and does not move remaining entries.
        var it = self.records.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.published) continue;
            self.destroy(entry.value_ptr.*);
            self.records.removeByPtr(entry.key_ptr);
        }
    }
    pub fn begin(self: *Residency) !bool {
        std.debug.assert(!self.transaction);
        if (!try self.poll()) return false;
        var it = self.records.valueIterator();
        while (it.next()) |record| record.*.wanted = false;
        self.pending.clearRetainingCapacity();
        self.record_cursor = 0;
        self.pool_cursor = 0;
        self.byte_cursor = 0;
        self.header_cursor = 0;
        self.stats = .{};
        self.transaction = true;
        return true;
    }
    fn mark(self: *Residency, record: *Record) void {
        if (record.wanted) return;
        record.wanted = true;
        self.stats.reused_bytes += record.payload_bytes;
        if (record.key.kind == .tile) self.stats.reused_tiles += 1;
        for (record.dependencies.items) |child| self.mark(child);
    }
    pub fn find(self: *Residency, key: Key) ?*Record {
        const record = self.records.get(key) orelse return null;
        self.mark(record);
        return record;
    }
    pub fn create(self: *Residency, key: Key, lengths: [5]usize) !*Record {
        std.debug.assert(self.transaction and !self.records.contains(key));
        try self.pending.ensureUnusedCapacity(1);
        try self.records.ensureUnusedCapacity(1);
        const record = try self.allocator.create(Record);
        record.* = .{ .key = key, .dependencies = std.ArrayList(*Record).init(self.allocator) };
        errdefer self.destroy(record);
        for (lengths, 0..) |length, i| {
            if (length != 0) record.ranges[i] = try self.arenas[i].reserve(length);
            record.payload_bytes += length;
        }
        if (record.payload_bytes > @import("../rendering.zig").gpu_staging_bytes -| self.staging_bytes) return error.GeometryStagingLimit;
        self.records.putAssumeCapacity(key, record);
        self.pending.appendAssumeCapacity(record);
        if (key.kind == .tile) self.stats.new_tiles += 1;
        return record;
    }
    pub fn copy(self: *Residency, record: *Record, pool: usize, bytes: []const u8) !void {
        std.debug.assert(record.data[pool].len == 0);
        if (bytes.len == 0) return;
        record.data[pool] = try self.allocator.dupe(u8, bytes);
        self.staging_bytes += bytes.len;
    }
    pub fn pinTile(self: *Residency, record: *Record, tile: terrain.Tile) void {
        record.tile = tile.retain();
        self.staging_bytes += tile.nodes.len * @sizeOf(terrain.Node);
    }
    pub fn upload(self: *Residency, headers: []const u8, budget: usize, sent: *usize) !bool {
        std.debug.assert(headers.len == self.header_bytes and self.transaction);
        while (self.record_cursor < self.pending.items.len) {
            const record = self.pending.items[self.record_cursor];
            while (self.pool_cursor < 5) {
                const source = record.source(self.pool_cursor);
                if (self.byte_cursor < source.len) {
                    const count = @min(source.len - self.byte_cursor, budget -| sent.*);
                    if (count == 0) return false;
                    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.buffers[self.pool_cursor]);
                    try gl.bufferSubData(c.GL_TEXTURE_BUFFER, @intCast(record.base(self.pool_cursor) + self.byte_cursor), @intCast(count), source[self.byte_cursor..].ptr);
                    self.byte_cursor += count;
                    sent.* += count;
                    self.stats.payload_bytes += count;
                }
                if (self.byte_cursor < source.len) return false;
                self.pool_cursor += 1;
                self.byte_cursor = 0;
            }
            self.releaseSource(record);
            self.record_cursor += 1;
            self.pool_cursor = 0;
        }
        if (self.header_cursor < headers.len) {
            const count = @min(headers.len - self.header_cursor, budget -| sent.*);
            if (count == 0) return false;
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.header_buffers[1 - self.active_header]);
            try gl.bufferSubData(c.GL_TEXTURE_BUFFER, @intCast(self.header_cursor), @intCast(count), headers[self.header_cursor..].ptr);
            self.header_cursor += count;
            sent.* += count;
            self.stats.metadata_bytes += count;
        }
        return self.header_cursor == headers.len;
    }
    fn retireFence(self: *Residency) !void {
        std.debug.assert(self.fence == null);
        self.fence = c.__glewFenceSync.?(c.GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        if (self.fence == null) return error.GeometryFenceFailed;
    }
    pub fn publish(self: *Residency) !void {
        try self.retireFence();
        var it = self.records.valueIterator();
        while (it.next()) |record| record.*.published = record.*.wanted;
        self.active_header = 1 - self.active_header;
        self.published = true;
        self.transaction = false;
        self.last_stats = self.stats;
    }
    pub fn cancel(self: *Residency) !void {
        if (!self.transaction) return;
        try self.retireFence();
        for (self.pending.items) |record| self.releaseSource(record);
        self.transaction = false;
    }
    pub fn bind(self: *const Residency) void {
        gl.activeTexture(c.GL_TEXTURE0);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.header_textures[self.active_header]);
        for (self.textures, 0..) |texture, i| {
            gl.activeTexture(@intCast(c.GL_TEXTURE1 + i));
            gl.bindTexture(c.GL_TEXTURE_BUFFER, texture);
        }
    }
    pub fn allocatedBytes(self: *const Residency) usize {
        var bytes = self.header_bytes * 2;
        for (self.arenas) |arena| bytes += arena.capacity;
        return bytes;
    }
    pub fn retiredBytes(self: *const Residency) usize {
        var bytes: usize = 0;
        var it = self.records.valueIterator();
        while (it.next()) |record| if (!record.*.published) {
            for (record.*.ranges) |range| if (range) |h| {
                bytes += h.bytes;
            };
        };
        return bytes;
    }
};

test "geometry allocations stay disjoint, reject stale frees and coalesce" {
    var arena = try Arena.init(std.testing.allocator, 128);
    defer arena.deinit();
    const a = try arena.reserve(17);
    const b = try arena.reserve(64);
    const d = try arena.reserve(32);
    try std.testing.expectEqual(@as(u32, 32), a.bytes);
    try std.testing.expectError(error.GeometryCapacityExceeded, arena.reserve(1));
    try arena.release(b);
    const reused = try arena.reserve(48);
    try std.testing.expectEqual(b.base, reused.base);
    try std.testing.expectError(error.StaleGeometryHandle, arena.release(b));
    try std.testing.expect(a.base + a.bytes <= reused.base and reused.base + reused.bytes <= d.base);
    try arena.release(reused);
    try arena.release(a);
    try arena.release(d);
    try std.testing.expectEqual(@as(usize, 1), arena.spans.items.len);
    try std.testing.expectEqual(@as(u32, 128), (try arena.reserve(128)).bytes);
}

fn exerciseResidency(a: std.mem.Allocator) !void {
    var r = try Residency.initCpu(a, 256, .{ 64, 64, 64, 64, 64 });
    defer r.deinit();
    _ = try r.begin();
    const key = Key{ .kind = .tile, .coord = .{ -256, 0, 0 }, .version = 1 };
    const active = try r.create(key, .{ 0, 0, 0, 0, 32 });
    try r.copy(active, 4, &([_]u8{7} ** 32));
    active.published = true;
    r.transaction = false;
    _ = try r.begin();
    try std.testing.expect(r.find(key).? == active);
    try std.testing.expectEqual(@as(usize, 32), r.stats.reused_bytes);
    const cancelled = try r.create(.{ .kind = .tile, .coord = .{ 0, 0, 0 }, .version = 2 }, .{ 0, 0, 0, 0, 32 });
    const old = cancelled.ranges[4].?;
    r.transaction = false; // simulate cancellation with a completion token pending
    r.reclaimRetired(false);
    try std.testing.expectError(error.GeometryCapacityExceeded, r.arenas[4].reserve(16));
    r.reclaimRetired(true);
    try std.testing.expect(r.records.get(key).? == active);
    const replacement = try r.arenas[4].reserve(32);
    try std.testing.expectEqual(old.base, replacement.base);
    try std.testing.expectError(error.StaleGeometryHandle, r.arenas[4].release(old));
    try r.arenas[4].release(replacement);
    _ = try r.begin();
    // A later-pool reservation failure rolls back every earlier reservation.
    if (r.create(.{ .kind = .block, .coord = .{ 0, 0, 0 }, .version = 3 }, .{ 32, 128, 0, 0, 0 })) |_| {
        return error.ExpectedCapacityFailure;
    } else |err| {
        if (err == error.OutOfMemory) return err;
        try std.testing.expectEqual(error.GeometryCapacityExceeded, err);
    }
    try std.testing.expectEqual(@as(usize, 1), r.arenas[0].spans.items.len);
}
test "retirement waits for completion and allocation failures release ownership" {
    try exerciseResidency(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseResidency, .{});
}
