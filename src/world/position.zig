const std = @import("std");

const CHUNK_TYPE = i56;
const BLOCK_TYPE = u4;
const VOXEL_TYPE = u4;

pub const ChunkPosition1 = packed struct {
    chunk: CHUNK_TYPE,

    /// Signed global coordinate in chunk units.
    pub fn coordinate(self: @This()) i64 {
        return self.chunk;
    }

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash1D(mixSeed(seed, 1), self.coordinate());
    }
};

pub const BlockPosition1 = packed struct {
    chunk: CHUNK_TYPE,
    block: BLOCK_TYPE,

    /// Signed global coordinate in block units.
    pub fn coordinate(self: @This()) i64 {
        return @as(i64, self.chunk) * 16 + self.block;
    }

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash1D(mixSeed(seed, 2), self.coordinate());
    }
};

pub const VoxelPosition1 = packed struct {
    chunk: CHUNK_TYPE,
    block: BLOCK_TYPE,
    voxel: VOXEL_TYPE,

    /// Signed global coordinate in voxel units.
    pub fn coordinate(self: @This()) i64 {
        return @as(i64, self.chunk) * 256 + @as(i64, self.block) * 16 + self.voxel;
    }

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash1D(mixSeed(seed, 3), self.coordinate());
    }
};

pub const ChunkPosition2 = packed struct {
    x: ChunkPosition1,
    y: ChunkPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash2D(mixSeed(seed, 1), self.x.coordinate(), self.y.coordinate());
    }
};

pub const ChunkPosition3 = packed struct {
    x: ChunkPosition1,
    y: ChunkPosition1,
    z: ChunkPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash3D(mixSeed(seed, 1), self.x.coordinate(), self.y.coordinate(), self.z.coordinate());
    }
};

pub const BlockPosition2 = packed struct {
    x: BlockPosition1,
    y: BlockPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash2D(mixSeed(seed, 2), self.x.coordinate(), self.y.coordinate());
    }
};

pub const BlockPosition3 = packed struct {
    x: BlockPosition1,
    y: BlockPosition1,
    z: BlockPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash3D(mixSeed(seed, 2), self.x.coordinate(), self.y.coordinate(), self.z.coordinate());
    }
};

pub const VoxelPosition2 = packed struct {
    x: VoxelPosition1,
    y: VoxelPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash2D(mixSeed(seed, 3), self.x.coordinate(), self.y.coordinate());
    }
};

pub const VoxelPosition3 = packed struct {
    x: VoxelPosition1,
    y: VoxelPosition1,
    z: VoxelPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash3D(mixSeed(seed, 3), self.x.coordinate(), self.y.coordinate(), self.z.coordinate());
    }
};

pub const SuperchunkPosition1 = packed struct {
    superchunk: i52,

    pub fn coordinate(self: @This()) i64 {
        return self.superchunk;
    }

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash1D(mixSeed(seed, 4), self.coordinate());
    }
};

pub const SuperchunkPosition2 = packed struct {
    x: SuperchunkPosition1,
    y: SuperchunkPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash2D(mixSeed(seed, 4), self.x.coordinate(), self.y.coordinate());
    }
};

pub const SuperchunkPosition3 = packed struct {
    x: SuperchunkPosition1,
    y: SuperchunkPosition1,
    z: SuperchunkPosition1,

    pub fn hash(self: @This(), seed: u64) u64 {
        return hash3D(mixSeed(seed, 4), self.x.coordinate(), self.y.coordinate(), self.z.coordinate());
    }
};

