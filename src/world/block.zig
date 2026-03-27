const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;

pub fn Block(comptime T: type, comptime SIZE: usize) type {
    return struct {
        const Self = @This();

        voxels: Chunk(T, 16, 16, 16),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .voxels = try Chunk(T, 16, 16, 16).init(allocator, SIZE),
            };
        }

        pub fn deinit(self: *Self) void {
            self.voxels.deinit();
        }

        pub fn set(self: *Self, x: usize, y: usize, z: usize, v: T) void {
            self.voxels.set(x, y, z, v);
        }

        pub fn get(self: *Self, x: usize, y: usize, z: usize) T {
            return self.voxels.get(x, y, z);
        }
    };
}
