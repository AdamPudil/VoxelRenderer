//! Runtime hierarchy policy. Distances and cell sizes are world voxel units.
const std = @import("std");
pub const cell_sizes = [_]u32{ 1, 4, 16, 64, 256 };
pub const refinement = 4;
pub const children = refinement * refinement * refinement;
pub const max_rings = 8;
// The current runtime generator produces proven uniform chunks in O(1).
// Bound delivery/pending work while preserving completed parents until publish.
pub const generation_chunks_per_frame = 32;
pub const pending_generation_chunks = 128;
pub const lighting_cache_entries_per_frame = 65536;
pub const upload_bytes_per_frame = 8 * 1024 * 1024;
// Stable pools: block headers, voxel headers, bitmaps, palettes, index/terrain.
// Capacity includes published, pending and fence-retired ranges (86 MiB total).
pub const gpu_arena_bytes = [5]u32{ 8 << 20, 2 << 20, 4 << 20, 8 << 20, 64 << 20 };
pub const gpu_staging_bytes: usize = 48 * 1024 * 1024;
pub const Ring = struct { outer_radius_voxels: f32, cell_size_voxels: u32 };
pub const geometry_rings = [_]Ring{
    .{ .outer_radius_voxels = 128, .cell_size_voxels = 1 },
    .{ .outer_radius_voxels = 384, .cell_size_voxels = 1 },
    .{ .outer_radius_voxels = 768, .cell_size_voxels = 4 },
    .{ .outer_radius_voxels = 1536, .cell_size_voxels = 16 },
    .{ .outer_radius_voxels = 8192, .cell_size_voxels = 64 },
};
pub const lighting_rings = [_]Ring{
    .{ .outer_radius_voxels = 128, .cell_size_voxels = 1 },
    .{ .outer_radius_voxels = 384, .cell_size_voxels = 4 },
    .{ .outer_radius_voxels = 768, .cell_size_voxels = 16 },
    .{ .outer_radius_voxels = 1536, .cell_size_voxels = 64 },
    .{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 },
};
pub const Settings = struct {
    exact_hierarchy: bool = true,
    geometry_rings: []const Ring = &geometry_rings,
    lighting_rings: []const Ring = &lighting_rings,
    hysteresis_voxels: f32 = 16,
    transition_width_voxels: f32 = 32,
    interaction_radius_voxels: f32 = 256,

    pub fn validate(self: Settings) !void {
        try validateRings(self.geometry_rings);
        try validateRings(self.lighting_rings);
        for ([_]f32{ self.hysteresis_voxels, self.transition_width_voxels, self.interaction_radius_voxels }) |v|
            if (!std.math.isFinite(v) or v < 0) return error.InvalidDistance;
    }
};

pub fn validateRings(rings: []const Ring) !void {
    if (rings.len == 0 or rings.len > max_rings) return error.InvalidRingCount;
    var radius: f32 = 0;
    var size: u32 = 1;
    for (rings) |ring| {
        if (!std.math.isFinite(ring.outer_radius_voxels) or ring.outer_radius_voxels <= radius) return error.InvalidRadius;
        if (std.mem.indexOfScalar(u32, &cell_sizes, ring.cell_size_voxels) == null or ring.cell_size_voxels < size) return error.InvalidCellSize;
        radius = ring.outer_radius_voxels;
        size = ring.cell_size_voxels;
    }
}

pub fn aligned(value: i32, size: u32) i32 {
    const s: i32 = @intCast(size);
    return @divFloor(value, s) * s;
}

pub fn distanceToBounds(origin: [3]i32, side: u32, focus: [3]f32) f32 {
    var squared: f32 = 0;
    for ([_]usize{ 0, 2 }) |axis| {
        const lower: f32 = @floatFromInt(origin[axis]);
        const d = @max(@max(lower - focus[axis], focus[axis] - lower - @as(f32, @floatFromInt(side))), 0);
        squared += d * d;
    }
    return @sqrt(squared);
}

/// Last ring extends only to the loaded-world boundary; it never expands streaming.
pub fn requestedSize(rings: []const Ring, origin: [3]i32, side: u32, focus: [3]f32, guard: f32) u32 {
    const distance = distanceToBounds(origin, side, focus) - guard;
    for (rings) |ring| if (distance <= ring.outer_radius_voxels) return ring.cell_size_voxels;
    return rings[rings.len - 1].cell_size_voxels;
}

