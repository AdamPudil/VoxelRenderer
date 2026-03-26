const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const gl = @import("../graphics/gl.zig");
const noise = @import("generation/noises.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

pub fn World(
    comptime T: type,
    comptime CHUNK_SIZE: usize,
    comptime STREAM_CHUNKS_XZ: usize,
    comptime STREAM_CHUNKS_Y: usize,
) type {
    return struct {
        const Self = @This();

        const ChunkKey = struct {
            x: i32,
            y: i32,
            z: i32,
        };

        allocator: std.mem.Allocator,
        chunks: std.AutoHashMap(ChunkKey, Chunk(T)),

        tex: c_uint = 0,
        gpu_dirty: bool = true,

        // voxel-space origin of currently uploaded region
        gpu_region_origin: [3]i32 = .{ 0, 0, 0 },

        // chunk-space origin of currently uploaded region
        region_chunk_origin: [3]i32 = .{ 0, 0, 0 },

        streamed_voxel_size: [3]usize = .{
            CHUNK_SIZE * STREAM_CHUNKS_XZ,
            CHUNK_SIZE * STREAM_CHUNKS_Y,
            CHUNK_SIZE * STREAM_CHUNKS_XZ,
        },

        const chunk_size_i32: i32 = @intCast(CHUNK_SIZE);
        const stream_chunks_xz_i32: i32 = @intCast(STREAM_CHUNKS_XZ);
        const stream_chunks_y_i32: i32 = @intCast(STREAM_CHUNKS_Y);

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .chunks = std.AutoHashMap(ChunkKey, Chunk(T)).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.chunks.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.chunks.deinit();

            if (self.tex != 0) {
                c.glDeleteTextures(1, &self.tex);
            }
        }

        inline fn divFloor(a: i32, b: i32) i32 {
            return @divFloor(a, b);
        }

        inline fn modFloor(a: i32, b: i32) i32 {
            return @mod(a, b);
        }

        pub fn worldToChunkCoord(v: i32) i32 {
            return divFloor(v, chunk_size_i32);
        }

        pub fn worldToLocalCoord(v: i32) usize {
            return @intCast(modFloor(v, chunk_size_i32));
        }

        fn terrainHeight(wx: i32, wz: i32) i32 {
            const nx = @as(f32, @floatFromInt(wx)) * 0.02;
            const nz = @as(f32, @floatFromInt(wz)) * 0.02;

            var h: f32 = 2;
            var amp: f32 = 0.9;
            var freq: f32 = 0.3;

            for (0..3) |_| {
                h += noise.noise2D(nx * freq, nz * freq) * amp;
                amp *= 0.5;
                freq *= 2.0;
            }

            return @as(i32, @intFromFloat(h * 12.0)) + 8;
        }

        fn chunkNeededByHeightMap(_: *Self, cx: i32, cy: i32, cz: i32) bool {
            const base_x = cx * chunk_size_i32;
            const base_y = cy * chunk_size_i32;
            const base_z = cz * chunk_size_i32;

            const top_y = base_y + chunk_size_i32 - 1;
            if (top_y < 0) return false;

            var max_height = terrainHeight(base_x, base_z);
            const half: i32 = @intCast(CHUNK_SIZE / 2);

            const sample_points = [_][2]i32{
                .{ base_x, base_z },
                .{ base_x + chunk_size_i32 - 1, base_z },
                .{ base_x, base_z + chunk_size_i32 - 1 },
                .{ base_x + chunk_size_i32 - 1, base_z + chunk_size_i32 - 1 },
                .{ base_x + half, base_z + half },
            };

            for (sample_points) |p| {
                max_height = @max(max_height, terrainHeight(p[0], p[1]));
            }

            return base_y <= max_height;
        }

        fn generateChunk(self: *Self, cx: i32, cy: i32, cz: i32) !Chunk(T) {
            var chunk = try Chunk(T).init(self.allocator, CHUNK_SIZE);
            chunk.fill(@as(T, 0));

            const base_x = cx * chunk_size_i32;
            const base_y = cy * chunk_size_i32;
            const base_z = cz * chunk_size_i32;

            for (0..CHUNK_SIZE) |lz| {
                for (0..CHUNK_SIZE) |lx| {
                    const wx = base_x + @as(i32, @intCast(lx));
                    const wz = base_z + @as(i32, @intCast(lz));
                    const height = terrainHeight(wx, wz);

                    for (0..CHUNK_SIZE) |ly| {
                        const wy = base_y + @as(i32, @intCast(ly));
                        if (wy >= 0 and wy <= height) {
                            chunk.set(lx, ly, lz, @as(T, 1));
                        }
                    }
                }
            }

            return chunk;
        }

        fn getOrCreateChunk(self: *Self, cx: i32, cy: i32, cz: i32) !struct { ptr: *Chunk(T), created: bool } {
            const key = ChunkKey{ .x = cx, .y = cy, .z = cz };
            const gop = try self.chunks.getOrPut(key);

            if (!gop.found_existing) {
                gop.value_ptr.* = try self.generateChunk(cx, cy, cz);
                self.gpu_dirty = true;
                return .{ .ptr = gop.value_ptr, .created = true };
            }

            return .{ .ptr = gop.value_ptr, .created = false };
        }

        pub fn setVoxel(self: *Self, x: i32, y: i32, z: i32, v: T) !void {
            const cx = worldToChunkCoord(x);
            const cy = worldToChunkCoord(y);
            const cz = worldToChunkCoord(z);

            const lx = worldToLocalCoord(x);
            const ly = worldToLocalCoord(y);
            const lz = worldToLocalCoord(z);

            const res = try self.getOrCreateChunk(cx, cy, cz);
            res.ptr.set(lx, ly, lz, v);
            self.gpu_dirty = true;
        }

        pub fn getVoxel(self: *Self, x: i32, y: i32, z: i32) T {
            const cx = worldToChunkCoord(x);
            const cy = worldToChunkCoord(y);
            const cz = worldToChunkCoord(z);

            const lx = worldToLocalCoord(x);
            const ly = worldToLocalCoord(y);
            const lz = worldToLocalCoord(z);

            if (self.chunks.getPtr(.{ .x = cx, .y = cy, .z = cz })) |chunk| {
                return chunk.get(lx, ly, lz);
            }
            return @as(T, 0);
        }

        fn computeRegionChunkOrigin(cam_pos: [3]f32) [3]i32 {
            const cam_chunk_x = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[0]))));
            const cam_chunk_y = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[1]))));
            const cam_chunk_z = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[2]))));

            return .{
                cam_chunk_x - @divFloor(stream_chunks_xz_i32, 2),
                cam_chunk_y - @divFloor(stream_chunks_y_i32, 2),
                cam_chunk_z - @divFloor(stream_chunks_xz_i32, 2),
            };
        }

        fn ensureRegionChunks(self: *Self, region_origin: [3]i32) !bool {
            var created_any = false;

            for (0..STREAM_CHUNKS_XZ) |dz| {
                for (0..STREAM_CHUNKS_Y) |dy| {
                    for (0..STREAM_CHUNKS_XZ) |dx| {
                        const cx = region_origin[0] + @as(i32, @intCast(dx));
                        const cy = region_origin[1] + @as(i32, @intCast(dy));
                        const cz = region_origin[2] + @as(i32, @intCast(dz));

                        if (!self.chunkNeededByHeightMap(cx, cy, cz)) continue;

                        const res = try self.getOrCreateChunk(cx, cy, cz);
                        if (res.created) created_any = true;
                    }
                }
            }

            return created_any;
        }

        fn uploadFullRegion(self: *Self, region_origin: [3]i32) !void {
            const size_x = self.streamed_voxel_size[0];
            const size_y = self.streamed_voxel_size[1];
            const size_z = self.streamed_voxel_size[2];
            const count = size_x * size_y * size_z;

            var buffer = try self.allocator.alloc(T, count);
            defer self.allocator.free(buffer);
            @memset(buffer, @as(T, 0));

            for (0..STREAM_CHUNKS_XZ) |chunk_z| {
                for (0..STREAM_CHUNKS_Y) |chunk_y| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_x| {
                        const cx = region_origin[0] + @as(i32, @intCast(chunk_x));
                        const cy = region_origin[1] + @as(i32, @intCast(chunk_y));
                        const cz = region_origin[2] + @as(i32, @intCast(chunk_z));

                        const maybe_chunk = self.chunks.getPtr(.{ .x = cx, .y = cy, .z = cz });
                        if (maybe_chunk == null) continue;

                        const chunk = maybe_chunk.?;

                        for (0..CHUNK_SIZE) |lz| {
                            for (0..CHUNK_SIZE) |ly| {
                                for (0..CHUNK_SIZE) |lx| {
                                    const gx = chunk_x * CHUNK_SIZE + lx;
                                    const gy = chunk_y * CHUNK_SIZE + ly;
                                    const gz = chunk_z * CHUNK_SIZE + lz;
                                    const dst = gx + gy * size_x + gz * size_x * size_y;
                                    buffer[dst] = chunk.get(lx, ly, lz);
                                }
                            }
                        }
                    }
                }
            }

            if (self.tex == 0) {
                c.glGenTextures(1, &self.tex);
                gl.ActiveTexture(c.GL_TEXTURE0);
                c.glBindTexture(c.GL_TEXTURE_3D, self.tex);
                c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
                c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            }

            gl.ActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_3D, self.tex);

            gl.TexImage3D(
                c.GL_TEXTURE_3D,
                0,
                c.GL_R16UI,
                @intCast(size_x),
                @intCast(size_y),
                @intCast(size_z),
                0,
                c.GL_RED_INTEGER,
                c.GL_UNSIGNED_SHORT,
                buffer.ptr,
            );

            self.region_chunk_origin = region_origin;
            self.gpu_region_origin = .{
                region_origin[0] * chunk_size_i32,
                region_origin[1] * chunk_size_i32,
                region_origin[2] * chunk_size_i32,
            };
            self.gpu_dirty = false;
        }

        fn uploadChunkToTexture(self: *Self, chunk_x: usize, chunk_y: usize, chunk_z: usize, world_cx: i32, world_cy: i32, world_cz: i32) !void {
            const maybe_chunk = self.chunks.getPtr(.{ .x = world_cx, .y = world_cy, .z = world_cz });

            const count = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
            var buffer = try self.allocator.alloc(T, count);
            defer self.allocator.free(buffer);
            @memset(buffer, @as(T, 0));

            if (maybe_chunk) |chunk| {
                for (0..CHUNK_SIZE) |lz| {
                    for (0..CHUNK_SIZE) |ly| {
                        for (0..CHUNK_SIZE) |lx| {
                            const idx = lx + ly * CHUNK_SIZE + lz * CHUNK_SIZE * CHUNK_SIZE;
                            buffer[idx] = chunk.get(lx, ly, lz);
                        }
                    }
                }
            }

            gl.ActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_3D, self.tex);

            gl.TexSubImage3D(
                c.GL_TEXTURE_3D,
                0,
                @intCast(chunk_x * CHUNK_SIZE),
                @intCast(chunk_y * CHUNK_SIZE),
                @intCast(chunk_z * CHUNK_SIZE),
                @intCast(CHUNK_SIZE),
                @intCast(CHUNK_SIZE),
                @intCast(CHUNK_SIZE),
                c.GL_RED_INTEGER,
                c.GL_UNSIGNED_SHORT,
                buffer.ptr,
            );
        }

        fn uploadEdgeForMove(self: *Self, old_origin: [3]i32, new_origin: [3]i32) !void {
            const dx = new_origin[0] - old_origin[0];
            const dy = new_origin[1] - old_origin[1];
            const dz = new_origin[2] - old_origin[2];

            const moved_axes =
                @as(i32, if (dx != 0) 1 else 0) +
                @as(i32, if (dy != 0) 1 else 0) +
                @as(i32, if (dz != 0) 1 else 0);

            if (moved_axes != 1) {
                try self.uploadFullRegion(new_origin);
                return;
            }

            if ((dx != 0 and @abs(dx) != 1) or (dy != 0 and @abs(dy) != 1) or (dz != 0 and @abs(dz) != 1)) {
                try self.uploadFullRegion(new_origin);
                return;
            }

            // This version keeps the old texture layout and overwrites the newly visible edge.
            // It is not a full ring-buffer yet, so it is only safe as a "lighter step" when you
            // also treat the texture logically as the new region after edge upload.
            // If you see spatial mismatch while moving, switch this fallback to full rebuild.

            if (dx == 1) {
                const chunk_x = STREAM_CHUNKS_XZ - 1;
                const world_cx = new_origin[0] + @as(i32, @intCast(chunk_x));
                for (0..STREAM_CHUNKS_Y) |chunk_y| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_z| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            world_cx,
                            new_origin[1] + @as(i32, @intCast(chunk_y)),
                            new_origin[2] + @as(i32, @intCast(chunk_z)),
                        );
                    }
                }
            } else if (dx == -1) {
                const chunk_x: usize = 0;
                const world_cx = new_origin[0];
                for (0..STREAM_CHUNKS_Y) |chunk_y| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_z| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            world_cx,
                            new_origin[1] + @as(i32, @intCast(chunk_y)),
                            new_origin[2] + @as(i32, @intCast(chunk_z)),
                        );
                    }
                }
            } else if (dz == 1) {
                const chunk_z = STREAM_CHUNKS_XZ - 1;
                const world_cz = new_origin[2] + @as(i32, @intCast(chunk_z));
                for (0..STREAM_CHUNKS_Y) |chunk_y| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_x| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            new_origin[0] + @as(i32, @intCast(chunk_x)),
                            new_origin[1] + @as(i32, @intCast(chunk_y)),
                            world_cz,
                        );
                    }
                }
            } else if (dz == -1) {
                const chunk_z: usize = 0;
                const world_cz = new_origin[2];
                for (0..STREAM_CHUNKS_Y) |chunk_y| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_x| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            new_origin[0] + @as(i32, @intCast(chunk_x)),
                            new_origin[1] + @as(i32, @intCast(chunk_y)),
                            world_cz,
                        );
                    }
                }
            } else if (dy == 1) {
                const chunk_y = STREAM_CHUNKS_Y - 1;
                const world_cy = new_origin[1] + @as(i32, @intCast(chunk_y));
                for (0..STREAM_CHUNKS_XZ) |chunk_z| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_x| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            new_origin[0] + @as(i32, @intCast(chunk_x)),
                            world_cy,
                            new_origin[2] + @as(i32, @intCast(chunk_z)),
                        );
                    }
                }
            } else if (dy == -1) {
                const chunk_y: usize = 0;
                const world_cy = new_origin[1];
                for (0..STREAM_CHUNKS_XZ) |chunk_z| {
                    for (0..STREAM_CHUNKS_XZ) |chunk_x| {
                        try self.uploadChunkToTexture(
                            chunk_x,
                            chunk_y,
                            chunk_z,
                            new_origin[0] + @as(i32, @intCast(chunk_x)),
                            world_cy,
                            new_origin[2] + @as(i32, @intCast(chunk_z)),
                        );
                    }
                }
            }

            self.region_chunk_origin = new_origin;
            self.gpu_region_origin = .{
                new_origin[0] * chunk_size_i32,
                new_origin[1] * chunk_size_i32,
                new_origin[2] * chunk_size_i32,
            };
            self.gpu_dirty = false;
        }

        pub fn generate(self: *Self, cam_pos: [3]f32) !bool {
            const region_origin = computeRegionChunkOrigin(cam_pos);
            return try self.ensureRegionChunks(region_origin);
        }

        pub fn render(self: *Self, cam_pos: [3]f32) !c_uint {
            const new_origin = computeRegionChunkOrigin(cam_pos);
            const created_any = try self.ensureRegionChunks(new_origin);

            if (self.tex == 0) {
                try self.uploadFullRegion(new_origin);
            } else if (self.gpu_dirty) {
                try self.uploadFullRegion(new_origin);
            } else if (!std.meta.eql(self.region_chunk_origin, new_origin)) {
                try self.uploadFullRegion(new_origin);
            } else if (created_any) {
                try self.uploadFullRegion(new_origin);
            }

            gl.ActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_3D, self.tex);
            return self.tex;
        }
    };
}
