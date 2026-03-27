const std = @import("std");

pub fn Chunk(comptime T: type, comptime SX: usize, comptime SY: usize, comptime SZ: usize) type {
    const VOXEL_COUNT = SX * SY * SZ;
    const BIT_WORDS = (VOXEL_COUNT + 31) / 32;

    return struct {
        const Self = @This();

        voxels: []T,
        occupancy: []u32,
        solid_count: u32,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) !Self {
            const voxels = try allocator.alloc(T, VOXEL_COUNT);
            errdefer allocator.free(voxels);

            const occupancy = try allocator.alloc(u32, BIT_WORDS);
            errdefer allocator.free(occupancy);

            @memset(voxels, 0);
            @memset(occupancy, 0);

            return .{
                .voxels = voxels,
                .occupancy = occupancy,
                .solid_count = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.voxels);
            self.allocator.free(self.occupancy);
        }

        inline fn index(x: usize, y: usize, z: usize) usize {
            return x + y * SX + z * SX * SY;
        }

        inline fn bitPos(i: usize) struct { word: usize, bit: u5 } {
            return .{
                .word = i >> 5,
                .bit = @intCast(i & 31),
            };
        }

        pub inline fn inBounds(x: usize, y: usize, z: usize) bool {
            return x < SX and y < SY and z < SZ;
        }

        pub fn isSolid(self: *const Self, x: usize, y: usize, z: usize) bool {
            const i = index(x, y, z);
            const p = bitPos(i);
            return ((self.occupancy[p.word] >> p.bit) & 1) != 0;
        }

        pub fn setSolid(self: *Self, x: usize, y: usize, z: usize, solid: bool) void {
            const i = index(x, y, z);
            const p = bitPos(i);
            const mask: u32 = (@as(u32, 1) << p.bit);

            const was_solid = (self.occupancy[p.word] & mask) != 0;

            if (solid) {
                if (!was_solid) {
                    self.occupancy[p.word] |= mask;
                    self.solid_count += 1;
                }
            } else {
                if (was_solid) {
                    self.occupancy[p.word] &= ~mask;
                    self.solid_count -= 1;
                }
            }
        }

        pub fn fill(self: *Self, value: T) void {
            @memset(self.voxels, value);

            if (value == 0) {
                @memset(self.occupancy, 0);
                self.solid_count = 0;
            } else {
                @memset(self.occupancy, ~@as(u32, 0));
                self.solid_count = VOXEL_COUNT;

                // clear unused bits in last word if voxel count is not multiple of 64
                const used_bits = VOXEL_COUNT & 31;
                if (used_bits != 0) {
                    const last = self.occupancy.len - 1;
                    self.occupancy[last] = (@as(u32, 1) << @intCast(used_bits)) - 1;
                }
            }
        }

        pub fn setVoxel(self: *Self, x: usize, y: usize, z: usize, value: T) void {
            const i = index(x, y, z);
            self.voxels[i] = value;
            self.setSolid(x, y, z, value != 0);
        }

        pub fn getVoxel(self: *const Self, x: usize, y: usize, z: usize) T {
            return self.voxels[index(x, y, z)];
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.solid_count == 0;
        }

        pub fn rebuildBitmap(self: *Self) void {
            @memset(self.occupancy, 0);
            self.solid_count = 0;

            var i: usize = 0;
            while (i < VOXEL_COUNT) : (i += 1) {
                if (self.voxels[i] != 0) {
                    const p = bitPos(i);
                    self.occupancy[p.word] |= (@as(u32, 1) << p.bit);
                    self.solid_count += 1;
                }
            }
        }
    };
}
