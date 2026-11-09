//! One worker, immutable requests, and complete versioned coverage replacements.
//! Publication changes the whole horizontal window atomically so balancing also
//! holds across tile boundaries while moving. Vertical chunks share each tile.
const std = @import("std");
const policy = @import("../../rendering.zig");
const terrain = @import("../terrainHierarchy.zig");
const generator = @import("terrainGenerator.zig");
pub const window_side = @import("../worldConstants.zig").STREAM_CHUNKS_XZ;
pub const tile_count = window_side * window_side;
pub const Budgets = struct {
    payload_bytes: usize = 24 * 1024 * 1024,
    owned_payload_bytes: usize = 96 * 1024 * 1024,
    completed_bytes: usize = 24 * 1024 * 1024,
    slice_samples: usize = 2048,
    slice_ns: u64 = 2 * std.time.ns_per_ms,
};
pub const Request = struct { policy: policy.Snapshot, origin: [2]i32, token: u64, submitted_ns: i128 = 0 };
pub const Batch = struct {
    request: Request,
    config_revision: u64,
    tiles: [tile_count]terrain.Tile = undefined,
    ready: [tile_count]bool = .{false} ** tile_count,
    bytes: usize = @sizeOf(Batch),
    stats: generator.Stats = .{},
    cache_bytes: usize = 0,
    build_ns: u64 = 0,
    queue_ns: u64 = 0,
    reused_tiles: usize = 0,
    coarse: bool,
    pub fn deinit(self: *Batch, allocator: std.mem.Allocator) void {
        for (&self.tiles, self.ready) |*item, ready| if (ready) item.deinit(allocator);
        allocator.destroy(self);
    }
    pub fn tile(self: *const Batch, x: i32, z: i32) ?*const terrain.Tile {
        const rx = @divFloor(x, 256) - self.request.origin[0];
        const rz = @divFloor(z, 256) - self.request.origin[1];
        if (rx < 0 or rz < 0 or rx >= window_side or rz >= window_side) return null;
        const index: usize = @intCast(rx + rz * window_side);
        return if (self.ready[index]) &self.tiles[index] else null;
    }
};
const TileCache = std.AutoHashMap([2]i32, terrain.Tile);
pub const Stream = struct {
    allocator: std.mem.Allocator,
    config: generator.Config,
    budgets: Budgets,
    payload_allocator: generator.BudgetAllocator,
    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    stop: bool = false,
    request: ?Request = null,
    completed: ?*Batch = null,
    resident: ?*Batch = null, // main-thread only
    failures: u64 = 0,
    discarded: u64 = 0,
    submitted: u64 = 0,
    committed: u64 = 0,
    pub fn init(allocator: std.mem.Allocator, config: generator.Config, budgets: Budgets) !Stream {
        try config.validate();
        if (budgets.payload_bytes < 1024 * 1024 or budgets.completed_bytes < budgets.payload_bytes or budgets.owned_payload_bytes < budgets.payload_bytes or budgets.slice_samples == 0 or budgets.slice_ns == 0) return error.InvalidBudget;
        return .{ .allocator = allocator, .config = config, .budgets = budgets, .payload_allocator = .{ .backing = allocator, .limit = budgets.owned_payload_bytes } };
    }
    pub fn start(self: *Stream) !void {
        if (self.thread == null) self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn deinit(self: *Stream) void {
        self.mutex.lock();
        self.stop = true;
        self.cv.signal();
        self.mutex.unlock();
        if (self.thread) |thread| thread.join();
        if (self.completed) |batch| batch.deinit(self.allocator);
        if (self.resident) |batch| batch.deinit(self.allocator);
    }
    pub fn update(self: *Stream, snapshot: policy.Snapshot, position: [3]f32) void {
        const origin = [2]i32{ @divFloor(@as(i32, @intFromFloat(@floor(position[0]))), 256) - window_side / 2, @divFloor(@as(i32, @intFromFloat(@floor(position[2]))), 256) - window_side / 2 };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request) |old| if (old.policy.revision == snapshot.revision and std.meta.eql(old.origin, origin)) return;
        self.submitted += 1;
        self.request = .{ .policy = snapshot, .origin = origin, .token = self.submitted, .submitted_ns = std.time.nanoTimestamp() };
        self.cv.signal();
    }
    pub fn take(self: *Stream) ?*Batch {
        self.mutex.lock();
        defer self.mutex.unlock();
        const batch = self.completed orelse return null;
        self.completed = null;
        self.cv.signal();
        if (self.request == null or batch.request.token != self.request.?.token or batch.config_revision != self.config.revision) {
            batch.deinit(self.allocator);
            self.discarded += 1;
            return null;
        }
        self.committed += 1;
        return batch;
    }
    fn current(self: *Stream, token: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return !self.stop and self.request != null and self.request.?.token == token;
    }
    fn deliver(self: *Stream, batch: *Batch) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.stop and self.request.?.token == batch.request.token and self.completed != null) self.cv.wait(&self.mutex);
        if (self.stop or self.request.?.token != batch.request.token) {
            batch.deinit(self.allocator);
            self.discarded += 1;
            return false;
        }
        self.completed = batch;
        return true;
    }
    fn build(self: *Stream, sampler: *generator.Sampler, cache: *TileCache, request: Request, minimum: u32) !*Batch {
        var timer = try std.time.Timer.start();
        const queued = std.time.nanoTimestamp() - request.submitted_ns;
        const batch = try self.allocator.create(Batch);
        batch.* = .{ .request = request, .config_revision = self.config.revision, .coarse = minimum == 256 };
        errdefer batch.deinit(self.allocator);
        var order: [tile_count]usize = undefined;
        for (&order, 0..) |*index, i| index.* = i;
        const Context = struct {
            request: Request,
            fn less(ctx: @This(), a: usize, b: usize) bool {
                const ax = (ctx.request.origin[0] + @as(i32, @intCast(a % window_side))) * 256;
                const az = (ctx.request.origin[1] + @as(i32, @intCast(a / window_side))) * 256;
                const bx = (ctx.request.origin[0] + @as(i32, @intCast(b % window_side))) * 256;
                const bz = (ctx.request.origin[1] + @as(i32, @intCast(b / window_side))) * 256;
                return policy.distanceToBounds(.{ ax, 0, az }, 256, ctx.request.policy.focus) < policy.distanceToBounds(.{ bx, 0, bz }, 256, ctx.request.policy.focus);
            }
        };
        std.mem.sort(usize, &order, Context{ .request = request }, Context.less);
        for (order) |i| {
            if (!self.current(request.token)) return error.Obsolete;
            const x = (request.origin[0] + @as(i32, @intCast(i % window_side))) * 256;
            const z = (request.origin[1] + @as(i32, @intCast(i / window_side))) * 256;
            if (minimum == 1) {
                if (cache.getPtr(.{ x, z })) |old| {
                    if (old.matches(&request.policy)) {
                        batch.tiles[i] = old.retain();
                        batch.ready[i] = true;
                        batch.bytes += old.nodes.len * @sizeOf(terrain.Node);
                        batch.reused_tiles += 1;
                        if (batch.bytes > self.budgets.payload_bytes) return error.PayloadBudgetExceeded;
                        continue;
                    }
                }
            }
            var builder = try terrain.Builder.init(self.payload_allocator.allocator(), x, z, request.policy, minimum, self.budgets.payload_bytes - batch.bytes);
            defer builder.deinit();
            while (!try builder.advance(sampler, self.budgets.slice_samples, self.budgets.slice_ns)) {
                if (!self.current(request.token)) return error.Obsolete;
            }
            batch.tiles[i] = try builder.finish(self.config.revision);
            batch.ready[i] = true;
            batch.bytes += batch.tiles[i].nodes.len * @sizeOf(terrain.Node);
            if (batch.bytes > self.budgets.payload_bytes) return error.PayloadBudgetExceeded;
            if (minimum == 1) {
                const gop = try cache.getOrPut(.{ x, z });
                if (gop.found_existing) gop.value_ptr.deinit(self.allocator);
                gop.value_ptr.* = batch.tiles[i].retain();
                var cached_bytes: usize = 0;
                var values = cache.valueIterator();
                while (values.next()) |value| cached_bytes += value.nodes.len * @sizeOf(terrain.Node);
                while (cached_bytes > self.budgets.payload_bytes) {
                    var keys = cache.keyIterator();
                    const key = keys.next().?.*;
                    var removed = cache.fetchRemove(key).?;
                    cached_bytes -= removed.value.nodes.len * @sizeOf(terrain.Node);
                    removed.value.deinit(self.allocator);
                }
            }
        }
        batch.build_ns = timer.read();
        batch.queue_ns = @intCast(@max(queued, 0));
        batch.stats = sampler.stats;
        batch.cache_bytes = sampler.budget.used;
        return batch;
    }
    fn run(self: *Stream) void {
        var sampler = generator.Sampler.init(self.allocator, self.config) catch return;
        defer sampler.deinit();
        var cache = TileCache.init(self.allocator);
        defer {
            var it = cache.valueIterator();
            while (it.next()) |tile| tile.deinit(self.allocator);
            cache.deinit();
        }
        var handled: u64 = 0;
        var first = true;
        while (true) {
            self.mutex.lock();
            while (!self.stop and (self.request == null or self.request.?.token == handled)) self.cv.wait(&self.mutex);
            if (self.stop) {
                self.mutex.unlock();
                return;
            }
            const request = self.request.?;
            handled = request.token;
            self.mutex.unlock();
            // Retain at most one window of reusable payloads. Cache identity is
            // origin + generator revision; policy only decides whether its shape fits.
            var remove: [tile_count][2]i32 = undefined;
            var count: usize = 0;
            var it = cache.iterator();
            var retained_bytes: usize = 0;
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                retained_bytes += entry.value_ptr.nodes.len * @sizeOf(terrain.Node);
                if (key[0] < request.origin[0] * 256 or key[0] >= (request.origin[0] + window_side) * 256 or key[1] < request.origin[1] * 256 or key[1] >= (request.origin[1] + window_side) * 256 or retained_bytes > self.budgets.payload_bytes) {
                    remove[count] = key;
                    count += 1;
                }
            }
            for (remove[0..count]) |key| {
                var removed = cache.fetchRemove(key).?;
                removed.value.deinit(self.allocator);
            }
            if (first) {
                const coarse = self.build(&sampler, &cache, request, 256) catch continue;
                if (!self.deliver(coarse)) continue;
                first = false;
            }
            const batch = self.build(&sampler, &cache, request, 1) catch |err| {
                self.mutex.lock();
                if (err == error.Obsolete) self.discarded += 1 else self.failures += 1;
                self.mutex.unlock();
                continue;
            };
            _ = self.deliver(batch);
        }
    }
};

