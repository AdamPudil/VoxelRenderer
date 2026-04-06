const std = @import("std");
const BlockChunk = @import("worldChunk.zig").BlockChunk;
const Voxel = @import("voxel.zig").Voxel;
const wc = @import("worldConstants.zig");
const gl = @import("../graphics/gl.zig");

const genUtil = @import("generation//utils.zig");
const noise = @import("generation/noises2d.zig");
const noise3d = @import("generation/noises3d.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

pub fn World(
    comptime BLOCK_SIZE: usize,
    comptime CHUNK_BLOCKS: usize,
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

        const FinishedChunk = struct {
            key: ChunkKey,
            chunk: BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS),
        };

        generator_thread: ?std.Thread = null,
        stream_mutex: std.Thread.Mutex = .{},
        stream_cv: std.Thread.Condition = .{},

        latest_cam_chunk: [3]i32 = .{ 0, 0, 0 },
        stop_generator: bool = false,

        ready_set: std.AutoHashMap(ChunkKey, void),
        inflight_set: std.AutoHashMap(ChunkKey, void),
        finished_chunks: std.ArrayList(FinishedChunk),

        allocator: std.mem.Allocator,
        chunks: std.AutoHashMap(ChunkKey, BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS)),

        dirty_chunks: std.ArrayList(ChunkKey),
        pending_chunks: std.ArrayList(ChunkKey),

        active_buf: c_uint = 0,
        bitmap_buf: c_uint = 0,
        block_mask_buf: c_uint = 0,
        voxel_lo_buf: c_uint = 0,
        voxel_hi_buf: c_uint = 0,

        active_tex: c_uint = 0,
        bitmap_tex: c_uint = 0,
        block_mask_tex: c_uint = 0,
        voxel_lo_tex: c_uint = 0,
        voxel_hi_tex: c_uint = 0,

        gpu_region_origin_chunk: [3]i32 = .{ 0, 0, 0 },
        gpu_dirty: bool = true,

        gpu_active_cpu: ?[]u32 = null,
        gpu_block_mask_cpu: ?[]u32 = null,
        gpu_voxel_bitmap_cpu: ?[]u32 = null,
        gpu_voxel_lo_cpu: ?[]u32 = null,
        gpu_voxel_hi_cpu: ?[]u32 = null,
        gpu_region_valid: bool = false,

        const stream_chunks_xz_i32: i32 = @intCast(STREAM_CHUNKS_XZ);
        const stream_chunks_y_i32: i32 = @intCast(STREAM_CHUNKS_Y);

        const chunk_voxel_side: usize = BLOCK_SIZE * CHUNK_BLOCKS;
        const chunk_voxel_side_i32: i32 = @intCast(chunk_voxel_side);

        const chunk_voxels: usize = chunk_voxel_side * chunk_voxel_side * chunk_voxel_side;
        const voxel_bitmap_words: usize = (chunk_voxels + 31) / 32;

        const chunk_blocks: usize = CHUNK_BLOCKS * CHUNK_BLOCKS * CHUNK_BLOCKS;
        const block_bitmap_words: usize = (chunk_blocks + 31) / 32;

        const region_slots: usize = STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y * STREAM_CHUNKS_XZ;

        pub fn init(allocator: std.mem.Allocator) !Self {
            var ret: Self = .{
                .allocator = allocator,
                .chunks = std.AutoHashMap(ChunkKey, BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS)).init(allocator),

                //.active_buf = 0,
                //.bitmap_buf = 0,
                //.voxel_buf = 0,

                //.active_tex = 0,
                //.bitmap_tex = 0,
                //.voxel_tex = 0,

                .gpu_region_origin_chunk = .{ 0, 0, 0 },
                .gpu_dirty = true,
                .dirty_chunks = std.ArrayList(ChunkKey).init(allocator),

                .pending_chunks = std.ArrayList(ChunkKey).init(allocator),

                .generator_thread = null,
                .stream_mutex = .{},
                .stream_cv = .{},
                .latest_cam_chunk = .{ 0, 0, 0 },
                .stop_generator = false,

                .ready_set = std.AutoHashMap(ChunkKey, void).init(allocator),
                .inflight_set = std.AutoHashMap(ChunkKey, void).init(allocator),
                .finished_chunks = std.ArrayList(FinishedChunk).init(allocator),
            };

            try gl.genBuffers(1, &ret.active_buf);
            try gl.genBuffers(1, &ret.block_mask_buf);
            try gl.genBuffers(1, &ret.bitmap_buf);
            try gl.genBuffers(1, &ret.voxel_lo_buf);
            try gl.genBuffers(1, &ret.voxel_hi_buf);

            gl.genTextures(1, &ret.active_tex);
            gl.genTextures(1, &ret.block_mask_tex);
            gl.genTextures(1, &ret.bitmap_tex);
            gl.genTextures(1, &ret.voxel_lo_tex);
            gl.genTextures(1, &ret.voxel_hi_tex);

            return ret;
        }

        pub fn deinit(self: *Self) !void {
            {
                self.stream_mutex.lock();
                self.stop_generator = true;
                self.stream_cv.signal();
                self.stream_mutex.unlock();
            }

            if (self.generator_thread) |thread| {
                thread.join();
            }

            for (self.finished_chunks.items) |*item| {
                item.chunk.deinit();
            }
            self.finished_chunks.deinit();

            self.ready_set.deinit();
            self.inflight_set.deinit();

            var it = self.chunks.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.chunks.deinit();

            if (self.block_mask_tex != 0) gl.deleteTextures(1, &self.block_mask_tex);
            if (self.voxel_hi_tex != 0) gl.deleteTextures(1, &self.voxel_hi_tex);
            if (self.voxel_lo_tex != 0) gl.deleteTextures(1, &self.voxel_lo_tex);

            if (self.block_mask_buf != 0) try gl.deleteBuffers(1, &self.block_mask_buf);
            if (self.voxel_hi_buf != 0) try gl.deleteBuffers(1, &self.voxel_hi_buf);
            if (self.voxel_lo_buf != 0) try gl.deleteBuffers(1, &self.voxel_lo_buf);
        }

        fn chunkDist2(a: ChunkKey, b: ChunkKey) i32 {
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const dz = a.z - b.z;
            return dx * dx + dy * dy + dz * dz;
        }

        fn updateLatestCameraChunk(self: *Self, cam_pos: [3]f32) void {
            const cam_chunk = [3]i32{
                worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[0])))),
                worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[1])))),
                worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[2])))),
            };

            self.stream_mutex.lock();
            self.latest_cam_chunk = cam_chunk;
            self.stream_cv.signal();
            self.stream_mutex.unlock();
        }

        fn drainFinishedChunks(self: *Self) !void {
            var local_finished = std.ArrayList(FinishedChunk).init(self.allocator);
            defer local_finished.deinit();

            self.stream_mutex.lock();
            std.mem.swap(std.ArrayList(FinishedChunk), &local_finished, &self.finished_chunks);
            self.stream_mutex.unlock();

            for (local_finished.items) |*item| {
                const gop = try self.chunks.getOrPut(item.key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = item.chunk;
                    try self.ready_set.put(item.key, {});
                    _ = self.inflight_set.remove(item.key);
                    self.gpu_dirty = true;
                } else {
                    item.chunk.deinit();
                    _ = self.inflight_set.remove(item.key);
                }
            }
        }

        pub fn enqueueInitialArea(self: *Self) !void {
            self.stream_mutex.lock();
            defer self.stream_mutex.unlock();

            const half_xz: i32 = 4; // 8 total
            const min_y: i32 = 0;
            const max_y: i32 = 1; // 2 chunks high

            var z: i32 = -half_xz;
            while (z < half_xz) : (z += 1) {
                var y: i32 = min_y;
                while (y <= max_y) : (y += 1) {
                    var x: i32 = -half_xz;
                    while (x < half_xz) : (x += 1) {
                        const key = ChunkKey{ .x = x, .y = y, .z = z };
                        if (!self.ready_set.contains(key) and !self.inflight_set.contains(key)) {
                            try self.inflight_set.put(key, {});
                        }
                    }
                }
            }

            var it = self.inflight_set.keyIterator();
            while (it.next()) |k| {
                _ = k;
            }

            self.stream_cv.signal();
        }

        fn findNextChunkToBuildLocked(self: *Self) ?ChunkKey {
            const cam = ChunkKey{
                .x = self.latest_cam_chunk[0],
                .y = self.latest_cam_chunk[1],
                .z = self.latest_cam_chunk[2],
            };

            const half_xz = @divFloor(stream_chunks_xz_i32, 2);
            const half_y = @divFloor(stream_chunks_y_i32, 2);

            var best_key: ?ChunkKey = null;
            var best_d2: i32 = 0x7fffffff;

            var dz: i32 = -half_xz;
            while (dz <= half_xz) : (dz += 1) {
                var dy: i32 = -half_y;
                while (dy <= half_y) : (dy += 1) {
                    var dx: i32 = -half_xz;
                    while (dx <= half_xz) : (dx += 1) {
                        const key = ChunkKey{
                            .x = cam.x + dx,
                            .y = cam.y + dy,
                            .z = cam.z + dz,
                        };

                        if (self.ready_set.contains(key)) continue;
                        if (self.inflight_set.contains(key)) continue;

                        const d2 = chunkDist2(key, cam);
                        if (d2 < best_d2) {
                            best_d2 = d2;
                            best_key = key;
                        }
                    }
                }
            }

            return best_key;
        }

        fn generatorMain(self: *Self) !void {
            while (true) {
                var key: ?ChunkKey = null;

                self.stream_mutex.lock();
                while (!self.stop_generator and key == null) {
                    key = self.findNextChunkToBuildLocked();
                    if (key == null) {
                        self.stream_cv.wait(&self.stream_mutex);
                    }
                }

                if (self.stop_generator) {
                    self.stream_mutex.unlock();
                    return;
                }

                try self.inflight_set.put(key.?, {});
                self.stream_mutex.unlock();

                var built = generateChunkStatic(self.allocator, key.?.x, key.?.y, key.?.z) catch {
                    self.stream_mutex.lock();
                    _ = self.inflight_set.remove(key.?);
                    self.stream_mutex.unlock();
                    continue;
                };

                self.stream_mutex.lock();
                self.finished_chunks.append(.{
                    .key = key.?,
                    .chunk = built,
                }) catch {
                    built.deinit();
                    _ = self.inflight_set.remove(key.?);
                    self.stream_mutex.unlock();
                    return;
                };
                self.stream_mutex.unlock();
            }
        }

        fn ensureGpuRegionStorage(self: *Self) !void {
            if (self.gpu_region_valid) return;

            self.gpu_active_cpu = try self.allocator.alloc(u32, region_slots);
            self.gpu_block_mask_cpu = try self.allocator.alloc(u32, region_slots * block_bitmap_words);
            self.gpu_voxel_bitmap_cpu = try self.allocator.alloc(u32, region_slots * voxel_bitmap_words);
            self.gpu_voxel_lo_cpu = try self.allocator.alloc(u32, region_slots * chunk_voxels);
            self.gpu_voxel_hi_cpu = try self.allocator.alloc(u32, region_slots * chunk_voxels);

            @memset(self.gpu_active_cpu.?, 0);
            @memset(self.gpu_block_mask_cpu.?, 0);
            @memset(self.gpu_voxel_bitmap_cpu.?, 0);
            @memset(self.gpu_voxel_lo_cpu.?, 0);
            @memset(self.gpu_voxel_hi_cpu.?, 0);

            self.gpu_region_valid = true;
        }

        fn packVoxelLo(v: Voxel) u32 {
            return (@as(u32, v.r)) |
                (@as(u32, v.g) << 8) |
                (@as(u32, v.b) << 16) |
                (@as(u32, v.transparency) << 24);
        }

        fn packVoxelHi(v: Voxel) u32 {
            return (@as(u32, v.opacity)) |
                (@as(u32, v.reflectiveness) << 8) |
                (@as(u32, v.luminescence) << 16) |
                (@as(u32, v.padding) << 24);
        }

        fn updateGpuSlotFromChunk(self: *Self, slot: usize, chunk: *BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS)) !void {
            const active = self.gpu_active_cpu.?;
            const block_mask = self.gpu_block_mask_cpu.?;
            const voxel_bitmap = self.gpu_voxel_bitmap_cpu.?;
            const voxel_lo = self.gpu_voxel_lo_cpu.?;
            const voxel_hi = self.gpu_voxel_hi_cpu.?;

            active[slot] = if (chunk.nonempty_block_count > 0) 1 else 0;

            const block_mask_base = slot * block_bitmap_words;
            for (chunk.block_occupancy, 0..) |w, i| {
                block_mask[block_mask_base + i] = w;
            }

            const voxel_bitmap_base = slot * voxel_bitmap_words;
            const voxel_lo_base = slot * chunk_voxels;
            const voxel_hi_base = slot * chunk_voxels;

            var voxel_index: usize = 0;
            for (chunk.blocks) |*block| {
                for (block.occupancy, 0..) |w, wi| {
                    voxel_bitmap[voxel_bitmap_base + voxel_index / 32 / 128 * 128 + wi] = w;
                }

                for (block.voxels) |v| {
                    voxel_lo[voxel_lo_base + voxel_index] = packVoxelLo(v);
                    voxel_hi[voxel_hi_base + voxel_index] = packVoxelHi(v);
                    voxel_index += 1;
                }
            }

            chunk.clearDirty();
        }

        fn generateChunkStatic(
            allocator: std.mem.Allocator,
            _: i32,
            cy: i32,
            _: i32,
        ) !BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS) {
            var chunk = try BlockChunk(BLOCK_SIZE, CHUNK_BLOCKS).init(allocator);

            const chunk_side_i32: i32 = @intCast(BLOCK_SIZE * CHUNK_BLOCKS);

            //const base_x = cx * chunk_side_i32;
            const base_y = cy * chunk_side_i32;
            //const base_z = cz * chunk_side_i32;

            const dirt = Voxel.rgb(96, 61, 29);
            const grass = Voxel.rgb(90, 180, 70);
            const stone = Voxel.rgb(120, 120, 120);

            for (0..chunk_side_i32) |lz| {
                for (0..chunk_side_i32) |ly| {
                    for (0..chunk_side_i32) |lx| {
                        //const wx = base_x + @as(i32, @intCast(lx));
                        const wy = base_y + @as(i32, @intCast(ly));
                        //const wz = base_z + @as(i32, @intCast(lz));

                        if (wy < 0) {
                            const v = if (wy == -1) grass else if (wy > -6) dirt else stone;
                            chunk.setVoxel(
                                @intCast(lx),
                                @intCast(ly),
                                @intCast(lz),
                                v,
                            );
                        }
                    }
                }
            }

            return chunk;
        }

        pub fn bindGpuTextures(self: *Self) void {
            gl.activeTexture(c.GL_TEXTURE0);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.active_tex);

            gl.activeTexture(c.GL_TEXTURE1);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.block_mask_tex);

            gl.activeTexture(c.GL_TEXTURE2);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.bitmap_tex);

            gl.activeTexture(c.GL_TEXTURE3);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_lo_tex);

            gl.activeTexture(c.GL_TEXTURE4);
            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_hi_tex);
        }

        inline fn divFloor(a: i32, b: i32) i32 {
            return @divFloor(a, b);
        }

        pub fn worldToChunkCoord(v: i32) i32 {
            return divFloor(v, chunk_voxel_side_i32);
        }

        pub fn startGenerator(self: *Self) !void {
            if (self.generator_thread != null) return;
            self.generator_thread = try std.Thread.spawn(.{}, generatorMain, .{self});
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

        //     fn slotIndex(rx: usize, ry: usize, rz: usize) usize {
        //         return rx + ry * STREAM_CHUNKS_XZ + rz * STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y;
        //     }

        fn uploadFullRegion(self: *Self, new_origin: [3]i32) !void {
            self.gpu_region_origin_chunk = new_origin;
            try self.ensureGpuRegionStorage();

            const active = self.gpu_active_cpu.?;
            const block_mask = self.gpu_block_mask_cpu.?;
            const voxel_bitmap = self.gpu_voxel_bitmap_cpu.?;
            const voxel_lo = self.gpu_voxel_lo_cpu.?;
            const voxel_hi = self.gpu_voxel_hi_cpu.?;

            @memset(active, 0);
            @memset(block_mask, 0);
            @memset(voxel_bitmap, 0);
            @memset(voxel_lo, 0);
            @memset(voxel_hi, 0);

            var rz: usize = 0;
            while (rz < STREAM_CHUNKS_XZ) : (rz += 1) {
                var ry: usize = 0;
                while (ry < STREAM_CHUNKS_Y) : (ry += 1) {
                    var rx: usize = 0;
                    while (rx < STREAM_CHUNKS_XZ) : (rx += 1) {
                        const cx = self.gpu_region_origin_chunk[0] + @as(i32, @intCast(rx));
                        const cy = self.gpu_region_origin_chunk[1] + @as(i32, @intCast(ry));
                        const cz = self.gpu_region_origin_chunk[2] + @as(i32, @intCast(rz));

                        const slot = rx + ry * STREAM_CHUNKS_XZ + rz * STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y;

                        const key = ChunkKey{ .x = cx, .y = cy, .z = cz };

                        if (self.chunks.getPtr(key)) |chunk| {
                            try self.updateGpuSlotFromChunk(slot, chunk);
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

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.block_mask_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(block_mask.len * @sizeOf(u32)),
                block_mask.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.block_mask_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.block_mask_buf);

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.bitmap_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(voxel_bitmap.len * @sizeOf(u32)),
                voxel_bitmap.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.bitmap_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.bitmap_buf);

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.voxel_lo_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(voxel_lo.len * @sizeOf(u32)),
                voxel_lo.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_lo_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.voxel_lo_buf);

            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.voxel_hi_buf);
            try gl.bufferData(
                c.GL_TEXTURE_BUFFER,
                @intCast(voxel_hi.len * @sizeOf(u32)),
                voxel_hi.ptr,
                c.GL_DYNAMIC_DRAW,
            );

            gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_hi_tex);
            try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, self.voxel_hi_buf);

            self.gpu_region_valid = true;
        }

        pub fn render(self: *Self, cam_pos: [3]f32) !void {
            self.updateLatestCameraChunk(cam_pos);
            try self.drainFinishedChunks();

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
