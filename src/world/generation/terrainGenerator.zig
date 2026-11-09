//! Worker-owned deterministic height cache. Player position is never noise identity.
const std = @import("std");
const region = @import("superchunk.zig");
const ds = @import("noises/diamondSquare.zig");
pub const profile_version: u32 = 2;
pub const steps = [_]i32{
    512, // Root amplitude.
    220,
    160,
    100,
    80,
    60,
    40,
    30,
    20,
    16,
    12,
    8,
    6,
    4,
    3,
    2,
    1,
    1, 1, // Spacing 8: last level with random displacement.
    // Final three refinements (8 -> 4 -> 2 -> 1) only average their parents.
    // Zero both passes at each level, preserving existing coarse anchors.
    0, 0,
    0, 0,
    0, 0,
};
pub const Noise = ds.DiamondSquare(&steps);
pub const Config = struct {
    seed: u64 = 0x123456789abcdef0,
    base_height: i32 = 128,
    revision: u64 = 1,
    flat: bool = false,
    cache_bytes: usize = 96 * 1024 * 1024,
    max_regions: usize = 8,
    pub fn validate(self: Config) !void {
        if (self.base_height < -1000000 or self.base_height > 1000000) return error.InvalidElevation;
        if (self.cache_bytes < 128 * 1024 or self.max_regions == 0 or self.max_regions > 64) return error.InvalidBudget;
    }
};

/// Counts actual allocation sizes, including hash capacity and transient rehash
/// copies. Must remain at a stable address while its allocator is in use.
pub const BudgetAllocator = struct {
    backing: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    limit: usize,
    used: usize = 0,
    peak: usize = 0,
    pub fn allocator(self: *BudgetAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (len > self.limit - self.used) return null;
        const p = self.backing.rawAlloc(len, alignment, ra) orelse return null;
        self.used += len;
        self.peak = @max(self.peak, self.used);
        return p;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (len > buf.len and len - buf.len > self.limit - self.used) return false;
        if (!self.backing.rawResize(buf, alignment, len, ra)) return false;
        self.used = self.used - buf.len + len;
        self.peak = @max(self.peak, self.used);
        return true;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (len > buf.len and len - buf.len > self.limit - self.used) return null;
        const p = self.backing.rawRemap(buf, alignment, len, ra) orelse return null;
        self.used = self.used - buf.len + len;
        self.peak = @max(self.peak, self.used);
        return p;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BudgetAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.backing.rawFree(buf, alignment, ra);
        self.used -= buf.len;
    }
};

pub const Stats = struct {
    requested: u64 = 0,
    outputs_by_level: [5]u64 = .{0} ** 5,
    base_samples: u64 = 0,
    new_outputs: u64 = 0,
    hits: u64 = 0,
    generated: [13]u64 = .{0} ** 13,
    evictions: u64 = 0,
    worst_sample_ns: u64 = 0,
    work_ns: u64 = 0,
};
const Key = struct { x: i32, z: i32 };
const Entry = struct { key: Key, noise: Noise.Sparse, age: u64 };
pub const Sampler = struct {
    allocator: std.mem.Allocator,
    budget: BudgetAllocator,
    config: Config,
    entries: std.ArrayList(Entry),
    stats: Stats = .{},
    tick: u64 = 0,
    pub fn init(allocator: std.mem.Allocator, config: Config) !Sampler {
        try config.validate();
        return .{ .allocator = allocator, .budget = .{ .backing = allocator, .limit = config.cache_bytes }, .config = config, .entries = std.ArrayList(Entry).init(allocator) };
    }
    pub fn deinit(self: *Sampler) void {
        for (self.entries.items) |*entry| entry.noise.deinit();
        self.entries.deinit();
        std.debug.assert(self.budget.used == 0);
    }
    fn evict(self: *Sampler) void {
        if (self.entries.items.len == 0) return;
        var oldest: usize = 0;
        for (self.entries.items, 0..) |entry, i| if (entry.age < self.entries.items[oldest].age) {
            oldest = i;
        };
        var entry = self.entries.swapRemove(oldest);
        entry.noise.deinit();
        self.stats.evictions += 1;
    }
    fn getEntry(self: *Sampler, key: Key) !*Entry {
        self.entries.allocator = self.budget.allocator();
        for (self.entries.items) |*e| if (std.meta.eql(e.key, key)) {
            e.age = self.tick;
            return e;
        };
        if (self.entries.items.len >= self.config.max_regions) self.evict();
        var noise = try Noise.Sparse.init(self.budget.allocator(), .{ .seed = self.config.seed, .position = .{ .x = .{ .superchunk = key.x }, .y = .{ .superchunk = key.z } } }, 256);
        errdefer noise.deinit();
        try self.entries.append(.{ .key = key, .noise = noise, .age = self.tick });
        self.stats.base_samples += noise.base.grid().values.len;
        return &self.entries.items[self.entries.items.len - 1];
    }
    pub fn height(self: *Sampler, x: i32, z: i32, spacing: u32) !i32 {
        if (std.mem.indexOfScalar(u32, &@import("../../rendering.zig").cell_sizes, spacing) == null) return error.InvalidResolution;
        if (@mod(x, @as(i32, @intCast(spacing))) != 0 or @mod(z, @as(i32, @intCast(spacing))) != 0) return error.InvalidSample;
        if (@abs(@as(i64, x)) > 100000000 or @abs(@as(i64, z)) > 100000000) return error.CoordinateOverflow;
        self.stats.requested += 1;
        self.stats.outputs_by_level[std.mem.indexOfScalar(u32, &@import("../../rendering.zig").cell_sizes, spacing).?] += 1;
        if (self.config.flat) return self.config.base_height;
        var timer = try std.time.Timer.start();
        defer {
            const elapsed = timer.read();
            self.stats.work_ns += elapsed;
            self.stats.worst_sample_ns = @max(self.stats.worst_sample_ns, elapsed);
        }
        self.tick += 1;
        // A failed recursive sample leaves useful valid dependencies. Evict a
        // whole cache and retry; never exceed the hard allocation budget.
        var attempts: usize = 0;
        while (attempts <= self.config.max_regions + 1) : (attempts += 1) {
            const e = self.getEntry(.{ .x = @divFloor(x, region.side), .z = @divFloor(z, region.side) }) catch |err| {
                if (err != error.OutOfMemory) return err;
                self.evict();
                continue;
            };
            const lx: u32 = @intCast(@mod(x, region.side));
            const lz: u32 = @intCast(@mod(z, region.side));
            if (e.noise.sampleCached(lx, lz)) |value| {
                self.stats.hits += 1;
                return std.math.add(i32, self.config.base_height, value);
            }
            const before = e.noise.generated_by_level;
            const result = e.noise.sampleAt(lx, lz, spacing);
            for (before, e.noise.generated_by_level, 0..) |a, b, i| self.stats.generated[i] += b - a;
            const value = result catch |err| {
                if (err != error.OutOfMemory) return err;
                self.evict();
                continue;
            };
            self.stats.new_outputs += 1;
            return std.math.add(i32, self.config.base_height, value);
        }
        return error.OutOfMemory;
    }
};