// Integer operations deliberately wrap. Never hash packed storage or padding.
fn avalanche(value: u64) u64 {
    var x = value;
    x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
    x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

pub fn mixSeed(seed: u64, value: u64) u64 {
    return avalanche(seed ^ avalanche(value +% 0x9e3779b97f4a7c15));
}

pub fn hash1D(seed: u64, x: i64) u64 {
    return mixSeed(mixSeed(seed, 1), @bitCast(x));
}

/// The second coordinate is Z when hashing horizontal terrain positions.
pub fn hash2D(seed: u64, x: i64, z: i64) u64 {
    return mixSeed(mixSeed(mixSeed(seed, 2), @bitCast(x)), @bitCast(z));
}

pub fn hash3D(seed: u64, x: i64, y: i64, z: i64) u64 {
    return mixSeed(mixSeed(mixSeed(mixSeed(seed, 3), @bitCast(x)), @bitCast(y)), @bitCast(z));
}

/// Dispatches to each position's numeric-coordinate hash, including its unit domain.
pub fn hashPosition(seed: u64, position: anytype) u64 {
    return position.hash(seed);
}

pub fn hashToU8(value: u64) u8 {
    return @truncate(value);
}

pub fn hashToU16(value: u64) u16 {
    return @truncate(value);
}

pub fn hashToU32(value: u64) u32 {
    return @truncate(value);
}

/// Inclusive [0, 1], using the 24 high bits representable in f32.
pub fn hashToUnitF32(value: u64) f32 {
    return @as(f32, @floatFromInt(value >> 40)) / 16777215.0;
}

pub fn hashToSignedF32(value: u64) f32 {
    return hashToUnitF32(value) * 2 - 1;
}

/// Inclusive range. Modulo reduction has a small bias for non-power-of-two ranges.
pub fn hashToRangeI64(value: u64, min: i64, max: i64) i64 {
    std.debug.assert(min <= max);
    const width: u128 = @intCast(@as(i128, max) - min + 1);
    return @intCast(@as(i128, min) + @as(i128, @intCast(@as(u128, value) % width)));
}

pub fn hashToRangeI32(value: u64, min: i32, max: i32) i32 {
    return @intCast(hashToRangeI64(value, min, max));
}

pub fn hashToSignedRange(value: u64, amplitude: i32) i32 {
    std.debug.assert(amplitude >= 0);
    return hashToRangeI32(value, -amplitude, amplitude);
}

test "position hash dispatch covers every unit and dimension" {
    inline for (.{ ChunkPosition1, BlockPosition1, VoxelPosition1, SuperchunkPosition1, ChunkPosition2, BlockPosition2, VoxelPosition2, SuperchunkPosition2, ChunkPosition3, BlockPosition3, VoxelPosition3, SuperchunkPosition3 }) |T| {
        const p: T = std.mem.zeroes(T);
        try std.testing.expectEqual(p.hash(123), hashPosition(123, p));
        try std.testing.expect(p.hash(123) != p.hash(124));
    }
    const a: VoxelPosition1 = .{ .chunk = -1, .block = 15, .voxel = 15 };
    try std.testing.expectEqual(@as(i64, -1), a.coordinate());
    try std.testing.expectEqual(hash1D(mixSeed(123, 3), -1), a.hash(123));
    const b: BlockPosition1 = .{ .chunk = -1, .block = 15 };
    try std.testing.expectEqual(@as(i64, -1), b.coordinate());
    try std.testing.expect(a.hash(123) != b.hash(123));
    const min: VoxelPosition1 = .{ .chunk = std.math.minInt(i56), .block = 0, .voxel = 0 };
    const max: VoxelPosition1 = .{ .chunk = std.math.maxInt(i56), .block = 15, .voxel = 15 };
    try std.testing.expectEqual(std.math.minInt(i64), min.coordinate());
    try std.testing.expectEqual(std.math.maxInt(i64), max.coordinate());
}

test "hashes preserve sign dimensions order and nearby-coordinate distribution" {
    try std.testing.expect(hash2D(7, -3, 5) != hash2D(7, 5, -3));
    try std.testing.expect(hash1D(7, -3) != hash1D(7, 3));
    try std.testing.expect(hash1D(7, -3) != hash2D(7, -3, 0));
    try std.testing.expect(hash2D(7, -3, 5) != hash3D(7, -3, 5, 0));
    var hashes = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer hashes.deinit();
    var changed_bits: usize = 0;
    var buckets = [_]usize{0} ** 16;
    for (0..4096) |i| {
        const x = @as(i64, @intCast(i)) - 2048;
        const h = hash2D(42, x, -27);
        try std.testing.expectEqual(h, hash2D(42, x, -27));
        try std.testing.expect(!(try hashes.getOrPut(h)).found_existing);
        changed_bits += @popCount(h ^ hash2D(42, x + 1, -27));
        buckets[hashToU8(h) & 15] += 1;
    }
    try std.testing.expect(changed_bits > 4096 * 28 and changed_bits < 4096 * 36);
    for (buckets) |count| try std.testing.expect(count > 180 and count < 340);
}

test "hash output helpers include endpoints and full signed ranges" {
    const max = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u8, 255), hashToU8(max));
    try std.testing.expectEqual(@as(u16, 65535), hashToU16(max));
    try std.testing.expectEqual(std.math.maxInt(u32), hashToU32(max));
    try std.testing.expectEqual(@as(f32, 0), hashToUnitF32(0));
    try std.testing.expectEqual(@as(f32, 1), hashToUnitF32(max));
    try std.testing.expectEqual(@as(f32, -1), hashToSignedF32(0));
    try std.testing.expectEqual(@as(f32, 1), hashToSignedF32(max));
    try std.testing.expectEqual(std.math.minInt(i64), hashToRangeI64(0, std.math.minInt(i64), std.math.maxInt(i64)));
    try std.testing.expectEqual(std.math.maxInt(i64), hashToRangeI64(max, std.math.minInt(i64), std.math.maxInt(i64)));
    try std.testing.expectEqual(std.math.maxInt(i32), hashToRangeI32(0xffffffff, std.math.minInt(i32), std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i64, -5), hashToRangeI64(max, -5, -5));
    for (0..1000) |i| {
        const h = hash1D(42, @intCast(i));
        const v = hashToSignedRange(h, 73);
        try std.testing.expect(v >= -73 and v <= 73);
    }
}