test "ring validation, all levels, negative alignment and conservative crossings" {
    try (Settings{}).validate();
    for (cell_sizes) |size| {
        try std.testing.expectEqual(-@as(i32, @intCast(size)), aligned(-1, size));
        try std.testing.expectEqual(@as(i32, 0), aligned(@intCast(size - 1), size));
    }
    try std.testing.expectError(error.InvalidRingCount, validateRings(&.{}));
    try std.testing.expectError(error.InvalidRadius, validateRings(&.{.{ .outer_radius_voxels = std.math.nan(f32), .cell_size_voxels = 1 }}));
    try std.testing.expectError(error.InvalidCellSize, validateRings(&.{.{ .outer_radius_voxels = 2, .cell_size_voxels = 2 }}));
    try std.testing.expectError(error.InvalidRadius, validateRings(&.{ .{ .outer_radius_voxels = 2, .cell_size_voxels = 1 }, .{ .outer_radius_voxels = 2, .cell_size_voxels = 4 } }));
    try std.testing.expectError(error.InvalidCellSize, validateRings(&.{ .{ .outer_radius_voxels = 2, .cell_size_voxels = 4 }, .{ .outer_radius_voxels = 3, .cell_size_voxels = 1 } }));
    const rings = [_]Ring{ .{ .outer_radius_voxels = 128, .cell_size_voxels = 1 }, .{ .outer_radius_voxels = 256, .cell_size_voxels = 16 } };
    try std.testing.expectEqual(@as(u32, 1), requestedSize(&rings, .{ 128, 999, 0 }, 64, .{ 0, 0, 0 }, 0));
    try std.testing.expectEqual(@as(u32, 16), requestedSize(&rings, .{ 192, 0, 0 }, 64, .{ 0, 999, 0 }, 0));
    try std.testing.expectEqual(@as(u32, 1), requestedSize(&rings, .{ -192, 0, 0 }, 64, .{ 0, 0, 0 }, 0));
}

/// Terrain uses every public hierarchy level; the finite final ring covers the
/// streamed window but never enlarges it.
pub const terrain_rings = [_]Ring{
    .{ .outer_radius_voxels = 384, .cell_size_voxels = 1 },
    .{ .outer_radius_voxels = 768, .cell_size_voxels = 4 },
    .{ .outer_radius_voxels = 1280, .cell_size_voxels = 16 },
    .{ .outer_radius_voxels = 1792, .cell_size_voxels = 64 },
    .{ .outer_radius_voxels = 8192, .cell_size_voxels = 256 },
};
pub const terrain_settings = Settings{ .geometry_rings = &terrain_rings };

/// Owns ring arrays so worker requests cannot reference mutable caller storage.
pub const ExactRequest = struct { center: [3]f32, radius: f32 };
pub const max_exact_requests = 4;
pub const Snapshot = struct {
    focus: [3]f32,
    exact_requests: [max_exact_requests]ExactRequest = undefined,
    exact_request_count: usize = 0,
    geometry: [max_rings]Ring = undefined,
    lighting: [max_rings]Ring = undefined,
    geometry_count: usize,
    lighting_count: usize,
    guard: f32,
    transition: f32,
    interaction: f32,
    exact: bool,
    revision: u64,

    pub fn settings(self: *const Snapshot) Settings {
        return .{ .geometry_rings = self.geometry[0..self.geometry_count], .lighting_rings = self.lighting[0..self.lighting_count], .hysteresis_voxels = self.guard, .transition_width_voxels = self.transition, .interaction_radius_voxels = self.interaction, .exact_hierarchy = self.exact };
    }

    /// Conservative transition retention plus a size-dependent balancing halo.
    /// The halo decreases by four on each split. A neighboring node two levels
    /// coarser must therefore split too, including across chunk boundaries.
    pub fn needsSplit(self: *const Snapshot, x: i32, z: i32, side: u32) bool {
        if (side == 1) return false;
        const distance = distanceToBounds(.{ x, 0, z }, side, self.focus) - self.guard;
        const halo: f32 = 2 * @as(f32, @floatFromInt(side));
        for (self.exact_requests[0..self.exact_request_count]) |request| {
            if (distanceToBounds(.{ x, 0, z }, side, request.center) <= request.radius + halo) return true;
        }
        if (distance <= self.interaction + 64 + halo) return true;
        for (self.geometry[0..self.geometry_count]) |ring| {
            if (ring.cell_size_voxels >= side) break;
            if (distance <= ring.outer_radius_voxels + self.transition + halo) return true;
        }
        return false;
    }
};