/// Resumable aligned rectangle. A recursive sample is the indivisible unit;
/// dependency budget and wall time are checked immediately after every output.
pub const AreaJob = struct {
    x: i32,
    z: i32,
    spacing: u32,
    width: u32,
    height: u32,
    cursor: usize = 0,
    pub fn advance(self: *AreaJob, sampler: *Sampler, output: []i32, max_samples: usize, max_ns: u64) !bool {
        if (output.len != @as(usize, self.width) * self.height or self.width == 0 or self.height == 0) return error.InvalidArea;
        var timer = try std.time.Timer.start();
        const before = sampler.stats.generated;
        var count: usize = 0;
        while (self.cursor < output.len and count < max_samples and timer.read() < max_ns) {
            const x = @as(i64, self.x) + @as(i64, @intCast(self.cursor % self.width)) * self.spacing;
            const z = @as(i64, self.z) + @as(i64, @intCast(self.cursor / self.width)) * self.spacing;
            output[self.cursor] = try sampler.height(std.math.cast(i32, x) orelse return error.CoordinateOverflow, std.math.cast(i32, z) orelse return error.CoordinateOverflow, self.spacing);
            self.cursor += 1;
            count += 1;
            var generated: u64 = 0;
            for (before, sampler.stats.generated) |a, b| generated += b - a;
            if (generated >= max_samples) break;
        }
        return self.cursor == output.len;
    }
};

test "runtime sparse heights preserve anchors, signed ownership and bounded eviction" {
    var sampler = try Sampler.init(std.testing.allocator, .{ .max_regions = 1, .cache_bytes = 256 * 1024 });
    defer sampler.deinit();
    const h = try sampler.height(-4096, 0, 256);
    try std.testing.expectEqual(h, try sampler.height(-4096, 0, 1));
    _ = try sampler.height(4096, 0, 1);
    try std.testing.expectEqual(h, try sampler.height(-4096, 0, 4));
    var direct = try Noise.Sparse.init(std.testing.allocator, .{ .position = .{ .x = .{ .superchunk = -1 }, .y = .{ .superchunk = 0 } }, .seed = sampler.config.seed }, 256);
    defer direct.deinit();
    for ([_]u32{ 1, 4, 16, 64, 256 }) |spacing| {
        const x: i32 = -@as(i32, @intCast(spacing));
        try std.testing.expectEqual(sampler.config.base_height + try direct.sampleAt(@intCast(4096 + x), spacing, spacing), try sampler.height(x, @intCast(spacing), spacing));
    }
    try std.testing.expect(sampler.budget.peak <= sampler.config.cache_bytes);
    try std.testing.expect(sampler.stats.evictions >= 2);
    var output: [64]i32 = undefined;
    var job = AreaJob{ .x = -8, .z = -8, .spacing = 1, .width = 8, .height = 8 };
    try std.testing.expect(!try job.advance(&sampler, &output, 1, std.time.ns_per_s));
    while (!try job.advance(&sampler, &output, 8, std.time.ns_per_s)) {}
    for (output, 0..) |value, i| try std.testing.expectEqual(value, try sampler.height(-8 + @as(i32, @intCast(i % 8)), -8 + @as(i32, @intCast(i / 8)), 1));
}