test "obsolete completed terrain is rejected and unchanged focus queues nothing" {
    var stream = try Stream.init(std.testing.allocator, .{}, .{});
    defer stream.deinit();
    var focus = policy.FocusState{};
    const first = try focus.resolve(policy.terrain_settings, .{ 0, 0, 0 });
    stream.update(first, first.focus);
    stream.update(first, first.focus);
    try std.testing.expectEqual(@as(u64, 1), stream.submitted);
    const batch = try std.testing.allocator.create(Batch);
    batch.* = .{ .request = stream.request.?, .config_revision = 1, .coarse = true };
    stream.completed = batch;
    const moved = try focus.resolve(policy.terrain_settings, .{ -4097, 0, 4097 });
    stream.update(moved, moved.focus);
    try std.testing.expect(stream.take() == null);
    try std.testing.expectEqual(@as(u64, 1), stream.discarded);
}

test "moving demands reuse unchanged tiles, reconstruct evictions and bound memory" {
    const a = std.testing.allocator;
    var stream = try Stream.init(a, .{ .cache_bytes = 2 * 1024 * 1024, .max_regions = 2 }, .{});
    defer stream.deinit();
    var sampler = try generator.Sampler.init(a, stream.config);
    defer sampler.deinit();
    var cache = TileCache.init(a);
    defer {
        var values = cache.valueIterator();
        while (values.next()) |tile| tile.deinit(a);
        cache.deinit();
    }
    var state = policy.FocusState{};
    const rings = [_]policy.Ring{ .{ .outer_radius_voxels = 1, .cell_size_voxels = 1 }, .{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 } };
    const settings = policy.Settings{ .geometry_rings = &rings, .interaction_radius_voxels = 0, .transition_width_voxels = 0 };
    var anchor: ?i32 = null;
    for ([_]f32{ -4097, -4090, -4070, 32768, -4097 }, 0..) |x, frame| {
        const snapshot = try state.resolve(settings, .{ x, 0, -1 });
        stream.update(snapshot, .{ x, 0, -1 });
        // Long walks evict obsolete tile payloads; samples have an independent cap.
        var values = cache.valueIterator();
        while (values.next()) |tile| tile.deinit(a);
        cache.clearRetainingCapacity();
        const batch = try stream.build(&sampler, &cache, stream.request.?, 1);
        defer batch.deinit(a);
        try std.testing.expect(batch.bytes <= stream.budgets.payload_bytes);
        try std.testing.expect(sampler.budget.peak <= stream.config.cache_bytes);
        if (frame == 0) anchor = batch.tile(-4097, -1).?.at(-4097, -1).height;
        if (frame == 4) try std.testing.expectEqual(anchor.?, batch.tile(-4097, -1).?.at(-4097, -1).height);
        const samples = sampler.stats.requested;
        const cached = try stream.build(&sampler, &cache, stream.request.?, 1);
        defer cached.deinit(a);
        try std.testing.expectEqual(@as(usize, tile_count), cached.reused_tiles);
        try std.testing.expectEqual(samples, sampler.stats.requested);
        // Shapes and heights are byte-identical regardless of request history.
        for (batch.tiles, cached.tiles) |first, second| try std.testing.expectEqualSlices(terrain.Node, first.nodes, second.nodes);
    }
    try std.testing.expect(sampler.stats.evictions > 0);
}

