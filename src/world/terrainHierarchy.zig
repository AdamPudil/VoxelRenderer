//! Column quadtree, separate from authored exact occupancy summaries. A terminal
//! represents a vertical run below height, clipped by the streamed Y bounds.
const std = @import("std");
const policy = @import("../rendering.zig");
const generator = @import("generation/terrainGenerator.zig");
pub const State = enum { exact, proxy, branch, pending };
/// GPU ABI: four words. children is a relative node index (zero = terminal).
/// Heights are signed and exclusive. Side and origin follow from tree descent.
pub const Node = extern struct { children: u32 = 0, height: i32 = 0, min_height: i32 = 0, max_height: i32 = 0 };
var next_payload_id = std.atomic.Value(u64).init(1);
const Storage = struct { allocator: std.mem.Allocator, id: u64, references: std.atomic.Value(usize) = std.atomic.Value(usize).init(1) };
pub const Sample = struct {
    height: i32,
    side: u32,
    pub fn state(self: Sample) State {
        return if (self.side == 1) .exact else .proxy;
    }
};
pub const Tile = struct {
    x: i32,
    z: i32,
    revision: u64,
    nodes: []Node,
    storage: ?*Storage = null,
    pub fn payloadId(self: Tile) u64 {
        return self.storage.?.id;
    }
    pub fn deinit(self: *Tile, allocator: std.mem.Allocator) void {
        if (self.storage) |storage| {
            if (storage.references.fetchSub(1, .acq_rel) != 1) return;
            const owner = storage.allocator;
            owner.destroy(storage);
            owner.free(self.nodes);
            return;
        }
        allocator.free(self.nodes);
    }
    pub fn retain(self: Tile) Tile {
        _ = self.storage.?.references.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn matches(self: *const Tile, snapshot: *const policy.Snapshot) bool {
        return self.matchesNode(0, self.x, self.z, 256, snapshot);
    }
    fn matchesNode(self: *const Tile, index: u32, x: i32, z: i32, side: u32, snapshot: *const policy.Snapshot) bool {
        if (side == 1) return true;
        const split = snapshot.needsSplit(x, z, side);
        const children = self.nodes[index].children;
        if (split != (children != 0)) return false;
        if (!split) return true;
        for (0..16) |i| if (!self.matchesNode(children + @as(u32, @intCast(i)), x + @as(i32, @intCast(i % 4 * (side / 4))), z + @as(i32, @intCast(i / 4 * (side / 4))), side / 4, snapshot)) return false;
        return true;
    }
    pub fn at(self: *const Tile, x: i32, z: i32) Sample {
        std.debug.assert(x >= self.x and x < self.x + 256 and z >= self.z and z < self.z + 256);
        var index: u32 = 0;
        var side: u32 = 256;
        const lx: u32 = @intCast(x - self.x);
        const lz: u32 = @intCast(z - self.z);
        while (self.nodes[index].children != 0) {
            side /= 4;
            index = self.nodes[index].children + (lx / side % 4) + (lz / side % 4) * 4;
        }
        return .{ .height = self.nodes[index].height, .side = side };
    }
};
const Pending = struct { index: u32, x: i32, z: i32, side: u32 };
pub const Builder = struct {
    nodes: std.ArrayList(Node),
    stack: [61]Pending = undefined,
    count: usize = 1,
    x: i32,
    z: i32,
    policy: policy.Snapshot,
    minimum_side: u32,
    max_bytes: usize,
    pub fn init(allocator: std.mem.Allocator, x: i32, z: i32, snapshot: policy.Snapshot, minimum_side: u32, max_bytes: usize) !Builder {
        if (@mod(x, 256) != 0 or @mod(z, 256) != 0) return error.InvalidOrigin;
        if (std.mem.indexOfScalar(u32, &policy.cell_sizes, minimum_side) == null) return error.InvalidResolution;
        if (max_bytes < @sizeOf(Node)) return error.PayloadBudgetExceeded;
        var self = Builder{ .nodes = std.ArrayList(Node).init(allocator), .x = x, .z = z, .policy = snapshot, .minimum_side = minimum_side, .max_bytes = max_bytes };
        try self.nodes.append(.{});
        self.stack[0] = .{ .index = 0, .x = x, .z = z, .side = 256 };
        return self;
    }
    pub fn deinit(self: *Builder) void {
        self.nodes.deinit();
    }
    pub fn advance(self: *Builder, sampler: *generator.Sampler, max_samples: usize, max_ns: u64) !bool {
        var timer = try std.time.Timer.start();
        const before = sampler.stats.generated;
        var outputs: usize = 0;
        while (self.count > 0 and outputs < max_samples and timer.read() < max_ns) {
            const p = self.stack[self.count - 1];
            if (p.side > self.minimum_side and self.policy.needsSplit(p.x, p.z, p.side)) {
                if ((self.nodes.items.len + 16) * @sizeOf(Node) > self.max_bytes) return error.PayloadBudgetExceeded;
                const base: u32 = @intCast(self.nodes.items.len);
                try self.nodes.appendNTimes(.{}, 16);
                self.nodes.items[p.index].children = base;
                self.count -= 1;
                for (0..16) |i| {
                    const child: u32 = @intCast(15 - i);
                    const side = p.side / 4;
                    self.stack[self.count] = .{ .index = base + child, .x = p.x + @as(i32, @intCast(child % 4 * side)), .z = p.z + @as(i32, @intCast(child / 4 * side)), .side = side };
                    self.count += 1;
                }
            } else {
                const height = try sampler.height(p.x, p.z, p.side);
                const surface = policy.aligned(height, p.side);
                self.nodes.items[p.index] = .{ .height = surface, .min_height = surface, .max_height = surface };
                self.count -= 1;
                outputs += 1;
                var generated: u64 = 0;
                for (before, sampler.stats.generated) |a, b| generated += b - a;
                if (generated >= max_samples) break;
            }
        }
        return self.count == 0;
    }
    pub fn finish(self: *Builder, revision: u64) !Tile {
        if (self.count != 0) return error.Pending;
        // Children are allocated after their parent; reverse order computes
        // published vertical bounds without visiting any finest descendants.
        var i = self.nodes.items.len;
        while (i > 0) {
            i -= 1;
            const base = self.nodes.items[i].children;
            if (base == 0) continue;
            var low: i32 = std.math.maxInt(i32);
            var high: i32 = std.math.minInt(i32);
            for (self.nodes.items[base..][0..16]) |node| {
                low = @min(low, node.min_height);
                high = @max(high, node.max_height);
            }
            self.nodes.items[i].min_height = low;
            self.nodes.items[i].max_height = high;
        }
        const storage = try self.nodes.allocator.create(Storage);
        errdefer self.nodes.allocator.destroy(storage);
        storage.* = .{ .allocator = self.nodes.allocator, .id = next_payload_id.fetchAdd(1, .monotonic) };
        return .{ .x = self.x, .z = self.z, .revision = revision, .nodes = try self.nodes.toOwnedSlice(), .storage = storage };
    }
};

test "all terrain levels build directly with signed exclusive surfaces" {
    var sampler = try generator.Sampler.init(std.testing.allocator, .{ .flat = true, .base_height = -3 });
    defer sampler.deinit();
    var focus = policy.FocusState{};
    const snapshot = try focus.resolve(policy.terrain_settings, .{ 0, 0, 0 });
    for (policy.cell_sizes) |side| {
        var builder = try Builder.init(std.testing.allocator, -256, 0, snapshot, side, 2 * 1024 * 1024);
        defer builder.deinit();
        while (!try builder.advance(&sampler, 1024, std.time.ns_per_s)) {}
        var tile = try builder.finish(1);
        defer tile.deinit(std.testing.allocator);
        const sample = tile.at(-1, 5);
        try std.testing.expectEqual(side, sample.side);
        try std.testing.expectEqual(-@as(i32, @intCast(side)) * @as(i32, if (side == 1) 3 else 1), sample.height);
        try std.testing.expectEqual(if (side == 1) State.exact else State.proxy, sample.state());
        if (side == 256) try std.testing.expectEqual(@as(usize, 1), tile.nodes.len);
    }
}

test "mixed columns are balanced across negative chunk boundaries" {
    var sampler = try generator.Sampler.init(std.testing.allocator, .{ .flat = true });
    defer sampler.deinit();
    var state = policy.FocusState{};
    const rings = [_]policy.Ring{ .{ .outer_radius_voxels = 1, .cell_size_voxels = 1 }, .{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 } };
    const snapshot = try state.resolve(.{ .geometry_rings = &rings, .interaction_radius_voxels = 0, .hysteresis_voxels = 0, .transition_width_voxels = 0 }, .{ 0, 0, 0 });
    var tiles: [4]Tile = undefined;
    var count: usize = 0;
    defer for (tiles[0..count]) |*tile| tile.deinit(std.testing.allocator);
    for (0..4) |i| {
        var builder = try Builder.init(std.testing.allocator, @as(i32, @intCast(i)) * 256 - 256, 0, snapshot, 1, 2 * 1024 * 1024);
        defer builder.deinit();
        while (!try builder.advance(&sampler, 4096, std.time.ns_per_s)) {}
        tiles[i] = try builder.finish(1);
        count += 1;
    }
    var x: i32 = -255;
    while (x < 768) : (x += 1) for (0..256) |z| {
        const a = tiles[@intCast(@divFloor(x + 256, 256))].at(x, @intCast(z));
        const b = tiles[@intCast(@divFloor(x + 255, 256))].at(x - 1, @intCast(z));
        try std.testing.expect(@max(a.side, b.side) <= @min(a.side, b.side) * 4);
    };
}
