const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const Block = @import("block.zig").Block;
const gl = @import("../graphics/gl.zig");

const noise = @import("generation/noises.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

pub fn BlockChunk(
    comptime T: type,
    comptime BLOCK_SIZE: usize,
    comptime CHUNK_SIZE: usize,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        chunk: Chunk(Block(T, BLOCK_SIZE)),

        pub fn init(allocator: std.mem.Allocator) !Self {
            const chunk = try Chunk(Block(T, BLOCK_SIZE)).init(allocator, CHUNK_SIZE);

            for (chunk.data) |*b| {
                b.* = try Block(T, BLOCK_SIZE).init(allocator);
            }

            return Self{
                .allocator = allocator,
                .chunk = chunk,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.chunk.data) |*b| b.deinit();
            self.chunk.deinit();
        }

        inline fn index(self: *Self, x: usize, y: usize, z: usize) usize {
            return self.chunk.index(x, y, z);
        }

        pub fn setVoxel(self: *Self, x: usize, y: usize, z: usize, v: T) void {
            const chunkWorld = CHUNK_SIZE * BLOCK_SIZE;

            const lx = x % chunkWorld;
            const ly = y % chunkWorld;
            const lz = z % chunkWorld;

            const bx = lx / BLOCK_SIZE;
            const by = ly / BLOCK_SIZE;
            const bz = lz / BLOCK_SIZE;

            const vx = lx % BLOCK_SIZE;
            const vy = ly % BLOCK_SIZE;
            const vz = lz % BLOCK_SIZE;

            self.chunk.data[self.chunk.index(bx, by, bz)].set(vx, vy, vz, v);
            self.chunk.data[self.chunk.index(bx, by, bz)].setSolid(vx, vy, vz, 1);
        }

        pub fn upload(self: *Self, tex: *c_uint) void {
            const worldSize = BLOCK_SIZE * CHUNK_SIZE;
            const count = worldSize * worldSize * worldSize;

            var buffer = self.allocator.alloc(u16, count) catch unreachable;
            defer self.allocator.free(buffer);

            // flatten all chunks into one buffer
            for (0..worldSize) |z| {
                for (0..worldSize) |y| {
                    for (0..worldSize) |x| {
                        const idx = x + y * worldSize + z * worldSize * worldSize;

                        const chunkWorld = BLOCK_SIZE * CHUNK_SIZE;

                        const lx = x % chunkWorld;
                        const ly = y % chunkWorld;
                        const lz = z % chunkWorld;

                        const bx = lx / BLOCK_SIZE;
                        const by = ly / BLOCK_SIZE;
                        const bz = lz / BLOCK_SIZE;

                        const vx = lx % BLOCK_SIZE;
                        const vy = ly % BLOCK_SIZE;
                        const vz = lz % BLOCK_SIZE;

                        var block = self.chunk.data[self.chunk.index(bx, by, bz)];
                        buffer[idx] = block.get(vx, vy, vz);
                    }
                }
            }

            c.glGenTextures(1, tex);

            gl.ActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_3D, tex.*);

            gl.TexImage3D(
                c.GL_TEXTURE_3D,
                0,
                c.GL_R16UI,
                @intCast(worldSize),
                @intCast(worldSize),
                @intCast(worldSize),
                0,
                c.GL_RED_INTEGER,
                c.GL_UNSIGNED_SHORT,
                buffer.ptr,
            );

            c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        }

        pub fn generate(self: *Self) void {
            const worldSize = BLOCK_SIZE * CHUNK_SIZE;

            for (0..worldSize) |z| {
                for (0..worldSize) |x| {
                    const nx = @as(f32, @floatFromInt(x)) * 0.02;
                    const nz = @as(f32, @floatFromInt(z)) * 0.02;

                    var h: f32 = 2;
                    var amp: f32 = 0.9;
                    var freq: f32 = 0.3;

                    for (0..3) |_| {
                        h += noise.noise2D(nx * freq, nz * freq) * amp;
                        amp *= 0.5;
                        freq *= 2.0;
                    }

                    const height = @as(i32, @intFromFloat(h * 12.0)) + 8;

                    for (0..worldSize) |y| {
                        if (@as(i32, @intCast(y)) <= height) {
                            self.setVoxel(x, y, z, 1);
                        } else {
                            self.setVoxel(x, y, z, 0);
                        }
                    }
                }
            }
        }

        pub fn render(self: *Self, tex: c_uint) void {
            _ = self;

            gl.ActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_3D, tex);
        }
    };
}