test "real worker delivers coarse coverage before complete refinement and stops cleanly" {
    var stream = try Stream.init(std.testing.allocator, .{ .flat = true }, .{});
    defer stream.deinit();
    var state = policy.FocusState{};
    const rings = [_]policy.Ring{.{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 }};
    const snapshot = try state.resolve(.{ .geometry_rings = &rings, .interaction_radius_voxels = 0 }, .{ 0, 0, 0 });
    stream.update(snapshot, snapshot.focus);
    try stream.start();
    var timer = try std.time.Timer.start();
    var delivered: usize = 0;
    while (delivered < 2 and timer.read() < 10 * std.time.ns_per_s) {
        if (stream.take()) |batch| {
            defer batch.deinit(std.testing.allocator);
            try std.testing.expectEqual(delivered == 0, batch.coarse);
            const low_x = batch.request.origin[0] * 256;
            const low_z = batch.request.origin[1] * 256;
            const high_x = low_x + window_side * 256;
            const high_z = low_z + window_side * 256;
            for ([_]i32{ low_x, high_x - 1 }) |x| for ([_]i32{ low_z, high_z - 1 }) |z| {
                const edge = batch.tile(x, z).?;
                try std.testing.expectEqual(policy.aligned(x, 256), edge.x);
                try std.testing.expectEqual(policy.aligned(z, 256), edge.z);
                try std.testing.expectEqual(@as(u32, 256), edge.at(x, z).side);
            };
            try std.testing.expect(batch.tile(low_x - 1, low_z) == null);
            try std.testing.expect(batch.tile(high_x, low_z) == null);
            try std.testing.expect(batch.tile(low_x, low_z - 1) == null);
            try std.testing.expect(batch.tile(low_x, high_z) == null);
            if (delivered == 1) try std.testing.expectEqual(@as(u32, 1), batch.tile(0, 0).?.at(0, 0).side);
            delivered += 1;
        } else std.Thread.sleep(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 2), delivered);
    stream.update(snapshot, snapshot.focus);
    try std.testing.expectEqual(@as(u64, 1), stream.submitted);
}
