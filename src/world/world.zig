const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const gl = @import("../graphics/gl.zig");

const genUtil = @import("generation//utils.zig");
const noise = @import("generation/noises2d.zig");
const noise3d = @import("generation/noises3d.zig");

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
        chunks: std.AutoHashMap(ChunkKey, Chunk(T, 16, 16, 16)),

        active_buf: c_uint = 0,
        bitmap_buf: c_uint = 0,
        voxel_buf: c_uint = 0,

        active_tex: c_uint = 0,
        bitmap_tex: c_uint = 0,
        voxel_tex: c_uint = 0,

        gpu_region_origin_chunk: [3]i32 = .{ 0, 0, 0 },
        gpu_dirty: bool = true,

        const chunk_size_i32: i32 = @intCast(CHUNK_SIZE);
        const stream_chunks_xz_i32: i32 = @intCast(STREAM_CHUNKS_XZ);
        const stream_chunks_y_i32: i32 = @intCast(STREAM_CHUNKS_Y);

        const chunk_voxels: usize = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
        const bitmap_words: usize = (chunk_voxels + 31) / 32;
        const region_slots: usize = STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y * STREAM_CHUNKS_XZ;

        pub fn init(allocator: std.mem.Allocator) !Self {
            var ret: Self = .{
                .allocator = allocator,
                .chunks = std.AutoHashMap(ChunkKey, Chunk(T, 16, 16, 16)).init(allocator),

                .active_buf = 0,
                .bitmap_buf = 0,
                .voxel_buf = 0,

                .active_tex = 0,
                .bitmap_tex = 0,
                .voxel_tex = 0,

                .gpu_region_origin_chunk = .{ 0, 0, 0 },
                .gpu_dirty = true,
            };

            try gl.genBuffers(1, &ret.active_buf);
            try gl.genBuffers(1, &ret.bitmap_buf);
            try gl.genBuffers(1, &ret.voxel_buf);

            gl.genTextures(1, &ret.active_tex);
            gl.genTextures(1, &ret.bitmap_tex);
            gl.genTextures(1, &ret.voxel_tex);

            return ret;
        }

        pub fn deinit(self: *Self) !void {
            var it = self.chunks.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.chunks.deinit();

            if (self.active_tex != 0) gl.deleteTextures(1, &self.active_tex);
            if (self.bitmap_tex != 0) gl.deleteTextures(1, &self.bitmap_tex);
            if (self.voxel_tex != 0) gl.deleteTextures(1, &self.voxel_tex);

            if (self.active_buf != 0) try gl.deleteBuffers(1, &self.active_buf);
            if (self.bitmap_buf != 0) try gl.deleteBuffers(1, &self.bitmap_buf);
            if (self.voxel_buf != 0) try gl.deleteBuffers(1, &self.voxel_buf);
        }

        pub fn bindGpuTextures(self: *Self) !void {
            gl.activeTexture(c.GL_TEXTURE0);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.active_tex);

            gl.activeTexture(c.GL_TEXTURE1);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.bitmap_tex);

            gl.activeTexture(c.GL_TEXTURE2);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_tex);
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
            const x = @as(f32, @floatFromInt(wx));
            const z = @as(f32, @floatFromInt(wz));

            var sum: f32 = 0.0;
            var amp: f32 = 1.0;
            var freq: f32 = 0.02;
            var norm: f32 = 0.0;

            for (0..4) |_| {
                const n01 = noise.noise2D(x * freq, z * freq); // 0..1
                const n = n01 * 2.0 - 1.0; // -1..1
                sum += n * amp;
                norm += amp;
                amp *= 0.5;
                freq *= 2.0;
            }

            sum /= norm;

            //const base_height: f32 = 20.0;
            //const height_scale: f32 = 8.0;

            //return @as(i32, @intFromFloat(@round(base_height + sum * height_scale)));
            return 20 + @divFloor(wx, 8);
        }

        const GenMode = enum {
            menger_repeat,
            menger_world,
            pyramid_repeat,
            octahedron_repeat,
            organic_repeat,
            cave_crystals_repeat,
            voronoi_border_repeat,
            voronoi_border_world,
            voronoi_edges_world,
        };

        fn fillFractalChunk(
            chunk: *Chunk(T, 16, 16, 16),
            cx: i32,
            cy: i32,
            cz: i32,
            mode: GenMode,
        ) void {
            //const h = chunkHash3(cx, cy, cz);

            // keep 25% empty chunks for debug visibility
            //if ((h & 3) == 0) return;

            const size_i32: i32 = @intCast(CHUNK_SIZE);

            for (0..CHUNK_SIZE) |lz| {
                for (0..CHUNK_SIZE) |ly| {
                    for (0..CHUNK_SIZE) |lx| {
                        const lx_i: i32 = @intCast(lx);
                        const ly_i: i32 = @intCast(ly);
                        const lz_i: i32 = @intCast(lz);

                        const wx = cx * size_i32 + lx_i;
                        const wy = cy * size_i32 + ly_i;
                        const wz = cz * size_i32 + lz_i;

                        const solid = switch (mode) {
                            // repeats every chunk, but decided per voxel
                            .menger_repeat => noise3d.inMenger(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                            ),

                            // one continuous world-space fractal
                            .menger_world => noise3d.inMenger(wx, wy, wz),

                            .pyramid_repeat => noise3d.inPyramidLocal(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                                size_i32,
                            ),

                            .octahedron_repeat => noise3d.inOctahedronLocal(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                                size_i32,
                            ),
                            .organic_repeat => noise3d.inOrganicLocal(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                                size_i32,
                            ),
                            .cave_crystals_repeat => noise3d.inCaveCrystalsLocal(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                                size_i32,
                            ),
                            .voronoi_border_repeat => noise3d.inVoronoiBorderLocal(
                                genUtil.posMod(wx, size_i32),
                                genUtil.posMod(wy, size_i32),
                                genUtil.posMod(wz, size_i32),
                                size_i32,
                            ),

                            .voronoi_border_world => noise3d.inVoronoiBorderWorld(
                                wx,
                                wy,
                                wz,
                            ),
                            .voronoi_edges_world => noise3d.inVoronoiFaceEdgesWorld(
                                wx,
                                wy,
                                wz,
                            ),
                        };

                        if (solid) {
                            chunk.setVoxel(lx, ly, lz, @as(T, 1));
                        }
                    }
                }
            }
        }

        fn generateChunk(self: *Self, cx: i32, cy: i32, cz: i32) !Chunk(T, 16, 16, 16) {
            const genFrac = 1;

            if (genFrac == 1) {
                var chunk = try Chunk(T, 16, 16, 16).init(self.allocator);
                chunk.fill(@as(T, 0));

                fillFractalChunk(&chunk, cx, cy, cz, GenMode.menger_world);

                return chunk;
            } else {
                var chunk = try Chunk(T, 16, 16, 16).init(self.allocator);
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
                                chunk.setVoxel(lx, ly, lz, @as(T, 1));
                            }
                        }
                    }
                }

                return chunk;
            }
        }

        fn getOrCreateChunk(self: *Self, cx: i32, cy: i32, cz: i32) !struct { ptr: *Chunk(T, 16, 16, 16), created: bool } {
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
                return chunk.getVoxel(lx, ly, lz);
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

        fn slotIndex(rx: usize, ry: usize, rz: usize) usize {
            return rx + ry * STREAM_CHUNKS_XZ + rz * STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y;
        }

        fn uploadFullRegion(self: *Self, region_origin: [3]i32) !void {
            var active = try self.allocator.alloc(u32, region_slots);
            defer self.allocator.free(active);

            var bitmap = try self.allocator.alloc(u32, region_slots * bitmap_words);
            defer self.allocator.free(bitmap);

            var voxels = try self.allocator.alloc(u32, region_slots * chunk_voxels);
            defer self.allocator.free(voxels);

            @memset(active, 0);
            @memset(bitmap, 0);
            @memset(voxels, 0);

            for (0..STREAM_CHUNKS_XZ) |rz| {
                for (0..STREAM_CHUNKS_Y) |ry| {
                    for (0..STREAM_CHUNKS_XZ) |rx| {
                        const slot = slotIndex(rx, ry, rz);

                        const cx = region_origin[0] + @as(i32, @intCast(rx));
                        const cy = region_origin[1] + @as(i32, @intCast(ry));
                        const cz = region_origin[2] + @as(i32, @intCast(rz));

                        const res = try self.getOrCreateChunk(cx, cy, cz);
                        const chunk = res.ptr;

                        active[slot] = if (chunk.solid_count > 0) 1 else 0;

                        const bitmap_base = slot * bitmap_words;
                        const voxel_base = slot * chunk_voxels;

                        for (chunk.occupancy, 0..) |w, i| {
                            bitmap[bitmap_base + i] = w;
                        }

                        for (chunk.voxels, 0..) |v, i| {
                            voxels[voxel_base + i] = @as(u32, v);
                        }
                    }
                }
            }

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.active_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(active.len * @sizeOf(u32)),
                active.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.active_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.active_buf);

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.bitmap_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(bitmap.len * @sizeOf(u32)),
                bitmap.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.bitmap_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.bitmap_buf);

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.voxel_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(voxels.len * @sizeOf(u32)),
                voxels.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.voxel_buf);

            self.gpu_region_origin_chunk = region_origin;
            self.gpu_dirty = false;
        }

        //fn uploadChunkToTexture(self: *Self, chunk_x: usize, chunk_y: usize, chunk_z: usize, world_cx: i32, world_cy: i32, world_cz: i32) !void {
        //   const maybe_chunk = self.chunks.getPtr(.{ .x = world_cx, .y = world_cy, .z = world_cz });
        //
        //   const count = CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE;
        //   var buffer = try self.allocator.alloc(T, count);
        //   defer self.allocator.free(buffer);
        //   @memset(buffer, @as(T, 0));
        //
        //   if (maybe_chunk) |chunk| {
        //       for (0..CHUNK_SIZE) |lz| {
        //           for (0..CHUNK_SIZE) |ly| {
        //               for (0..CHUNK_SIZE) |lx| {
        //                   const idx = lx + ly * CHUNK_SIZE + lz * CHUNK_SIZE * CHUNK_SIZE;
        //                   buffer[idx] = chunk.getVoxel(lx, ly, lz);
        //               }
        //           }
        //       }
        //   }
        //
        //   gl.ActiveTexture(c.GL_TEXTURE0);
        //   c.glBindTexture(c.GL_TEXTURE_3D, self.tex);
        //
        //   gl.TexSubImage3D(
        //       c.GL_TEXTURE_3D,
        //       0,
        //       @intCast(chunk_x * CHUNK_SIZE),
        //       @intCast(chunk_y * CHUNK_SIZE),
        //       @intCast(chunk_z * CHUNK_SIZE),
        //       @intCast(CHUNK_SIZE),
        //       @intCast(CHUNK_SIZE),
        //       @intCast(CHUNK_SIZE),
        //       c.GL_RED_INTEGER,
        //       c.GL_UNSIGNED_SHORT,
        //       buffer.ptr,
        //   );
        //}

        //fn uploadEdgeForMove(self: *Self, old_origin: [3]i32, new_origin: [3]i32) !void {
        //    const dx = new_origin[0] - old_origin[0];
        //    const dy = new_origin[1] - old_origin[1];
        //    const dz = new_origin[2] - old_origin[2];
        //
        //    const moved_axes =
        //        @as(i32, if (dx != 0) 1 else 0) +
        //        @as(i32, if (dy != 0) 1 else 0) +
        //        @as(i32, if (dz != 0) 1 else 0);
        //
        //    if (moved_axes != 1) {
        //        try self.uploadFullRegion(new_origin);
        //        return;
        //    }
        //
        //    if ((dx != 0 and @abs(dx) != 1) or (dy != 0 and @abs(dy) != 1) or (dz != 0 and @abs(dz) != 1)) {
        //        try self.uploadFullRegion(new_origin);
        //        return;
        //    }
        //
        //    // This version keeps the old texture layout and overwrites the newly visible edge.
        //    // It is not a full ring-buffer yet, so it is only safe as a "lighter step" when you
        //    // also treat the texture logically as the new region after edge upload.
        //    // If you see spatial mismatch while moving, switch this fallback to full rebuild.
        //
        //    if (dx == 1) {
        //        const chunk_x = STREAM_CHUNKS_XZ - 1;
        //        const world_cx = new_origin[0] + @as(i32, @intCast(chunk_x));
        //        for (0..STREAM_CHUNKS_Y) |chunk_y| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_z| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    world_cx,
        //                    new_origin[1] + @as(i32, @intCast(chunk_y)),
        //                    new_origin[2] + @as(i32, @intCast(chunk_z)),
        //                );
        //            }
        //        }
        //    } else if (dx == -1) {
        //        const chunk_x: usize = 0;
        //        const world_cx = new_origin[0];
        //        for (0..STREAM_CHUNKS_Y) |chunk_y| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_z| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    world_cx,
        //                    new_origin[1] + @as(i32, @intCast(chunk_y)),
        //                    new_origin[2] + @as(i32, @intCast(chunk_z)),
        //                );
        //            }
        //        }
        //    } else if (dz == 1) {
        //        const chunk_z = STREAM_CHUNKS_XZ - 1;
        //        const world_cz = new_origin[2] + @as(i32, @intCast(chunk_z));
        //        for (0..STREAM_CHUNKS_Y) |chunk_y| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_x| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    new_origin[0] + @as(i32, @intCast(chunk_x)),
        //                    new_origin[1] + @as(i32, @intCast(chunk_y)),
        //                    world_cz,
        //                );
        //            }
        //        }
        //    } else if (dz == -1) {
        //        const chunk_z: usize = 0;
        //        const world_cz = new_origin[2];
        //        for (0..STREAM_CHUNKS_Y) |chunk_y| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_x| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    new_origin[0] + @as(i32, @intCast(chunk_x)),
        //                    new_origin[1] + @as(i32, @intCast(chunk_y)),
        //                    world_cz,
        //                );
        //            }
        //        }
        //    } else if (dy == 1) {
        //        const chunk_y = STREAM_CHUNKS_Y - 1;
        //        const world_cy = new_origin[1] + @as(i32, @intCast(chunk_y));
        //        for (0..STREAM_CHUNKS_XZ) |chunk_z| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_x| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    new_origin[0] + @as(i32, @intCast(chunk_x)),
        //                    world_cy,
        //                    new_origin[2] + @as(i32, @intCast(chunk_z)),
        //                );
        //            }
        //        }
        //    } else if (dy == -1) {
        //        const chunk_y: usize = 0;
        //        const world_cy = new_origin[1];
        //        for (0..STREAM_CHUNKS_XZ) |chunk_z| {
        //            for (0..STREAM_CHUNKS_XZ) |chunk_x| {
        //                try self.uploadChunkToTexture(
        //                    chunk_x,
        //                    chunk_y,
        //                    chunk_z,
        //                    new_origin[0] + @as(i32, @intCast(chunk_x)),
        //                    world_cy,
        //                    new_origin[2] + @as(i32, @intCast(chunk_z)),
        //                );
        //            }
        //        }
        //    }
        //
        //    self.region_chunk_origin = new_origin;
        //    self.gpu_region_origin = .{
        //        new_origin[0] * chunk_size_i32,
        //        new_origin[1] * chunk_size_i32,
        //        new_origin[2] * chunk_size_i32,
        //    };
        //    self.gpu_dirty = false;
        //}
        //
        //fn uploadChunk(self: *Self, chunk: *Chunk(T, 16, 16, 16)) !void {
        //    var gpu_voxels = try self.allocator.alloc(u32, chunk.voxels.len);
        //    defer self.allocator.free(gpu_voxels);
        //
        //    for (chunk.voxels, 0..) |v, i| {
        //        gpu_voxels[i] = @as(u32, v);
        //    }
        //
        //    try gl.bindBuffer(c.GL_SHADER_STORAGE_BUFFER, self.bitmap_ssbo);
        //    try gl.bufferData(
        //        c.GL_SHADER_STORAGE_BUFFER,
        //        @intCast(chunk.occupancy.len * @sizeOf(u32)),
        //        chunk.occupancy.ptr,
        //        c.GL_DYNAMIC_DRAW,
        //    );
        //    try gl.bindBufferBase(c.GL_SHADER_STORAGE_BUFFER, 0, self.bitmap_ssbo);
        //
        //    try gl.bindBuffer(c.GL_SHADER_STORAGE_BUFFER, self.voxel_ssbo);
        //    try gl.bufferData(
        //        c.GL_SHADER_STORAGE_BUFFER,
        //        @intCast(gpu_voxels.len * @sizeOf(u32)),
        //        gpu_voxels.ptr,
        //        c.GL_DYNAMIC_DRAW,
        //    );
        //    try gl.bindBufferBase(c.GL_SHADER_STORAGE_BUFFER, 1, self.voxel_ssbo);
        //}

        pub fn render(self: *Self, cam_pos: [3]f32) !void {
            //const cam_voxel = [3]i32{
            //    @as(i32, @intFromFloat(@floor(cam_pos[0]))),
            //    @as(i32, @intFromFloat(@floor(cam_pos[1]))),
            //    @as(i32, @intFromFloat(@floor(cam_pos[2]))),
            //};

            const new_origin = computeRegionChunkOrigin(cam_pos);

            if (self.gpu_dirty or
                self.gpu_region_origin_chunk[0] != new_origin[0] or
                self.gpu_region_origin_chunk[1] != new_origin[1] or
                self.gpu_region_origin_chunk[2] != new_origin[2])
            {
                try self.uploadFullRegion(new_origin);
            }
        }
    };
}
