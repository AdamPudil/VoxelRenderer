// src/chunk.zig

const std = @import("std");

const gl = @import("../graphics/gl.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

// Generic chunk that works for BOTH voxels and blocks

pub fn Chunk(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        size: usize,
        data: []T,

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            const count = size * size * size;

            return Self{
                .allocator = allocator,
                .size = size,
                .data = try allocator.alloc(T, count),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub inline fn index(self: *Self, x: usize, y: usize, z: usize) usize {
            return x + y * self.size + z * self.size * self.size;
        }

        pub fn set(self: *Self, x: usize, y: usize, z: usize, v: T) void {
            self.data[self.index(x, y, z)] = v;
        }

        pub fn get(self: *Self, x: usize, y: usize, z: usize) T {
            return self.data[self.index(x, y, z)];
        }

        pub fn fill(self: *Self, v: T) void {
            for (self.data) |*e| e.* = v;
        }

        pub fn forEach(self: *Self, func: fn (*T) void) void {
            for (self.data) |*e| func(e);
        }
    };
}
