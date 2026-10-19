const std = @import("std");
const positions = @import("../position.zig");

pub const chunks_per_side = 16;
pub const voxels_per_chunk = 256;
pub const voxels_per_block = 16;
pub const side = chunks_per_side * voxels_per_chunk;

/// Horizontal X/Z coordinates. In existing Position2 types, y represents Z.
pub const Point = struct { x: i64, z: i64 };

pub const GenerationSuperchunk = struct {
    position: positions.SuperchunkPosition2,
    seed: u64,

    pub fn chunkOrigin(self: @This()) Point {
        return .{ .x = self.position.x.coordinate() * chunks_per_side, .z = self.position.y.coordinate() * chunks_per_side };
    }

    pub fn voxelOrigin(self: @This()) Point {
        const p = self.chunkOrigin();
        return .{ .x = p.x * voxels_per_chunk, .z = p.z * voxels_per_chunk };
    }

    /// Leave room for coarse parent samples outside the public sample domain.
    pub fn validate(self: @This()) !void {
        const p = self.voxelOrigin();
        const margin = side * 4;
        if (p.x < std.math.minInt(i64) + margin or p.x > std.math.maxInt(i64) - margin or
            p.z < std.math.minInt(i64) + margin or p.z > std.math.maxInt(i64) - margin)
            return error.CoordinateOverflow;
    }
};

pub fn validateResolution(resolution: u32) !void {
    if (resolution == 0 or resolution > side or !std.math.isPowerOfTwo(resolution))
        return error.InvalidResolution;
}

pub fn levelForResolution(resolution: u32) !usize {
    try validateResolution(resolution);
    return 12 - @as(usize, @intCast(@ctz(resolution)));
}

/// An owned, cropped result: row-major samples, no neighboring support cells.
/// Each sample is the lower X/Z corner of a resolution-sized output cell.
pub const Result = struct {
    allocator: std.mem.Allocator,
    origin: Point,
    resolution: u32,
    width: usize,
    height: usize,
    values: []i32,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn at(self: @This(), x: usize, z: usize) i32 {
        std.debug.assert(x < self.width and z < self.height);
        return self.values[z * self.width + x];
    }

    pub fn writePgm(self: @This(), writer: anytype, min: i32, max: i32) !void {
        try writePgmValues(writer, self.values, self.width, min, max);
    }
};

/// Explicit range keeps neighboring exports on the same grayscale scale.
pub fn writePgmValues(writer: anytype, values: []const i32, width: usize, min: i32, max: i32) !void {
    std.debug.assert(min < max and width > 0 and values.len % width == 0);
    try writer.print("P5\n{d} {d}\n255\n", .{ width, values.len / width });
    var buffer: [4096]u8 = undefined;
    var offset: usize = 0;
    while (offset < values.len) {
        const count = @min(buffer.len, values.len - offset);
        for (values[offset..][0..count], buffer[0..count]) |v, *pixel| {
            const clamped = std.math.clamp(v, min, max);
            pixel.* = @intCast(@divTrunc((@as(i64, clamped) - min) * 255, @as(i64, max) - min));
        }
        try writer.writeAll(buffer[0..count]);
        offset += count;
    }
}

/// Half-open rectangle, interpreted in voxel or chunk units by the caller.
pub const Area = struct {
    x: u32,
    z: u32,
    width: u32,
    height: u32,

    pub fn validate(self: @This(), limit: u32) !void {
        if (self.x >= limit or self.z >= limit or self.width == 0 or self.height == 0)
            return error.InvalidArea;
        if (self.width > limit - self.x or self.height > limit - self.z)
            return error.InvalidArea;
    }
};

/// Local X/Z circle. Refinement includes cells intersecting its boundary, plus
/// any coarser parent samples required by the noise algorithm.
pub const Circle = struct {
    x: u32,
    z: u32,
    radius: u32,

    pub fn validate(self: @This()) !void {
        if (self.x > side or self.z > side or self.radius > side) return error.InvalidCircle;
    }

    pub fn contains(self: @This(), x: u32, z: u32) bool {
        const dx = @as(i64, x) - self.x;
        const dz = @as(i64, z) - self.z;
        return dx * dx + dz * dz <= @as(i64, self.radius) * self.radius;
    }

    /// Select the entire parent cell by its geometric center. All children
    /// receive the same decision, producing a symmetric stepped outline.
    pub fn containsParentCell(self: @This(), x: u32, z: u32, parent_size: u32) bool {
        return self.contains(x / parent_size * parent_size + parent_size / 2, z / parent_size * parent_size + parent_size / 2);
    }

    pub fn intersectsCell(self: @This(), x: u32, z: u32, resolution: u32) bool {
        // Cell bounds are inclusive sample positions, e.g. 0..255 for a chunk.
        const nearest_x = std.math.clamp(self.x, x, x + resolution - 1);
        const nearest_z = std.math.clamp(self.z, z, z + resolution - 1);
        return self.contains(nearest_x, nearest_z);
    }
};

/// The mixed-detail preview: diameters 12 chunks at block spacing, 6 at voxel
/// spacing, centered in a single 16x16-chunk superchunk.
pub const CircularLod = struct {
    center_x: u32 = side / 2,
    center_z: u32 = side / 2,
    block_radius: u32 = 6 * voxels_per_chunk,
    voxel_radius: u32 = 3 * voxels_per_chunk,

    pub fn blockCircle(self: @This()) Circle {
        return .{ .x = self.center_x, .z = self.center_z, .radius = self.block_radius };
    }

    pub fn voxelCircle(self: @This()) Circle {
        return .{ .x = self.center_x, .z = self.center_z, .radius = self.voxel_radius };
    }

    pub fn validate(self: @This()) !void {
        try self.blockCircle().validate();
        try self.voxelCircle().validate();
        if (self.voxel_radius > self.block_radius) return error.InvalidCircle;
    }

    pub fn resolutionAt(self: @This(), x: u32, z: u32) u32 {
        if (!self.blockCircle().containsParentCell(x, z, voxels_per_chunk)) return voxels_per_chunk;
        if (self.voxelCircle().containsParentCell(x, z, voxels_per_block)) return 1;
        return voxels_per_block;
    }
};