pub const FocusState = struct {
    anchor: ?[3]f32 = null,
    revision: u64 = 0,
    fingerprint: u64 = 0,

    pub fn resolve(self: *FocusState, settings: Settings, position: [3]f32) !Snapshot {
        return self.resolveWithRequests(settings, position, &.{});
    }

    /// Picking, collision or tools may request exact data through the same
    /// versioned scheduler without changing the lighting surface definition.
    pub fn resolveWithRequests(self: *FocusState, settings: Settings, position: [3]f32, exact_requests: []const ExactRequest) !Snapshot {
        try settings.validate();
        if (exact_requests.len > max_exact_requests) return error.TooManyExactRequests;
        for (exact_requests) |request| {
            if (!std.math.isFinite(request.radius) or request.radius < 0) return error.InvalidDistance;
            for (request.center) |v| if (!std.math.isFinite(v) or @abs(v) > 100000000) return error.InvalidPosition;
        }
        for (position) |v| if (!std.math.isFinite(v) or @abs(v) > 100000000) return error.InvalidPosition;
        const old = self.anchor orelse position;
        const dx = old[0] - position[0];
        const dz = old[2] - position[2];
        var hash = std.hash.Wyhash.init(0);
        for (exact_requests) |request| {
            hash.update(std.mem.asBytes(&request.center));
            hash.update(std.mem.asBytes(&request.radius));
        }
        for (settings.geometry_rings) |r| {
            hash.update(std.mem.asBytes(&r.outer_radius_voxels));
            hash.update(std.mem.asBytes(&r.cell_size_voxels));
        }
        for (settings.lighting_rings) |r| {
            hash.update(std.mem.asBytes(&r.outer_radius_voxels));
            hash.update(std.mem.asBytes(&r.cell_size_voxels));
        }
        hash.update(std.mem.asBytes(&settings.hysteresis_voxels));
        hash.update(std.mem.asBytes(&settings.transition_width_voxels));
        hash.update(std.mem.asBytes(&settings.interaction_radius_voxels));
        hash.update(std.mem.asBytes(&settings.exact_hierarchy));
        const fingerprint = hash.final();
        if (self.anchor == null or fingerprint != self.fingerprint or dx * dx + dz * dz > settings.hysteresis_voxels * settings.hysteresis_voxels) {
            self.anchor = position;
            self.revision +%= 1;
            self.fingerprint = fingerprint;
        }
        var result = Snapshot{ .focus = self.anchor.?, .geometry_count = settings.geometry_rings.len, .lighting_count = settings.lighting_rings.len, .guard = settings.hysteresis_voxels, .transition = settings.transition_width_voxels, .interaction = settings.interaction_radius_voxels, .exact = settings.exact_hierarchy, .revision = self.revision };
        result.exact_request_count = exact_requests.len;
        @memcpy(result.exact_requests[0..exact_requests.len], exact_requests);
        @memcpy(result.geometry[0..result.geometry_count], settings.geometry_rings);
        @memcpy(result.lighting[0..result.lighting_count], settings.lighting_rings);
        return result;
    }
};

test "shared focus is stable, owns rings and retains transition detail" {
    var state = FocusState{};
    const first = try state.resolve(terrain_settings, .{ 0, 0, 0 });
    const stable = try state.resolve(terrain_settings, .{ 16, 100, 0 });
    try std.testing.expectEqual(first.revision, stable.revision);
    try std.testing.expectEqual(first.focus, stable.focus);
    const moved = try state.resolve(terrain_settings, .{ 17, 0, 0 });
    try std.testing.expect(moved.revision > stable.revision);
    try std.testing.expect(first.needsSplit(420, 0, 4));
    try std.testing.expect(!first.needsSplit(3000, 3000, 256));
    try std.testing.expectError(error.InvalidPosition, state.resolve(terrain_settings, .{ std.math.nan(f32), 0, 0 }));
}

/// CPU counterpart of hierarchyWeight, used to check shader transition demand.
pub fn geometryWeight(snapshot: *const Snapshot, origin: [3]i32, side: u32) f32 {
    const distance = distanceToBounds(origin, side, snapshot.focus) - snapshot.guard;
    if (distance <= snapshot.interaction) return 0;
    var start: f32 = 0;
    for (snapshot.geometry[0..snapshot.geometry_count], 0..) |ring, i| {
        if (ring.cell_size_voxels >= side) {
            if (i == 0) return 1;
            if (snapshot.transition == 0) return if (distance > start) 1 else 0;
            const t = std.math.clamp((distance - start) / snapshot.transition, 0, 1);
            return t * t * (3 - 2 * t);
        }
        start = ring.outer_radius_voxels;
    }
    return 0;
}

test "exact consumer requests share versioning and conservative balancing" {
    var state = FocusState{};
    const initial = try state.resolve(terrain_settings, .{ 0, 0, 0 });
    try std.testing.expect(!initial.needsSplit(3072, 0, 4));
    const request = [_]ExactRequest{.{ .center = .{ 3072, 0, 0 }, .radius = 16 }};
    const exact = try state.resolveWithRequests(terrain_settings, .{ 0, 0, 0 }, &request);
    try std.testing.expect(exact.revision > initial.revision);
    try std.testing.expect(exact.needsSplit(3072, 0, 4));
    const same = try state.resolveWithRequests(terrain_settings, .{ 0, 0, 0 }, &request);
    try std.testing.expectEqual(exact.revision, same.revision);
}
