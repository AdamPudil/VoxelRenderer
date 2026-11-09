const std = @import("std");
const Chunk = @import("worldChunk.zig").Chunk;
const BlockChunk = @import("worldChunk.zig").BlockChunk;
const Block = @import("block.zig").Block;
const VoxelBlock = @import("block.zig").VoxelBlock;
const Voxel = @import("voxel.zig").Voxel;
const wc = @import("worldConstants.zig");
const terrain = @import("terrainHierarchy.zig");
const terrain_streaming = @import("generation/terrainStreaming.zig");
const terrain_generator = @import("generation/terrainGenerator.zig");
const render_policy = @import("../rendering.zig");
const hierarchy = @import("renderHierarchy.zig");
const lighting = @import("../lighting.zig");
const gl = @import("../graphics/gl.zig");
const residency = @import("../graphics/worldResidency.zig");
const buffer_layout = @import("../graphics/worldBufferLayout.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

const BLOCK_VOXEL_CNT = wc.BLOCK_VOXEL_CNT;
const CHUNK_BLOCK_CNT = wc.CHUNK_BLOCK_CNT;
const CHUNK_BLOCK_TOTAL = wc.CHUNK_BLOCK_TOTAL;
const STREAM_CHUNKS_XZ = wc.STREAM_CHUNKS_XZ;
const STREAM_CHUNKS_Y = wc.STREAM_CHUNKS_Y;
const BLOCK_PALETTE_CNT = wc.BLOCK_PALLETE_SIZE;

const CHUNK_SIDE_VOXELS = BLOCK_VOXEL_CNT * CHUNK_BLOCK_CNT;
const REGION_SLOT_COUNT = STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y * STREAM_CHUNKS_XZ;
const VOXELS_PER_BLOCK = BLOCK_VOXEL_CNT * BLOCK_VOXEL_CNT * BLOCK_VOXEL_CNT;
const BLOCK_BITMAP_WORDS = @divExact(CHUNK_BLOCK_TOTAL, 32);
const VOXEL_BITMAP_WORDS = @divExact(VOXELS_PER_BLOCK, 32);

const ChunkState = enum(u32) {
    free = 0,
    mono = 1,
    block = 2,
};

const BlockState = enum(u32) {
    free = 0,
    mono = 1,
    voxel = 2,
};

pub const ChunkHeader = packed struct {
    state: u32,
    data0: u32,
    data1: u32,
    data2: u32,
};
// free:
//   data ignored
// mono:
//   data0 = chunk block id / material id
// block:
//   data0 = block_header_base
//   data1 = block count (normally CHUNK_BLOCK_TOTAL)
//   data2 = hierarchy root word offset + 1 in index pool (root then 64 children)
// terrain (state 3):
//   data0 = column root word offset + 1 (zero means unavailable)
//   data1 = optional exact overlay block-header base + 1
//   data2 = opaque terrain material low word; high word is 255

pub const BlockHeader = packed struct {
    state: u32,
    data0: u32,
    data1: u32,
    data2: u32,
};
// free:
//   ignored
// mono:
//   data0 = block id / material id
// voxel:
//   data0 = voxel_block_header_index
//   data2 = hierarchy root word offset + 1 in index pool (root then 64 children)
// inherit (state 3): only in terrain overlays; no edit, use procedural base

pub const VoxelBlockHeaderGpu = packed struct {
    bitmap_base: u32,
    palette_base: u32,
    index_base: u32,
    info: u32,
};
// info:
// bits 0..15   = solid_count
// bits 16..23  = palette_count
// bits 24..31  = index_bits (4 or 8)
pub const World = struct {
    const Self = @This();

    const ChunkKey = struct {
        x: i32,
        y: i32,
        z: i32,
    };

    const FinishedChunk = struct {
        key: ChunkKey,
        chunk: Chunk,
    };

    allocator: std.mem.Allocator,
    terrain_stream: ?*terrain_streaming.Stream = null,
    terrain_material: Voxel = Voxel.rgb(112, 137, 78),
    terrain_dirty: bool = false,
    terrain_build_active: bool = false,
    commit_budget_ns: u64 = 2 * std.time.ns_per_ms,
    commit_budget_words: usize = 1024 * 1024,
    terrain_build_tile: usize = 0,
    terrain_build_node: usize = 0,
    terrain_build_slot: usize = 0,
    terrain_build_block: usize = 0,
    terrain_build_roots: [terrain_streaming.tile_count]?u32 = .{null} ** terrain_streaming.tile_count,
    terrain_edit_revision: u64 = 0,
    upload_terrain_token: u64 = 0,
    upload_edit_revision: u64 = 0,
    upload_config_revision: u64 = 0,
    residency_failure: ?struct { token: u64, edit: u64, origin: [3]i32, reason: anyerror } = null,
    edited_blocks: std.AutoHashMap([3]i32, u64),
    overlay_versions: std.AutoHashMap([3]i32, u64),
    incremental_uploads: bool = true,
    gpu_residency: ?residency.Residency = null,
    incremental_overlay: ?*residency.Record = null,
    last_upload_submit_ns: u64 = 0,
    edit_bytes: usize = 0,
    edit_budget_bytes: usize = 32 * 1024 * 1024,

    chunks: std.AutoHashMap(ChunkKey, Chunk),
    dirty_chunks: std.ArrayList(ChunkKey),
    scene_lights: std.ArrayList(lighting.PointLight),
    block_lights: std.ArrayList(lighting.PointLight),

    generator_thread: ?std.Thread = null,
    stream_mutex: std.Thread.Mutex = .{},
    stream_cv: std.Thread.Condition = .{},
    latest_cam_chunk: [3]i32 = .{ 0, 0, 0 },
    stop_generator: bool = false,
    generation_budget: usize = @import("../rendering.zig").generation_chunks_per_frame,

    ready_set: std.AutoHashMap(ChunkKey, void),
    inflight_set: std.AutoHashMap(ChunkKey, void),
    finished_chunks: std.ArrayList(FinishedChunk),

    gpu_region_origin_chunk: [3]i32 = .{ 0, 0, 0 },
    gpu_region_valid: bool = false,
    gpu_revision: u64 = 0, // successful geometry uploads invalidate surface lighting
    upload_budget_bytes: usize = std.math.maxInt(usize),
    last_upload_bytes: usize = 0,
    last_commit_ns: u64 = 0,
    gpu_buffer_bytes: [6]usize = .{0} ** 6,
    staging_buffer_bytes: [6]usize = .{0} ** 6,
    upload_active: bool = false,
    upload_origin: [3]i32 = .{ 0, 0, 0 },
    upload_buffers: [6]c_uint = .{0} ** 6,
    upload_textures: [6]c_uint = .{0} ** 6,
    upload_buffer_index: usize = 0,
    upload_offset: usize = 0,
    pending_block_lights: std.ArrayList(lighting.PointLight),

    chunk_header_buf: c_uint = 0,
    block_header_buf: c_uint = 0,
    voxel_block_header_buf: c_uint = 0,
    bitmap_buf: c_uint = 0,
    palette_buf: c_uint = 0,
    index_buf: c_uint = 0,

    chunk_header_tex: c_uint = 0,
    block_header_tex: c_uint = 0,
    voxel_block_header_tex: c_uint = 0,
    bitmap_tex: c_uint = 0,
    palette_tex: c_uint = 0,
    index_tex: c_uint = 0,

    chunk_headers_cpu: []ChunkHeader = &.{},
    block_headers_cpu: std.ArrayList(BlockHeader),
    voxel_block_headers_cpu: std.ArrayList(VoxelBlockHeaderGpu),
    bitmap_pool_cpu: std.ArrayList(u32),
    palette_pool_cpu: std.ArrayList(u32),
    index_pool_cpu: std.ArrayList(u32),

    slot_keys: []?ChunkKey = &.{},

    pub fn initCpu(allocator: std.mem.Allocator) !Self {
        var self: Self = .{
            .allocator = allocator,
            .edited_blocks = std.AutoHashMap([3]i32, u64).init(allocator),
            .overlay_versions = std.AutoHashMap([3]i32, u64).init(allocator),
            .scene_lights = std.ArrayList(lighting.PointLight).init(allocator),
            .block_lights = std.ArrayList(lighting.PointLight).init(allocator),
            .pending_block_lights = std.ArrayList(lighting.PointLight).init(allocator),
            .chunks = std.AutoHashMap(ChunkKey, Chunk).init(allocator),
            .dirty_chunks = std.ArrayList(ChunkKey).init(allocator),

            .ready_set = std.AutoHashMap(ChunkKey, void).init(allocator),
            .inflight_set = std.AutoHashMap(ChunkKey, void).init(allocator),
            .finished_chunks = std.ArrayList(FinishedChunk).init(allocator),

            .block_headers_cpu = std.ArrayList(BlockHeader).init(allocator),
            .voxel_block_headers_cpu = std.ArrayList(VoxelBlockHeaderGpu).init(allocator),
            .bitmap_pool_cpu = std.ArrayList(u32).init(allocator),
            .palette_pool_cpu = std.ArrayList(u32).init(allocator),
            .index_pool_cpu = std.ArrayList(u32).init(allocator),
        };

        self.chunk_headers_cpu = try allocator.alloc(ChunkHeader, REGION_SLOT_COUNT);
        errdefer allocator.free(self.chunk_headers_cpu);
        self.slot_keys = try allocator.alloc(?ChunkKey, REGION_SLOT_COUNT);

        for (self.chunk_headers_cpu) |*h| h.* = .{ .state = 0, .data0 = 0, .data1 = 0, .data2 = 0 };
        for (self.slot_keys) |*k| k.* = null;

        return self;
    }

    pub fn init(allocator: std.mem.Allocator) !Self {
        var self = try initCpu(allocator);
        errdefer self.deinit() catch {};
        try gl.genBuffers(1, &self.chunk_header_buf);
        try gl.genBuffers(1, &self.block_header_buf);
        try gl.genBuffers(1, &self.voxel_block_header_buf);
        try gl.genBuffers(1, &self.bitmap_buf);
        try gl.genBuffers(1, &self.palette_buf);
        try gl.genBuffers(1, &self.index_buf);

        gl.genTextures(1, &self.chunk_header_tex);
        gl.genTextures(1, &self.block_header_tex);
        gl.genTextures(1, &self.voxel_block_header_tex);
        gl.genTextures(1, &self.bitmap_tex);
        gl.genTextures(1, &self.palette_tex);
        gl.genTextures(1, &self.index_tex);
        try self.uploadWholeGpuState();

        return self;
    }

    pub fn deinit(self: *Self) !void {
        if (self.terrain_stream) |stream| {
            stream.deinit();
            self.allocator.destroy(stream);
        }
        if (self.gpu_residency) |*resident| resident.deinit();
        self.edited_blocks.deinit();
        self.overlay_versions.deinit();
        {
            self.stream_mutex.lock();
            self.stop_generator = true;
            self.stream_cv.signal();
            self.stream_mutex.unlock();
        }

        if (self.generator_thread) |thread| thread.join();

        for (self.finished_chunks.items) |*item| {
            item.chunk.deinit(self.allocator);
        }
        self.finished_chunks.deinit();

        var it = self.chunks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.chunks.deinit();

        self.ready_set.deinit();
        self.inflight_set.deinit();
        self.dirty_chunks.deinit();
        self.scene_lights.deinit();
        self.block_lights.deinit();
        self.pending_block_lights.deinit();
        if (self.upload_textures[0] != 0) gl.deleteTextures(6, &self.upload_textures[0]);
        if (self.upload_buffers[0] != 0) try gl.deleteBuffers(6, &self.upload_buffers[0]);

        self.block_headers_cpu.deinit();
        self.voxel_block_headers_cpu.deinit();
        self.bitmap_pool_cpu.deinit();
        self.palette_pool_cpu.deinit();
        self.index_pool_cpu.deinit();

        self.allocator.free(self.chunk_headers_cpu);
        self.allocator.free(self.slot_keys);

        if (self.chunk_header_tex != 0) gl.deleteTextures(1, &self.chunk_header_tex);
        if (self.block_header_tex != 0) gl.deleteTextures(1, &self.block_header_tex);
        if (self.voxel_block_header_tex != 0) gl.deleteTextures(1, &self.voxel_block_header_tex);
        if (self.bitmap_tex != 0) gl.deleteTextures(1, &self.bitmap_tex);
        if (self.palette_tex != 0) gl.deleteTextures(1, &self.palette_tex);
        if (self.index_tex != 0) gl.deleteTextures(1, &self.index_tex);

        if (self.chunk_header_buf != 0) try gl.deleteBuffers(1, &self.chunk_header_buf);
        if (self.block_header_buf != 0) try gl.deleteBuffers(1, &self.block_header_buf);
        if (self.voxel_block_header_buf != 0) try gl.deleteBuffers(1, &self.voxel_block_header_buf);
        if (self.bitmap_buf != 0) try gl.deleteBuffers(1, &self.bitmap_buf);
        if (self.palette_buf != 0) try gl.deleteBuffers(1, &self.palette_buf);
        if (self.index_buf != 0) try gl.deleteBuffers(1, &self.index_buf);
    }

    // helpers
    inline fn divFloor(a: i32, b: i32) i32 {
        return @divFloor(a, b);
    }

    pub fn worldToChunkCoord(v: i32) i32 {
        return divFloor(v, @as(i32, @intCast(CHUNK_SIDE_VOXELS)));
    }

    fn computeRegionChunkOrigin(cam_pos: [3]f32) [3]i32 {
        const cx = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[0]))));
        const cy = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[1]))));
        const cz = worldToChunkCoord(@as(i32, @intFromFloat(@floor(cam_pos[2]))));

        return .{
            cx - @divFloor(@as(i32, @intCast(STREAM_CHUNKS_XZ)), 2),
            cy - @divFloor(@as(i32, @intCast(STREAM_CHUNKS_Y)), 2),
            cz - @divFloor(@as(i32, @intCast(STREAM_CHUNKS_XZ)), 2),
        };
    }

    fn slotIndex(rx: usize, ry: usize, rz: usize) usize {
        return rx + ry * STREAM_CHUNKS_XZ + rz * STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y;
    }

    fn packVoxelLo(v: Voxel) u32 {
        return (@as(u32, v.r)) | (@as(u32, v.g) << 8) | (@as(u32, v.b) << 16) | (@as(u32, v.refractive_index) << 24);
    }

    fn packVoxelHi(v: Voxel) u32 {
        return (@as(u32, v.opacity)) | (@as(u32, v.reflectiveness) << 8) | (@as(u32, v.luminescence) << 16) | (@as(u32, v.metallic) << 24);
    }

    // generation
    pub fn startGenerator(self: *Self) !void {
        if (self.terrain_stream) |stream| {
            try stream.start();
            return;
        }
        if (self.generator_thread != null) return;
        self.generator_thread = try std.Thread.spawn(.{}, generatorMain, .{self});
    }

    pub fn enableTerrain(self: *Self, config: terrain_generator.Config) !void {
        if (self.generator_thread != null or self.terrain_stream != null or self.chunks.count() != 0) return error.GeneratorAlreadyStarted;
        const stream = try self.allocator.create(terrain_streaming.Stream);
        errdefer self.allocator.destroy(stream);
        stream.* = try terrain_streaming.Stream.init(self.allocator, config, .{});
        self.terrain_stream = stream;
    }

    pub fn updateTerrain(self: *Self, snapshot: render_policy.Snapshot, position: [3]f32) void {
        if (self.terrain_stream) |stream| stream.update(snapshot, position);
    }

    pub const TerrainQuery = union(enum) { unavailable, air, solid: Voxel };
    pub fn queryVoxel(self: *const Self, pos: [3]i32) TerrainQuery {
        if (self.terrain_stream) |stream| {
            const coord = [3]i32{ @divFloor(pos[0], 16), @divFloor(pos[1], 16), @divFloor(pos[2], 16) };
            if (!self.edited_blocks.contains(coord)) {
                const batch = stream.resident orelse return .unavailable;
                const tile = batch.tile(pos[0], pos[2]) orelse return .unavailable;
                const sample = tile.at(pos[0], pos[2]);
                if (sample.side != 1) return .unavailable;
                return if (pos[1] < sample.height) .{ .solid = self.terrain_material } else .air;
            }
        }
        return if (self.authoredVoxelAt(pos)) |v| .{ .solid = v } else .air;
    }

    /// Exact readiness includes empty terrain; a proxy cannot authorize edits.
    pub fn terrainBlockReady(self: *const Self, coord: [3]i32) bool {
        if (self.terrain_stream == null or self.edited_blocks.contains(coord)) return true;
        for (0..16) |z| for (0..16) |x| {
            if (self.queryVoxel(.{ coord[0] * 16 + @as(i32, @intCast(x)), coord[1] * 16, coord[2] * 16 + @as(i32, @intCast(z)) }) == .unavailable) return false;
        };
        return true;
    }

    pub fn terrainSpawnHeight(self: *const Self, x: i32, z: i32) ?i32 {
        const stream = self.terrain_stream orelse return null;
        const batch = stream.resident orelse return null;
        // Wait for the complete interaction patch, including the movement margin.
        if (batch.coarse) return null;
        const tile = batch.tile(x, z) orelse return null;
        const sample = tile.at(x, z);
        return if (sample.side == 1) sample.height else null;
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

    fn chunkDist2(a: ChunkKey, b: ChunkKey) i32 {
        const dx = a.x - b.x;
        const dy = a.y - b.y;
        const dz = a.z - b.z;
        return (dx * dx + dz * dz) * (STREAM_CHUNKS_Y * STREAM_CHUNKS_Y) + dy * dy;
    }

    fn findNextChunkToBuildLocked(self: *Self) ?ChunkKey {
        const cam = ChunkKey{
            .x = self.latest_cam_chunk[0],
            .y = self.latest_cam_chunk[1],
            .z = self.latest_cam_chunk[2],
        };

        const half_xz = @divFloor(@as(i32, @intCast(STREAM_CHUNKS_XZ)), 2);
        const half_y = @divFloor(@as(i32, @intCast(STREAM_CHUNKS_Y)), 2);

        var best_key: ?ChunkKey = null;
        var best_d2: i32 = 0x7fffffff;

        var dz: i32 = -half_xz;
        while (dz < half_xz) : (dz += 1) {
            var dy: i32 = -half_y;
            while (dy < half_y) : (dy += 1) {
                var dx: i32 = -half_xz;
                while (dx < half_xz) : (dx += 1) {
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
                if (self.finished_chunks.items.len < @import("../rendering.zig").pending_generation_chunks)
                    key = self.findNextChunkToBuildLocked();
                if (key == null) self.stream_cv.wait(&self.stream_mutex);
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
                built.deinit(self.allocator);
                _ = self.inflight_set.remove(key.?);
                self.stream_mutex.unlock();
                return;
            };
            self.stream_mutex.unlock();
        }
    }

    fn drainFinishedChunks(self: *Self) !void {
        var local_finished = std.ArrayList(FinishedChunk).init(self.allocator);
        defer local_finished.deinit();

        self.stream_mutex.lock();
        const count = @min(self.generation_budget, self.finished_chunks.items.len);
        local_finished.appendSlice(self.finished_chunks.items[0..count]) catch |err| {
            self.stream_mutex.unlock();
            return err;
        };
        const remaining = self.finished_chunks.items.len - count;
        std.mem.copyForwards(FinishedChunk, self.finished_chunks.items[0..remaining], self.finished_chunks.items[count..]);
        self.finished_chunks.shrinkRetainingCapacity(remaining);
        self.stream_cv.signal();
        self.stream_mutex.unlock();

        // The worker reads these sets under the same mutex.
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        for (local_finished.items) |*item| {
            const gop = try self.chunks.getOrPut(item.key);
            if (!gop.found_existing) {
                gop.value_ptr.* = item.chunk;
                try self.ready_set.put(item.key, {});
                // Missing chunks already render as air. Streaming an empty
                // chunk changes CPU placement availability, but not GPU geometry
                // or cached lighting; avoid rebuilding/invalidation every frame.
                if (item.chunk.chunkData != .free) try self.dirty_chunks.append(item.key);
                _ = self.inflight_set.remove(item.key);
            } else {
                item.chunk.deinit(self.allocator);
                _ = self.inflight_set.remove(item.key);
            }
        }
    }

    fn generateChunkStatic(
        _: std.mem.Allocator,
        cx: i32,
        cy: i32,
        cz: i32,
    ) !Chunk {
        const dark_gray: Voxel = Voxel.rgb(49, 49, 56);
        const light_gray: Voxel = Voxel.rgb(196, 196, 224);
        const gray: Voxel = Voxel.rgb(98, 98, 112);
        //const blue = Voxel.rgb(50, 90, 220);

        const floor_half_extent: i32 = 4;
        const wall_height_chunks: i32 = 3;

        const inside_floor =
            cx >= -floor_half_extent and cx <= floor_half_extent and
            cz >= -floor_half_extent and cz <= floor_half_extent;

        const outside_floor = !inside_floor;

        // chunk
        if (inside_floor and cy == -1) {
            if (@mod(@abs(cx), 2) == @mod(@abs(cz), 2)) {
                return Chunk.initMono(0, light_gray);
            } else {
                return Chunk.initMono(0, dark_gray);
            }
        }

        // wall
        if (outside_floor and cy >= -1 and cy < (-1 + wall_height_chunks)) {
            return Chunk.initMono(0, gray);
        }

        return Chunk.initFree(0);
    }

    // voxel fill helper
    fn voxelLinearIndex(x: usize, y: usize, z: usize) usize {
        return x + y * BLOCK_VOXEL_CNT + z * BLOCK_VOXEL_CNT * BLOCK_VOXEL_CNT;
    }

    fn setOcc(words: []u32, idx: usize) void {
        const wi = idx >> 5;
        const bit: u5 = @intCast(idx & 31);
        words[wi] |= (@as(u32, 1) << bit);
    }

    fn setVoxelInVoxelBlock(vb: *VoxelBlock, x: usize, y: usize, z: usize, voxel: Voxel, palette_index: u8) void {
        const idx = voxelLinearIndex(x, y, z);
        const wi = idx >> 5;
        const bit: u5 = @intCast(idx & 31);

        if ((vb.occupance[wi] & (@as(u32, 1) << bit)) == 0) {
            vb.solid_count += 1;
            vb.occupance[wi] |= (@as(u32, 1) << bit);
        }

        vb.voxels[z][y][x] = palette_index;
        vb.pallete[palette_index] = voxel;
        vb.dirty = true;
    }

    pub fn bindGpuTextures(self: *Self) void {
        if (self.gpu_residency) |*resident| if (resident.published) {
            resident.bind();
            return;
        };
        gl.activeTexture(c.GL_TEXTURE0);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.chunk_header_tex);

        gl.activeTexture(c.GL_TEXTURE1);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.block_header_tex);

        gl.activeTexture(c.GL_TEXTURE2);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.voxel_block_header_tex);

        gl.activeTexture(c.GL_TEXTURE3);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.bitmap_tex);

        gl.activeTexture(c.GL_TEXTURE4);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.palette_tex);

        gl.activeTexture(c.GL_TEXTURE5);
        gl.bindTexture(c.GL_TEXTURE_BUFFER, self.index_tex);
    }

    pub const RayHit = struct {
        voxel: [3]i32,
        normal: [3]i32,
        distance: f32,

        pub fn blockCoord(self: RayHit) [3]i32 {
            return .{ @divFloor(self.voxel[0], BLOCK_VOXEL_CNT), @divFloor(self.voxel[1], BLOCK_VOXEL_CNT), @divFloor(self.voxel[2], BLOCK_VOXEL_CNT) };
        }

        pub fn adjacentBlock(self: RayHit) [3]i32 {
            var coord = self.blockCoord();
            for (0..3) |i| coord[i] += self.normal[i];
            return coord;
        }
    };

    /// Main-thread query of loaded world data; unloaded chunks are empty.
    pub fn voxelAt(self: *const Self, pos: [3]i32) ?Voxel {
        return switch (self.queryVoxel(pos)) {
            .solid => |v| v,
            else => null,
        };
    }

    fn authoredVoxelAt(self: *const Self, pos: [3]i32) ?Voxel {
        const key = ChunkKey{ .x = worldToChunkCoord(pos[0]), .y = worldToChunkCoord(pos[1]), .z = worldToChunkCoord(pos[2]) };
        const chunk = self.chunks.getPtr(key) orelse return null;
        switch (chunk.chunkData) {
            .free => return null,
            .mono => |voxel| return if (voxel.isEmpty()) null else voxel,
            .block => |bc| {
                const x: usize = @intCast(@mod(pos[0], CHUNK_SIDE_VOXELS));
                const y: usize = @intCast(@mod(pos[1], CHUNK_SIDE_VOXELS));
                const z: usize = @intCast(@mod(pos[2], CHUNK_SIDE_VOXELS));
                const block = &bc.blocks[z / BLOCK_VOXEL_CNT][y / BLOCK_VOXEL_CNT][x / BLOCK_VOXEL_CNT];
                const voxel = switch (block.blockData) {
                    .free => return null,
                    .mono => |v| v,
                    .voxel => |vb| vb.getVoxel(x % BLOCK_VOXEL_CNT, y % BLOCK_VOXEL_CNT, z % BLOCK_VOXEL_CNT) orelse return null,
                };
                return if (voxel.isEmpty()) null else voxel;
            },
        }
    }

    pub fn raycast(self: *const Self, origin: [3]f32, direction: [3]f32, reach: f32) ?RayHit {
        return self.raycastChecked(origin, direction, reach) catch null;
    }

    pub fn raycastChecked(self: *const Self, origin: [3]f32, direction: [3]f32, reach: f32) error{TerrainUnavailable}!?RayHit {
        var length: f32 = 0;
        for (direction) |d| length += d * d;
        if (length < 1e-12) return null;
        length = @sqrt(length);
        var voxel: [3]i32 = undefined;
        var step: [3]i32 = undefined;
        var delta: [3]f32 = undefined;
        var next: [3]f32 = undefined;
        for (0..3) |i| {
            const dir = direction[i] / length;
            voxel[i] = @intFromFloat(@floor(origin[i]));
            if (dir < 0 and origin[i] == @as(f32, @floatFromInt(voxel[i]))) voxel[i] -= 1;
            step[i] = if (dir > 0) 1 else if (dir < 0) -1 else 0;
            delta[i] = if (dir == 0) std.math.inf(f32) else @abs(1 / dir);
            const boundary = @as(f32, @floatFromInt(voxel[i] + @max(step[i], 0)));
            next[i] = if (dir == 0) std.math.inf(f32) else (boundary - origin[i]) / dir;
        }
        var normal = [3]i32{ 0, 0, 0 };
        var distance: f32 = 0;
        // A unit ray crosses at most sqrt(3) voxel planes per world unit.
        while (distance <= reach) {
            switch (self.queryVoxel(voxel)) {
                .unavailable => return error.TerrainUnavailable,
                .solid => return .{ .voxel = voxel, .normal = normal, .distance = distance },
                .air => {},
            }
            const axis: usize = if (next[0] < next[1] and next[0] < next[2]) 0 else if (next[1] < next[2]) 1 else 2;
            distance = next[axis];
            for (0..3) |i| if (next[i] == distance) {
                voxel[i] += step[i];
                next[i] += delta[i];
            };
            normal = .{ 0, 0, 0 };
            normal[axis] = -step[axis];
        }
        return null;
    }

    pub fn blockIsEmpty(self: *const Self, coord: [3]i32) bool {
        if (self.terrain_stream != null) {
            if (!self.terrainBlockReady(coord)) return false;
            for (0..16) |z| for (0..16) |y| for (0..16) |x| {
                if (self.queryVoxel(.{ coord[0] * 16 + @as(i32, @intCast(x)), coord[1] * 16 + @as(i32, @intCast(y)), coord[2] * 16 + @as(i32, @intCast(z)) }) != .air) return false;
            };
            return true;
        }
        const key = ChunkKey{ .x = @divFloor(coord[0], CHUNK_BLOCK_CNT), .y = @divFloor(coord[1], CHUNK_BLOCK_CNT), .z = @divFloor(coord[2], CHUNK_BLOCK_CNT) };
        const chunk = self.chunks.getPtr(key) orelse return false; // do not place into unstreamed terrain
        return switch (chunk.chunkData) {
            .free => true,
            .mono => |v| v.isEmpty(),
            .block => |bc| bc.blocks[@intCast(@mod(coord[2], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[1], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[0], CHUNK_BLOCK_CNT))].isFree(),
        };
    }

    /// Remove one occupied voxel, expanding a uniform block only when necessary.
    /// setBlock commits the edited copy and handles chunk expansion/dirty tracking.
    pub fn removeVoxel(self: *Self, pos: [3]i32) !bool {
        if (self.terrain_stream != null) {
            const coord = [3]i32{ @divFloor(pos[0], 16), @divFloor(pos[1], 16), @divFloor(pos[2], 16) };
            if (!self.terrainBlockReady(coord)) return error.TerrainUnavailable;
            if (self.voxelAt(pos) == null) return false;
            // Materialize just the edited block, never the full terrain chunk.
            if (!self.edited_blocks.contains(coord)) {
                var block = try Block.initVoxel(self.allocator, 0);
                defer block.deinit(self.allocator);
                block.blockData.voxel.setPaletteEntry(1, self.terrain_material);
                for (0..16) |z| for (0..16) |y| for (0..16) |x| {
                    const p = [3]i32{ coord[0] * 16 + @as(i32, @intCast(x)), coord[1] * 16 + @as(i32, @intCast(y)), coord[2] * 16 + @as(i32, @intCast(z)) };
                    if (self.voxelAt(p) != null) block.blockData.voxel.setVoxel(x, y, z, 1);
                };
                block.blockData.voxel.clearVoxel(@intCast(@mod(pos[0], 16)), @intCast(@mod(pos[1], 16)), @intCast(@mod(pos[2], 16)));
                try self.setBlock(coord, &block);
                return true;
            }
        }
        if (self.voxelAt(pos) == null) return false;
        const key = ChunkKey{ .x = worldToChunkCoord(pos[0]), .y = worldToChunkCoord(pos[1]), .z = worldToChunkCoord(pos[2]) };
        const chunk = self.chunks.getPtr(key).?;
        const coord = [3]i32{ @divFloor(pos[0], BLOCK_VOXEL_CNT), @divFloor(pos[1], BLOCK_VOXEL_CNT), @divFloor(pos[2], BLOCK_VOXEL_CNT) };
        const source = switch (chunk.chunkData) {
            .free => return false,
            .mono => |v| Block.initMono(0, v),
            .block => |bc| bc.blocks[@intCast(@mod(coord[2], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[1], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[0], CHUNK_BLOCK_CNT))],
        };
        var edited = if (source.blockData == .mono) try Block.initVoxel(self.allocator, source.blockID) else try source.clone(self.allocator);
        defer edited.deinit(self.allocator);
        const vb = edited.blockData.voxel;
        if (source.blockData == .mono) {
            vb.pallete[0] = source.blockData.mono;
            @memset(&vb.occupance, std.math.maxInt(u32));
            vb.solid_count = VOXELS_PER_BLOCK;
        }
        edited.light = source.light;
        vb.clearVoxel(@intCast(@mod(pos[0], BLOCK_VOXEL_CNT)), @intCast(@mod(pos[1], BLOCK_VOXEL_CNT)), @intCast(@mod(pos[2], BLOCK_VOXEL_CNT)));
        // A damaged lamp remains attached until its last luminous insert is gone.
        if (edited.light != null) {
            var emitting = false;
            for (0..BLOCK_VOXEL_CNT) |z| for (0..BLOCK_VOXEL_CNT) |y| for (0..BLOCK_VOXEL_CNT) |x| {
                if (vb.getVoxel(x, y, z)) |v| if (v.luminescence > 0) {
                    emitting = true;
                };
            };
            if (!emitting) edited.light = null;
        }
        if (vb.solid_count == 0) edited.setFree(self.allocator, source.blockID);
        try self.setBlock(coord, &edited);
        return true;
    }

    /// coord is in 16-voxel block units. The world owns a deep copy of model.
    /// Converting a mono chunk preserves all its other blocks.
    pub fn setBlock(self: *Self, coord: [3]i32, model: *const Block) !void {
        return self.setBlockOriented(coord, model, .positive_z);
    }

    pub fn setBlockOriented(self: *Self, coord: [3]i32, model: *const Block, orientation: @import("blockRotation.zig").Orientation) !void {
        if (!self.terrainBlockReady(coord)) return error.TerrainUnavailable;
        const new_edit = self.terrain_stream != null and !self.edited_blocks.contains(coord);
        const edit_cost = @sizeOf(BlockChunk) + @sizeOf(VoxelBlock) + 128;
        if (new_edit and edit_cost > self.edit_budget_bytes - self.edit_bytes) return error.EditBudgetExceeded;
        if (new_edit) try self.edited_blocks.ensureUnusedCapacity(1);
        if (self.terrain_stream != null) try self.overlay_versions.ensureUnusedCapacity(1);
        var copy = try model.cloneOriented(self.allocator, orientation);
        errdefer copy.deinit(self.allocator);
        const key = ChunkKey{ .x = @divFloor(coord[0], CHUNK_BLOCK_CNT), .y = @divFloor(coord[1], CHUNK_BLOCK_CNT), .z = @divFloor(coord[2], CHUNK_BLOCK_CNT) };
        try self.dirty_chunks.ensureUnusedCapacity(1);
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        try self.ready_set.ensureUnusedCapacity(1);
        const gop = try self.chunks.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = if (self.terrain_stream != null) Chunk.initFree(0) else try generateChunkStatic(self.allocator, key.x, key.y, key.z);
        errdefer if (!gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
            _ = self.chunks.remove(key);
        };
        const chunk = gop.value_ptr;
        if (chunk.chunkData != .block) {
            const bc = try self.allocator.create(BlockChunk);
            bc.* = BlockChunk.initFree();
            if (chunk.chunkData == .mono) {
                for (&bc.blocks) |*plane| for (plane) |*row| for (row) |*block| {
                    block.* = Block.initMono(0, chunk.chunkData.mono);
                };
                bc.solid_count = CHUNK_BLOCK_TOTAL;
            }
            chunk.chunkData = .{ .block = bc };
        }
        const bc = chunk.chunkData.block;
        const dest = &bc.blocks[@intCast(@mod(coord[2], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[1], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[0], CHUNK_BLOCK_CNT))];
        if (!dest.isFree()) bc.solid_count -= 1;
        dest.deinit(self.allocator);
        dest.* = copy;
        if (!dest.isFree()) bc.solid_count += 1;
        bc.dirty = true;
        // Any already-running generator result is discarded by drainFinishedChunks.
        self.ready_set.putAssumeCapacity(key, {});
        self.dirty_chunks.appendAssumeCapacity(key);
        if (self.terrain_stream != null) {
            if (new_edit) {
                self.edit_bytes += edit_cost;
            }
            self.terrain_edit_revision +%= 1;
            self.edited_blocks.putAssumeCapacity(coord, self.terrain_edit_revision);
            self.overlay_versions.putAssumeCapacity(.{ key.x, key.y, key.z }, self.terrain_edit_revision);
            self.terrain_dirty = true;
        }
    }

    // pack for gpu
    fn rebuildGpuRegion(self: *Self, new_origin: [3]i32) !void {
        self.upload_origin = new_origin;
        // Keep published lights with published geometry while the replacement
        // uploads. CPU arrays below form an immutable snapshot until completion.
        std.mem.swap(std.ArrayList(lighting.PointLight), &self.block_lights, &self.pending_block_lights);
        defer std.mem.swap(std.ArrayList(lighting.PointLight), &self.block_lights, &self.pending_block_lights);

        for (self.chunk_headers_cpu) |*h| {
            h.* = .{ .state = 0, .data0 = 0, .data1 = 0, .data2 = 0 };
        }

        self.block_lights.clearRetainingCapacity();
        self.block_headers_cpu.clearRetainingCapacity();
        self.voxel_block_headers_cpu.clearRetainingCapacity();
        self.bitmap_pool_cpu.clearRetainingCapacity();
        self.palette_pool_cpu.clearRetainingCapacity();
        self.index_pool_cpu.clearRetainingCapacity();

        var rz: usize = 0;
        while (rz < STREAM_CHUNKS_XZ) : (rz += 1) {
            var ry: usize = 0;
            while (ry < STREAM_CHUNKS_Y) : (ry += 1) {
                var rx: usize = 0;
                while (rx < STREAM_CHUNKS_XZ) : (rx += 1) {
                    const slot = slotIndex(rx, ry, rz);

                    const key = ChunkKey{
                        .x = new_origin[0] + @as(i32, @intCast(rx)),
                        .y = new_origin[1] + @as(i32, @intCast(ry)),
                        .z = new_origin[2] + @as(i32, @intCast(rz)),
                    };

                    self.slot_keys[slot] = key;

                    if (self.chunks.getPtr(key)) |chunk| {
                        try self.packChunkToGpu(slot, chunk);
                    }
                }
            }
        }

        if (self.upload_buffers[0] == 0) try gl.genBuffers(6, &self.upload_buffers[0]);
        if (self.upload_textures[0] == 0) gl.genTextures(6, &self.upload_textures[0]);
        self.upload_buffer_index = 0;
        self.upload_offset = 0;
        self.upload_active = true;
    }

    fn beginTerrainBuild(self: *Self, origin: [3]i32) !void {
        if (self.incremental_uploads and self.gpu_residency == null)
            self.gpu_residency = try residency.Residency.init(self.allocator, self.chunk_headers_cpu.len * @sizeOf(ChunkHeader), render_policy.gpu_arena_bytes);
        self.upload_origin = origin;
        self.upload_terrain_token = self.terrain_stream.?.resident.?.request.token;
        self.upload_edit_revision = self.terrain_edit_revision;
        self.upload_config_revision = self.terrain_stream.?.resident.?.config_revision;
        self.terrain_build_tile = 0;
        self.terrain_build_node = 0;
        self.terrain_build_slot = 0;
        self.terrain_build_block = 0;
        self.terrain_build_roots = .{null} ** terrain_streaming.tile_count;
        self.pending_block_lights.clearRetainingCapacity();
        self.block_headers_cpu.clearRetainingCapacity();
        self.voxel_block_headers_cpu.clearRetainingCapacity();
        self.bitmap_pool_cpu.clearRetainingCapacity();
        self.palette_pool_cpu.clearRetainingCapacity();
        self.index_pool_cpu.clearRetainingCapacity();
        // Reserve once while the array is empty: growing it later would copy a
        // multi-megabyte prefix in a single otherwise bounded commit slice.
        const words = if (self.incremental_uploads) VOXELS_PER_BLOCK + 260 else self.terrain_stream.?.resident.?.bytes / 4 + self.edited_blocks.count() * (VOXELS_PER_BLOCK + 260);
        try self.index_pool_cpu.ensureTotalCapacity(words);
        self.incremental_overlay = null;
        self.terrain_build_active = true;
        self.terrain_dirty = false;
        self.dirty_chunks.clearRetainingCapacity();
    }

    /// Repack a bounded number of words/blocks on the main thread. Readers keep
    /// using old GPU buffers throughout CPU assembly and the subsequent upload.
    fn advanceTerrainBuild(self: *Self) !void {
        if (self.incremental_uploads) return self.advanceIncrementalBuild();
        var timer = try std.time.Timer.start();
        defer self.last_commit_ns = timer.read();
        var words: usize = 0;
        const batch = self.terrain_stream.?.resident.?;
        while (self.terrain_build_tile < terrain_streaming.tile_count and words < self.commit_budget_words and timer.read() < self.commit_budget_ns) {
            const index = self.terrain_build_tile;
            const x = (self.upload_origin[0] + @as(i32, @intCast(index % STREAM_CHUNKS_XZ))) * 256;
            const z = (self.upload_origin[2] + @as(i32, @intCast(index / STREAM_CHUNKS_XZ))) * 256;
            const tile = batch.tile(x, z) orelse {
                self.terrain_build_tile += 1;
                continue;
            };
            if (self.terrain_build_node == 0) self.terrain_build_roots[index] = @intCast(self.index_pool_cpu.items.len);
            const count: usize = @min(@min(tile.nodes.len - self.terrain_build_node, 256), (self.commit_budget_words - words) / 4);
            if (count == 0) return;
            try self.index_pool_cpu.ensureUnusedCapacity(count * 4);
            for (tile.nodes[self.terrain_build_node..][0..count]) |node| self.index_pool_cpu.appendSliceAssumeCapacity(&.{ node.children, @bitCast(node.height), @bitCast(node.min_height), @bitCast(node.max_height) });
            self.terrain_build_node += count;
            words += count * 4;
            if (self.terrain_build_node == tile.nodes.len) {
                self.terrain_build_node = 0;
                self.terrain_build_tile += 1;
            }
        }
        while (self.terrain_build_tile == terrain_streaming.tile_count and self.terrain_build_slot < REGION_SLOT_COUNT and words < self.commit_budget_words and timer.read() < self.commit_budget_ns) {
            const slot = self.terrain_build_slot;
            const x = slot % STREAM_CHUNKS_XZ;
            const y = slot / STREAM_CHUNKS_XZ % STREAM_CHUNKS_Y;
            const z = slot / (STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y);
            const key = ChunkKey{ .x = self.upload_origin[0] + @as(i32, @intCast(x)), .y = self.upload_origin[1] + @as(i32, @intCast(y)), .z = self.upload_origin[2] + @as(i32, @intCast(z)) };
            if (self.terrain_build_block == 0) {
                self.slot_keys[slot] = key;
                self.chunk_headers_cpu[slot] = .{ .state = 3, .data0 = if (self.terrain_build_roots[x + z * STREAM_CHUNKS_XZ]) |root| root + 1 else 0, .data1 = 0, .data2 = packVoxelLo(self.terrain_material) };
            }
            if (self.chunks.getPtr(key)) |chunk| if (chunk.chunkData == .block) {
                if (self.terrain_build_block == 0) self.chunk_headers_cpu[slot].data1 = @intCast(self.block_headers_cpu.items.len + 1);
                const b = self.terrain_build_block;
                const bx = b % 16;
                const by = b / 16 % 16;
                const bz = b / 256;
                const coord = [3]i32{ key.x * 16 + @as(i32, @intCast(bx)), key.y * 16 + @as(i32, @intCast(by)), key.z * 16 + @as(i32, @intCast(bz)) };
                const block = &chunk.chunkData.block.blocks[bz][by][bx];
                if (self.edited_blocks.contains(coord)) {
                    const before = self.index_pool_cpu.items.len;
                    try self.packBlockToGpu(block);
                    words += 4 + self.index_pool_cpu.items.len - before;
                    if (lighting.LightingFeatures.point_lights) if (block.light) |local| if (!block.isFree()) {
                        var light = local;
                        for (0..3) |axis| light.position[axis] += @floatFromInt(coord[axis] * 16);
                        try self.pending_block_lights.append(light);
                    };
                } else {
                    try self.block_headers_cpu.append(.{ .state = 3, .data0 = 0, .data1 = 0, .data2 = 0 });
                    words += 4;
                }
                self.terrain_build_block += 1;
                if (self.terrain_build_block < CHUNK_BLOCK_TOTAL) continue;
            };
            self.terrain_build_slot += 1;
            self.terrain_build_block = 0;
            words += 4;
        }
        if (self.terrain_build_slot != REGION_SLOT_COUNT) return;
        if (self.upload_buffers[0] == 0) try gl.genBuffers(6, &self.upload_buffers[0]);
        if (self.upload_textures[0] == 0) gl.genTextures(6, &self.upload_textures[0]);
        self.upload_buffer_index = 0;
        self.upload_offset = 0;
        self.upload_active = true;
        self.terrain_build_active = false;
    }

    fn incrementalBlock(self: *Self, coord: [3]i32, block: *const Block, version: u64) !*residency.Record {
        const r = &self.gpu_residency.?;
        const key = residency.Key{ .kind = .block, .coord = coord, .version = version };
        if (r.find(key)) |record| return record;
        // The existing packer writes one block to small local scratch pools.
        self.block_headers_cpu.clearRetainingCapacity();
        self.voxel_block_headers_cpu.clearRetainingCapacity();
        self.bitmap_pool_cpu.clearRetainingCapacity();
        self.palette_pool_cpu.clearRetainingCapacity();
        self.index_pool_cpu.clearRetainingCapacity();
        try self.packBlockToGpu(block);
        const record = try r.create(key, .{ 0, self.voxel_block_headers_cpu.items.len * 16, self.bitmap_pool_cpu.items.len * 4, self.palette_pool_cpu.items.len * 4, self.index_pool_cpu.items.len * 4 });
        var header = self.block_headers_cpu.items[0];
        if (header.state == 2) {
            header.data0 += record.base(1) / 16;
            if (header.data2 != 0) header.data2 += record.base(4) / 4;
            for (self.voxel_block_headers_cpu.items) |*vh| {
                vh.bitmap_base += record.base(2) / 4;
                vh.palette_base += record.base(3) / 4;
                vh.index_base += record.base(4) / 4;
            }
        }
        record.header = .{ header.state, header.data0, header.data1, header.data2 };
        try r.copy(record, 1, std.mem.sliceAsBytes(self.voxel_block_headers_cpu.items));
        try r.copy(record, 2, std.mem.sliceAsBytes(self.bitmap_pool_cpu.items));
        try r.copy(record, 3, std.mem.sliceAsBytes(self.palette_pool_cpu.items));
        try r.copy(record, 4, std.mem.sliceAsBytes(self.index_pool_cpu.items));
        if (lighting.LightingFeatures.point_lights) if (block.light) |local| if (!block.isFree()) {
            var light = local;
            for (0..3) |axis| light.position[axis] += @floatFromInt(coord[axis] * 16);
            record.light = light;
        };
        return record;
    }

    fn advanceIncrementalBuild(self: *Self) !void {
        var timer = try std.time.Timer.start();
        defer self.last_commit_ns = timer.read();
        const r = &self.gpu_residency.?;
        if (!r.transaction and !try r.begin()) return;
        const batch = self.terrain_stream.?.resident.?;
        var words: usize = 0;
        while (self.terrain_build_tile < terrain_streaming.tile_count and words < self.commit_budget_words and timer.read() < self.commit_budget_ns) {
            const index = self.terrain_build_tile;
            const x = (self.upload_origin[0] + @as(i32, @intCast(index % STREAM_CHUNKS_XZ))) * 256;
            const z = (self.upload_origin[2] + @as(i32, @intCast(index / STREAM_CHUNKS_XZ))) * 256;
            if (batch.tile(x, z)) |tile| {
                const key = residency.Key{ .kind = .tile, .coord = .{ x, 0, z }, .version = tile.payloadId(), .config = batch.config_revision };
                const record = r.find(key) orelse new: {
                    const record = try r.create(key, .{ 0, 0, 0, 0, tile.nodes.len * @sizeOf(terrain.Node) });
                    r.pinTile(record, tile.*);
                    break :new record;
                };
                self.terrain_build_roots[index] = record.base(4) / 4;
            }
            self.terrain_build_tile += 1;
            words += 4;
        }
        while (self.terrain_build_tile == terrain_streaming.tile_count and self.terrain_build_slot < REGION_SLOT_COUNT and words < self.commit_budget_words and timer.read() < self.commit_budget_ns) {
            const slot = self.terrain_build_slot;
            const x = slot % STREAM_CHUNKS_XZ;
            const y = slot / STREAM_CHUNKS_XZ % STREAM_CHUNKS_Y;
            const z = slot / (STREAM_CHUNKS_XZ * STREAM_CHUNKS_Y);
            const coord = [3]i32{ self.upload_origin[0] + @as(i32, @intCast(x)), self.upload_origin[1] + @as(i32, @intCast(y)), self.upload_origin[2] + @as(i32, @intCast(z)) };
            const key = ChunkKey{ .x = coord[0], .y = coord[1], .z = coord[2] };
            if (self.terrain_build_block == 0) {
                self.slot_keys[slot] = key;
                self.chunk_headers_cpu[slot] = .{ .state = 3, .data0 = if (self.terrain_build_roots[x + z * STREAM_CHUNKS_XZ]) |root| root + 1 else 0, .data1 = 0, .data2 = packVoxelLo(self.terrain_material) };
                if (self.overlay_versions.get(coord)) |version| {
                    const overlay_key = residency.Key{ .kind = .overlay, .coord = coord, .version = version };
                    if (r.find(overlay_key)) |record| {
                        self.chunk_headers_cpu[slot].data1 = record.base(0) / 16 + 1;
                        self.terrain_build_slot += 1;
                        words += 4;
                        continue;
                    }
                    const record = try r.create(overlay_key, .{ CHUNK_BLOCK_TOTAL * 16, 0, 0, 0, 0 });
                    // Allocate once, then fill under the block/time budget below.
                    record.data[0] = try self.allocator.alloc(u8, CHUNK_BLOCK_TOTAL * 16);
                    r.staging_bytes += record.data[0].len;
                    self.incremental_overlay = record;
                    self.chunk_headers_cpu[slot].data1 = record.base(0) / 16 + 1;
                }
            }
            if (self.incremental_overlay) |overlay| {
                const b = self.terrain_build_block;
                const bx = b % 16;
                const by = b / 16 % 16;
                const bz = b / 256;
                const block_coord = [3]i32{ coord[0] * 16 + @as(i32, @intCast(bx)), coord[1] * 16 + @as(i32, @intCast(by)), coord[2] * 16 + @as(i32, @intCast(bz)) };
                var header = BlockHeader{ .state = 3, .data0 = 0, .data1 = 0, .data2 = 0 };
                if (self.edited_blocks.get(block_coord)) |version| {
                    const chunk = self.chunks.getPtr(key).?;
                    const record = try self.incrementalBlock(block_coord, &chunk.chunkData.block.blocks[bz][by][bx], version);
                    try overlay.dependencies.append(record);
                    header = .{ .state = record.header[0], .data0 = record.header[1], .data1 = record.header[2], .data2 = record.header[3] };
                }
                std.mem.bytesAsSlice(BlockHeader, overlay.data[0])[b] = header;
                self.terrain_build_block += 1;
                words += 4;
                if (self.terrain_build_block < CHUNK_BLOCK_TOTAL) continue;
                self.incremental_overlay = null;
            }
            self.terrain_build_block = 0;
            self.terrain_build_slot += 1;
            words += 4;
        }
        if (self.terrain_build_slot != REGION_SLOT_COUNT) return;
        var it = r.records.valueIterator();
        while (it.next()) |record| if (record.*.wanted) {
            if (record.*.light) |light| try self.pending_block_lights.append(light);
        };
        self.upload_active = true;
        self.terrain_build_active = false;
    }

    fn advanceIncrementalUpload(self: *Self) !void {
        self.last_upload_bytes = 0;
        if (!self.upload_active) return;
        var timer = try std.time.Timer.start();
        defer self.last_upload_submit_ns = timer.read();
        const r = &self.gpu_residency.?;
        if (self.terrainSnapshotStale()) {
            try r.cancel();
            self.upload_active = false;
            self.terrain_dirty = true;
            return;
        }
        if (!try r.upload(std.mem.sliceAsBytes(self.chunk_headers_cpu), self.upload_budget_bytes, &self.last_upload_bytes)) return;
        if (self.terrainSnapshotStale()) {
            try r.cancel();
            self.upload_active = false;
            self.terrain_dirty = true;
            return;
        }
        try r.publish();
        std.mem.swap(std.ArrayList(lighting.PointLight), &self.block_lights, &self.pending_block_lights);
        self.gpu_region_origin_chunk = self.upload_origin;
        self.gpu_region_valid = true;
        self.gpu_revision +%= 1;
        self.upload_active = false;
    }

    // chunk packing
    fn packChunkToGpu(self: *Self, slot: usize, chunk: *Chunk) !void {
        switch (chunk.chunkData) {
            .free => {
                self.chunk_headers_cpu[slot] = .{
                    .state = @intFromEnum(ChunkState.free),
                    .data0 = 0,
                    .data1 = 0,
                    .data2 = 0,
                };
            },
            .mono => |v| {
                self.chunk_headers_cpu[slot] = .{
                    .state = @intFromEnum(ChunkState.mono),
                    .data0 = packVoxelLo(v),
                    .data1 = packVoxelHi(v),
                    .data2 = 0,
                };
            },
            .block => |bc| {
                const block_base: u32 = @intCast(self.block_headers_cpu.items.len);

                try self.block_headers_cpu.ensureUnusedCapacity(CHUNK_BLOCK_TOTAL);

                for (0..CHUNK_BLOCK_CNT) |z| {
                    for (0..CHUNK_BLOCK_CNT) |y| {
                        for (0..CHUNK_BLOCK_CNT) |x| {
                            const block = &bc.blocks[z][y][x];
                            try self.packBlockToGpu(block);
                            if (lighting.LightingFeatures.point_lights) {
                                if (block.light) |local| {
                                    if (!block.isFree()) {
                                        var light = local;
                                        const key = self.slot_keys[slot].?;
                                        const coords = [3]i32{ key.x, key.y, key.z };
                                        const offsets = [3]usize{ x, y, z };
                                        for (0..3) |axis| light.position[axis] += @floatFromInt(coords[axis] * CHUNK_SIDE_VOXELS + @as(i32, @intCast(offsets[axis])) * BLOCK_VOXEL_CNT);
                                        try self.block_lights.append(light);
                                    }
                                }
                            }
                        }
                    }
                }

                // Rebuild every affected ancestor from authoritative packed children.
                var nodes: [hierarchy.children]hierarchy.Summary = undefined;
                for (0..4) |z| for (0..4) |y| for (0..4) |x| {
                    var blocks: [hierarchy.children]hierarchy.Summary = undefined;
                    for (0..4) |dz| for (0..4) |dy| for (0..4) |dx| {
                        const header = self.block_headers_cpu.items[block_base + (x * 4 + dx) + (y * 4 + dy) * 16 + (z * 4 + dz) * 256];
                        blocks[dx + dy * 4 + dz * 16] = switch (header.state) {
                            0 => .{},
                            1 => hierarchy.Summary.material(@bitCast(@as(u64, header.data0) | (@as(u64, header.data1) << 32)), 4096),
                            else => self.readSummary(header.data2),
                        };
                    };
                    nodes[x + y * 4 + z * 16] = hierarchy.Summary.combine(&blocks, 4096);
                };
                const summary = try self.packSummaries(&nodes, 64 * 64 * 64);
                self.chunk_headers_cpu[slot] = .{
                    .state = @intFromEnum(ChunkState.block),
                    .data0 = block_base,
                    .data1 = CHUNK_BLOCK_TOTAL,
                    .data2 = summary,
                };
            },
        }
    }

    fn packBlockToGpu(self: *Self, block: *const Block) !void {
        switch (block.blockData) {
            .free => {
                try self.block_headers_cpu.append(.{
                    .state = @intFromEnum(BlockState.free),
                    .data0 = 0,
                    .data1 = 0,
                    .data2 = 0,
                });
            },
            .mono => |voxel| {
                try self.block_headers_cpu.append(.{
                    .state = @intFromEnum(BlockState.mono),
                    .data0 = packVoxelLo(voxel),
                    .data1 = packVoxelHi(voxel),
                    .data2 = 0,
                });
            },
            .voxel => |vb| {
                const hdr_index: u32 = @intCast(self.voxel_block_headers_cpu.items.len);

                const bitmap_base: u32 = @intCast(self.bitmap_pool_cpu.items.len);
                for (vb.occupance) |w| try self.bitmap_pool_cpu.append(w);

                const palette_base: u32 = @intCast(self.palette_pool_cpu.items.len);
                var p: usize = 0;
                while (p < BLOCK_PALETTE_CNT) : (p += 1) {
                    try self.palette_pool_cpu.append(packVoxelLo(vb.pallete[p]));
                    try self.palette_pool_cpu.append(packVoxelHi(vb.pallete[p]));
                }

                const index_base: u32 = @intCast(self.index_pool_cpu.items.len);
                var z: usize = 0;
                while (z < BLOCK_VOXEL_CNT) : (z += 1) {
                    var y: usize = 0;
                    while (y < BLOCK_VOXEL_CNT) : (y += 1) {
                        var x: usize = 0;
                        while (x < BLOCK_VOXEL_CNT) : (x += 1) {
                            try self.index_pool_cpu.append(vb.voxels[z][y][x]);
                        }
                    }
                }

                try self.voxel_block_headers_cpu.append(.{
                    .bitmap_base = bitmap_base,
                    .palette_base = palette_base,
                    .index_base = index_base,
                    .info = vb.solid_count | (@as(u32, BLOCK_PALETTE_CNT) << 16) | (@as(u32, 8) << 24),
                });

                const nodes = hierarchy.voxelNodes(vb);
                const summary = try self.packSummaries(&nodes, 64);
                try self.block_headers_cpu.append(.{
                    .state = @intFromEnum(BlockState.voxel),
                    .data0 = hdr_index,
                    .data1 = 0,
                    .data2 = summary,
                });
            },
        }
    }

    fn packSummaries(self: *Self, nodes: *const [hierarchy.children]hierarchy.Summary, child_volume: u32) !u32 {
        const pointer: u32 = @intCast(self.index_pool_cpu.items.len + 1);
        const root = hierarchy.Summary.combine(nodes, child_volume);
        try self.index_pool_cpu.appendSlice(&.{ root.flags, root.lo, root.hi, root.occupied });
        for (nodes) |node| try self.index_pool_cpu.appendSlice(&.{ node.flags, node.lo, node.hi, node.occupied });
        return pointer;
    }

    fn readSummary(self: *const Self, pointer: u32) hierarchy.Summary {
        const words = self.index_pool_cpu.items[pointer - 1 ..][0..4];
        return .{ .flags = words[0], .lo = words[1], .hi = words[2], .occupied = words[3] };
    }

    // upload
    fn uploadWholeGpuState(self: *Self) !void {
        try uploadBufferTex(ChunkHeader, self.chunk_header_buf, self.chunk_header_tex, self.chunk_headers_cpu);
        try uploadBufferTex(BlockHeader, self.block_header_buf, self.block_header_tex, self.block_headers_cpu.items);
        try uploadBufferTex(VoxelBlockHeaderGpu, self.voxel_block_header_buf, self.voxel_block_header_tex, self.voxel_block_headers_cpu.items);
        try uploadBufferTex(u32, self.bitmap_buf, self.bitmap_tex, self.bitmap_pool_cpu.items);
        try uploadBufferTex(u32, self.palette_buf, self.palette_tex, self.palette_pool_cpu.items);
        try uploadBufferTex(u32, self.index_buf, self.index_tex, self.index_pool_cpu.items);
    }

    fn uploadBufferTex(comptime T: type, buf: c_uint, tex: c_uint, data: []const T) !void {
        const header = T == ChunkHeader or T == BlockHeader or T == VoxelBlockHeaderGpu;
        if (header) comptime std.debug.assert(@sizeOf(T) == 16);
        var limit: c_int = 0;
        c.glGetIntegerv(c.GL_MAX_TEXTURE_BUFFER_SIZE, &limit);
        try buffer_layout.validate(data.len * @sizeOf(T), header, @intCast(@max(limit, 0)));
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, buf);
        try gl.bufferData(
            c.GL_TEXTURE_BUFFER,
            @intCast(buffer_layout.allocationBytes(data.len * @sizeOf(T), header)),
            if (data.len == 0) null else data.ptr,
            c.GL_DYNAMIC_DRAW,
        );
        gl.bindTexture(c.GL_TEXTURE_BUFFER, tex);
        try gl.texBuffer(c.GL_TEXTURE_BUFFER, buffer_layout.format(header), buf);
    }

    /// Upload into a second set of buffers under a strict byte budget. A draw
    /// sees either complete old geometry/lights or complete new geometry/lights.
    fn advanceUpload(self: *Self) !void {
        if (self.terrain_stream != null and self.incremental_uploads) return self.advanceIncrementalUpload();
        self.last_upload_bytes = 0;
        if (!self.upload_active) return;
        // Movement or an edit can invalidate a transfer between frames. Cancel
        // before allocating or sending more bytes, including with a zero budget.
        if (self.terrainSnapshotStale()) {
            self.upload_active = false;
            self.terrain_dirty = true;
            return;
        }
        const sources = [_][]const u8{
            std.mem.sliceAsBytes(self.chunk_headers_cpu),
            std.mem.sliceAsBytes(self.block_headers_cpu.items),
            std.mem.sliceAsBytes(self.voxel_block_headers_cpu.items),
            std.mem.sliceAsBytes(self.bitmap_pool_cpu.items),
            std.mem.sliceAsBytes(self.palette_pool_cpu.items),
            std.mem.sliceAsBytes(self.index_pool_cpu.items),
        };
        while (self.upload_buffer_index < sources.len) {
            const i = self.upload_buffer_index;
            const source = sources[i];
            if (self.last_upload_bytes == self.upload_budget_bytes and source.len > 0) return;
            try gl.bindBuffer(c.GL_TEXTURE_BUFFER, self.upload_buffers[i]);
            if (self.upload_offset == 0) {
                const header = i < 3;
                var limit: c_int = 0;
                c.glGetIntegerv(c.GL_MAX_TEXTURE_BUFFER_SIZE, &limit);
                try buffer_layout.validate(source.len, header, @intCast(@max(limit, 0)));
                const bytes = buffer_layout.allocationBytes(source.len, header);
                try gl.bufferData(c.GL_TEXTURE_BUFFER, @intCast(bytes), null, c.GL_DYNAMIC_DRAW);
                self.staging_buffer_bytes[i] = bytes;
                gl.bindTexture(c.GL_TEXTURE_BUFFER, self.upload_textures[i]);
                try gl.texBuffer(c.GL_TEXTURE_BUFFER, buffer_layout.format(header), self.upload_buffers[i]);
            }
            const count = @min(source.len - self.upload_offset, self.upload_budget_bytes - self.last_upload_bytes);
            if (count > 0) try gl.bufferSubData(c.GL_TEXTURE_BUFFER, @intCast(self.upload_offset), @intCast(count), source[self.upload_offset..].ptr);
            self.upload_offset += count;
            self.last_upload_bytes += count;
            if (self.upload_offset != source.len) return;
            self.upload_buffer_index += 1;
            self.upload_offset = 0;
        }
        if (self.terrainSnapshotStale()) {
            self.upload_active = false;
            self.terrain_dirty = true;
            return;
        }
        const buffers = [_]*c_uint{ &self.chunk_header_buf, &self.block_header_buf, &self.voxel_block_header_buf, &self.bitmap_buf, &self.palette_buf, &self.index_buf };
        const textures = [_]*c_uint{ &self.chunk_header_tex, &self.block_header_tex, &self.voxel_block_header_tex, &self.bitmap_tex, &self.palette_tex, &self.index_tex };
        for (buffers, textures, 0..) |buf, tex, i| {
            std.mem.swap(c_uint, buf, &self.upload_buffers[i]);
            std.mem.swap(c_uint, tex, &self.upload_textures[i]);
            std.mem.swap(usize, &self.gpu_buffer_bytes[i], &self.staging_buffer_bytes[i]);
        }
        std.mem.swap(std.ArrayList(lighting.PointLight), &self.block_lights, &self.pending_block_lights);
        self.gpu_region_origin_chunk = self.upload_origin;
        self.gpu_region_valid = true;
        self.gpu_revision +%= 1;
        self.upload_active = false;
    }

    fn terrainSnapshotStale(self: *Self) bool {
        const stream = self.terrain_stream orelse return false;
        stream.mutex.lock();
        defer stream.mutex.unlock();
        return self.upload_config_revision != stream.config.revision or stream.request == null or self.upload_terrain_token != stream.request.?.token or self.upload_edit_revision != self.terrain_edit_revision;
    }

    /// A stationary benchmark must not mistake a coarse/intermediate publication
    /// for the completed request. Read worker-owned request state under its lock.
    pub fn captureReady(self: *Self) bool {
        if (!self.gpu_region_valid or self.upload_active or self.terrain_build_active) return false;
        if (self.terrain_stream) |stream| {
            stream.mutex.lock();
            defer stream.mutex.unlock();
            const batch = stream.resident orelse return false;
            const request = stream.request orelse return false;
            return !batch.coarse and !self.terrain_dirty and self.residency_failure == null and
                batch.request.token == request.token and self.upload_terrain_token == request.token and
                self.upload_config_revision == stream.config.revision and self.upload_edit_revision == self.terrain_edit_revision;
        }
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        return self.inflight_set.count() == 0 and self.finished_chunks.items.len == 0 and
            self.dirty_chunks.items.len == 0 and (self.generator_thread == null or self.findNextChunkToBuildLocked() == null);
    }

    pub fn snapshotBytes(self: *const Self) usize {
        if (self.gpu_residency) |*r| {
            var bytes: usize = self.chunk_headers_cpu.len * @sizeOf(ChunkHeader);
            var it = r.records.valueIterator();
            while (it.next()) |record| if (record.*.published) {
                bytes += record.*.payload_bytes;
            };
            return bytes;
        }
        return self.chunk_headers_cpu.len * @sizeOf(ChunkHeader) + self.block_headers_cpu.items.len * @sizeOf(BlockHeader) +
            self.voxel_block_headers_cpu.items.len * @sizeOf(VoxelBlockHeaderGpu) +
            (self.bitmap_pool_cpu.items.len + self.palette_pool_cpu.items.len + self.index_pool_cpu.items.len) * @sizeOf(u32);
    }

    pub fn cpuSnapshotAllocatedBytes(self: *const Self) usize {
        return (if (self.gpu_residency) |*r| r.staging_bytes else @as(usize, 0)) + self.chunk_headers_cpu.len * @sizeOf(ChunkHeader) + self.block_headers_cpu.capacity * @sizeOf(BlockHeader) +
            self.voxel_block_headers_cpu.capacity * @sizeOf(VoxelBlockHeaderGpu) +
            (self.bitmap_pool_cpu.capacity + self.palette_pool_cpu.capacity + self.index_pool_cpu.capacity) * @sizeOf(u32);
    }
    pub fn gpuAllocatedBytes(self: *const Self) usize {
        var bytes: usize = 0;
        for (self.gpu_buffer_bytes, self.staging_buffer_bytes) |published, staging| bytes += published + staging;
        if (self.gpu_residency) |*r| bytes += r.allocatedBytes();
        return bytes;
    }

    fn failTerrainBuild(self: *Self, reason: anyerror) !void {
        if (self.gpu_residency) |*r| try r.cancel();
        self.terrain_build_active = false;
        self.upload_active = false;
        self.terrain_dirty = true;
        if (reason == error.OutOfMemory) return;
        if (reason == error.GeometryCapacityExceeded or reason == error.GeometryStagingLimit or reason == error.GeometryTextureLimit) {
            const batch = self.terrain_stream.?.resident.?;
            self.residency_failure = .{ .token = batch.request.token, .edit = self.terrain_edit_revision, .origin = self.upload_origin, .reason = reason };
            std.debug.print("Terrain upload paused: {s}; retaining published geometry. Change demand or increase configured GPU arena budgets.\n", .{@errorName(reason)});
            return;
        }
        return reason;
    }

    // render
    pub fn render(self: *Self, cam_pos: [3]f32) !void {
        self.last_upload_bytes = 0;
        self.last_commit_ns = 0;
        self.last_upload_submit_ns = 0;
        if (self.gpu_residency) |*r| _ = try r.poll();
        if (self.terrain_stream == null) {
            self.updateLatestCameraChunk(cam_pos);
            try self.drainFinishedChunks();
        }

        if (self.upload_active) {
            try self.advanceUpload();
            return; // keep edits arriving during upload queued for the next snapshot
        }
        if (self.terrain_build_active) {
            if (self.terrainSnapshotStale()) {
                if (self.gpu_residency) |*r| try r.cancel();
                self.terrain_build_active = false;
                self.terrain_dirty = true;
            } else {
                self.advanceTerrainBuild() catch |err| {
                    try self.failTerrainBuild(err);
                    return;
                };
                try self.advanceUpload();
                return;
            }
        }
        if (self.terrain_stream) |stream| {
            if (stream.take()) |batch| {
                if (stream.resident) |old| old.deinit(self.allocator);
                stream.resident = batch;
                self.terrain_dirty = true;
            }
            // Retain the complete previous GPU snapshot while a newer request
            // is being generated, including its old streaming bounds.
            if (stream.resident) |batch| {
                stream.mutex.lock();
                const current = stream.request != null and batch.request.token == stream.request.?.token;
                stream.mutex.unlock();
                if (!current) return;
            } else return;
        }
        const new_origin = computeRegionChunkOrigin(cam_pos);
        if (self.residency_failure) |failure| {
            if (self.terrain_stream) |stream| if (stream.resident) |batch| {
                if (failure.token == batch.request.token and failure.edit == self.terrain_edit_revision and std.meta.eql(failure.origin, new_origin)) return;
            };
            self.residency_failure = null;
        }

        var visible_dirty = false;
        for (self.dirty_chunks.items) |key| {
            if (key.x >= new_origin[0] and key.x < new_origin[0] + STREAM_CHUNKS_XZ and
                key.y >= new_origin[1] and key.y < new_origin[1] + STREAM_CHUNKS_Y and
                key.z >= new_origin[2] and key.z < new_origin[2] + STREAM_CHUNKS_XZ)
            {
                visible_dirty = true;
                break;
            }
        }
        if (!self.gpu_region_valid or
            self.gpu_region_origin_chunk[0] != new_origin[0] or
            self.gpu_region_origin_chunk[1] != new_origin[1] or
            self.gpu_region_origin_chunk[2] != new_origin[2] or visible_dirty or self.terrain_dirty)
        {
            if (self.terrain_stream != null) {
                self.beginTerrainBuild(new_origin) catch |err| {
                    try self.failTerrainBuild(err);
                    return;
                };
                self.advanceTerrainBuild() catch |err| {
                    try self.failTerrainBuild(err);
                    return;
                };
                try self.advanceUpload();
                return;
            }
            self.rebuildGpuRegion(new_origin) catch |err| {
                if (self.terrain_stream != null and err == error.OutOfMemory) return;
                return err;
            };
            self.terrain_dirty = false;
        }
        // Off-region changes remain owned by chunks; entering that region always
        // rebuilds it. They cannot affect rays limited to the current GPU volume.
        self.dirty_chunks.clearRetainingCapacity();
        try self.advanceUpload();
    }
};

test "edits preserve mono chunk neighbors, clone models and pack actual material" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    var source = try Block.initVoxel(a, 42);
    defer source.deinit(a);
    source.blockData.voxel.setPaletteEntry(1, Voxel.rgb(255, 0, 0));
    source.blockData.voxel.setVoxel(0, 0, 0, 1);
    try world.setBlock(.{ -1, -1, -1 }, &source);
    source.blockData.voxel.clearVoxel(0, 0, 0);
    try std.testing.expectEqual(@as(u8, 255), world.voxelAt(.{ -16, -16, -16 }).?.r);
    try std.testing.expect(world.voxelAt(.{ -15, -16, -16 }) == null);
    // The rest of the procedural solid floor chunk survives its expansion.
    try std.testing.expect(world.voxelAt(.{ -17, -16, -16 }) != null);
    const empty = Block.initEmpty(0);
    try world.setBlock(.{ -1, -1, -1 }, &empty);
    try std.testing.expect(world.blockIsEmpty(.{ -1, -1, -1 }));
    try std.testing.expect(world.voxelAt(.{ -16, -16, -16 }) == null);
    try std.testing.expect(world.voxelAt(.{ -17, -16, -16 }) != null);
    var mono = Block.initMono(1234, Voxel.rgb(11, 22, 33));
    try world.packBlockToGpu(&mono);
    const header = world.block_headers_cpu.items[0];
    try std.testing.expectEqual(World.packVoxelLo(mono.blockData.mono), header.data0);
    try std.testing.expectEqual(World.packVoxelHi(mono.blockData.mono), header.data1);
}

test "center ray finds voxel faces, respects reach and supports negative coordinates" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    const block = Block.initMono(3, Voxel.rgb(5, 10, 15));
    try world.setBlock(.{ -1, 0, -1 }, &block);
    const hit = world.raycast(.{ -8, 30, -8 }, .{ 0, -1, 0 }, 64).?;
    try std.testing.expectEqual([3]i32{ -8, 15, -8 }, hit.voxel);
    try std.testing.expectEqual([3]i32{ 0, 1, 0 }, hit.normal);
    try std.testing.expectEqual([3]i32{ -1, 1, -1 }, hit.adjacentBlock());
    try std.testing.expectEqual(@as(f32, 14), hit.distance);
    try std.testing.expect(world.raycast(.{ -8, 30, -8 }, .{ 0, -1, 0 }, 10) == null);
    try std.testing.expect(world.raycast(.{ -8, 30, -8 }, .{ 0, 0, 0 }, 64) == null);
    try std.testing.expect(world.raycast(.{ -8, 30, -8 }, .{ 0, 1, 0 }, 64) == null);
}

test "oriented placement is picked, packed and edited in world coordinates" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    var model = try Block.initVoxel(a, 42);
    defer model.deinit(a);
    var emitter = Voxel.rgb(20, 255, 60);
    emitter.luminescence = 255;
    model.blockData.voxel.setPaletteEntry(1, emitter);
    model.blockData.voxel.setPaletteEntry(2, Voxel.rgb(255, 0, 0));
    model.blockData.voxel.setVoxel(1, 2, 3, 1);
    model.blockData.voxel.setVoxel(4, 5, 6, 2);
    model.light = .{ .position = .{ 1.5, 2.5, 3.5 } };
    const coords = [_][3]i32{ .{ -17, 6, -1 }, .{ -16, 6, 0 }, .{ 15, 6, 15 }, .{ 16, 6, 16 } };
    const first = [_][3]i32{ .{ 1, 2, 3 }, .{ 3, 2, 14 }, .{ 14, 2, 12 }, .{ 12, 2, 1 } };
    const second = [_][3]i32{ .{ 4, 5, 6 }, .{ 6, 5, 11 }, .{ 11, 5, 9 }, .{ 9, 5, 4 } };
    for (std.enums.values(@import("blockRotation.zig").Orientation), coords, first, second) |orientation, coord, p, q| {
        try world.setBlockOriented(coord, &model, orientation);
        var target: [3]i32 = undefined;
        var other: [3]i32 = undefined;
        var eye: [3]f32 = undefined;
        for (0..3) |axis| {
            target[axis] = coord[axis] * BLOCK_VOXEL_CNT + p[axis];
            other[axis] = coord[axis] * BLOCK_VOXEL_CNT + q[axis];
            eye[axis] = @as(f32, @floatFromInt(target[axis])) + 0.5;
        }
        eye[1] += 8;
        const hit = world.raycast(eye, .{ 0, -1, 0 }, 10).?;
        try std.testing.expectEqual(target, hit.voxel);
        try std.testing.expectEqual(coord, hit.blockCoord());
        try std.testing.expectEqual(emitter, world.voxelAt(target).?);
        const key = World.ChunkKey{ .x = @divFloor(coord[0], CHUNK_BLOCK_CNT), .y = @divFloor(coord[1], CHUNK_BLOCK_CNT), .z = @divFloor(coord[2], CHUNK_BLOCK_CNT) };
        const chunk = world.chunks.getPtr(key).?;
        const stored = &chunk.chunkData.block.blocks[@intCast(@mod(coord[2], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[1], CHUNK_BLOCK_CNT))][@intCast(@mod(coord[0], CHUNK_BLOCK_CNT))];
        const vb = stored.blockData.voxel;
        const header_index = world.voxel_block_headers_cpu.items.len;
        try world.packBlockToGpu(stored);
        const header = world.voxel_block_headers_cpu.items[header_index];
        try std.testing.expectEqualSlices(u32, &vb.occupance, world.bitmap_pool_cpu.items[header.bitmap_base..][0..vb.occupance.len]);
        for (0..BLOCK_VOXEL_CNT) |z| for (0..BLOCK_VOXEL_CNT) |y| for (0..BLOCK_VOXEL_CNT) |x| {
            try std.testing.expectEqual(@as(u32, vb.voxels[z][y][x]), world.index_pool_cpu.items[header.index_base + x + y * BLOCK_VOXEL_CNT + z * BLOCK_VOXEL_CNT * BLOCK_VOXEL_CNT]);
        };
        for (vb.pallete, 0..) |material, i| {
            try std.testing.expectEqual(World.packVoxelLo(material), world.palette_pool_cpu.items[header.palette_base + i * 2]);
            try std.testing.expectEqual(World.packVoxelHi(material), world.palette_pool_cpu.items[header.palette_base + i * 2 + 1]);
        }
        world.block_lights.clearRetainingCapacity();
        world.slot_keys[0] = key;
        try world.packChunkToGpu(0, chunk);
        try std.testing.expectEqual(@as(usize, 1), world.block_lights.items.len);
        for (0..3) |axis| try std.testing.expectEqual(@as(f32, @floatFromInt(target[axis])) + 0.5, world.block_lights.items[0].position[axis]);
        try std.testing.expect(try world.removeVoxel(target));
        try std.testing.expect(world.voxelAt(target) == null);
        try std.testing.expect(world.voxelAt(other) != null);
        try std.testing.expect(stored.light == null);
        try std.testing.expectEqual(@as(u32, 2), model.blockData.voxel.solid_count);
        try std.testing.expect(try world.removeVoxel(other));
        try std.testing.expect(world.blockIsEmpty(coord));
    }
}

test "queued procedural generation cannot overwrite a player edit" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    const key = World.ChunkKey{ .x = 0, .y = 0, .z = 0 };
    try world.inflight_set.put(key, {});
    try world.finished_chunks.append(.{ .key = key, .chunk = Chunk.initFree(0) });
    const model = Block.initMono(7, Voxel.rgb(200, 30, 40));
    try world.setBlock(.{ 0, 0, 0 }, &model);
    try world.drainFinishedChunks();
    try std.testing.expectEqual(@as(u8, 200), world.voxelAt(.{ 0, 0, 0 }).?.r);
    try std.testing.expect(world.ready_set.contains(key));
    try std.testing.expect(!world.inflight_set.contains(key));
}

test "voxel deletion expands uniform terrain without damaging neighbors" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    const key = World.ChunkKey{ .x = -1, .y = -1, .z = -1 };
    const color = Voxel.rgb(90, 120, 150);
    try world.chunks.put(key, Chunk.initMono(0, color));
    try std.testing.expect(try world.removeVoxel(.{ -1, -1, -1 }));
    try std.testing.expect(world.voxelAt(.{ -1, -1, -1 }) == null);
    try std.testing.expectEqual(color, world.voxelAt(.{ -2, -1, -1 }).?);
    try std.testing.expectEqual(color, world.voxelAt(.{ -17, -1, -1 }).?);
    const bc = world.chunks.getPtr(key).?.chunkData.block;
    try std.testing.expectEqual(@as(u32, CHUNK_BLOCK_TOTAL), bc.solid_count);
    try std.testing.expectEqual(@as(u32, 4095), bc.blocks[15][15][15].blockData.voxel.solid_count);
    // Deleting another mono block inside the already expanded chunk also works.
    try std.testing.expect(try world.removeVoxel(.{ -17, -1, -1 }));
    try std.testing.expect(world.voxelAt(.{ -17, -1, -1 }) == null);
    try std.testing.expectEqual(color, world.voxelAt(.{ -18, -1, -1 }).?);
    try std.testing.expect(!try world.removeVoxel(.{ -1, -1, -1 }));
    try std.testing.expect(!try world.removeVoxel(.{ 9999, 9999, 9999 }));
    const hit = world.raycast(.{ -0.5, 5, -0.5 }, .{ 0, -1, 0 }, 16).?;
    try std.testing.expectEqual([3]i32{ -1, -2, -1 }, hit.voxel);
    try std.testing.expect(world.dirty_chunks.items.len > 0);
}

test "voxel deletion preserves palette and instances, last deletion frees the block" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    var model = try Block.initVoxel(a, 14);
    defer model.deinit(a);
    model.blockData.voxel.setPaletteEntry(1, Voxel.rgb(255, 255, 255));
    model.blockData.voxel.setPaletteEntry(2, Voxel.rgb(0, 0, 0));
    model.blockData.voxel.setVoxel(0, 0, 0, 1);
    model.blockData.voxel.setVoxel(1, 0, 0, 2);
    try world.setBlock(.{ 0, 0, 0 }, &model);
    try world.setBlock(.{ 1, 0, 0 }, &model);
    try std.testing.expect(try world.removeVoxel(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 255), world.voxelAt(.{ 1, 0, 0 }).?.opacity);
    try std.testing.expectEqual(@as(u8, 0), world.voxelAt(.{ 1, 0, 0 }).?.r);
    try std.testing.expect(model.blockData.voxel.isOccupied(0, 0, 0));
    try std.testing.expect(world.voxelAt(.{ 16, 0, 0 }) != null);
    try std.testing.expect(try world.removeVoxel(.{ 1, 0, 0 }));
    try std.testing.expect(world.blockIsEmpty(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u32, 1), world.chunks.getPtr(.{ .x = 0, .y = 0, .z = 0 }).?.chunkData.block.solid_count);
}

test "fully transparent glass remains occupied, pickable and packed" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    var glass = Block.initMono(0, Voxel.rgb(255, 100, 100));
    glass.blockData.mono.opacity = 0;
    glass.blockData.mono.refractive_index = Voxel.encodeIor(1.5);
    try world.setBlock(.{ 0, 0, 0 }, &glass);
    try std.testing.expect(!world.blockIsEmpty(.{ 0, 0, 0 }));
    try std.testing.expect(world.raycast(.{ 8, 8, 32 }, .{ 0, 0, -1 }, 64) != null);
    try std.testing.expectEqual(glass.blockData.mono.refractive_index, @as(u8, @intCast(World.packVoxelLo(glass.blockData.mono) >> 24)));
}

test "streamed air does not dirty GPU geometry or invalidate lighting" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    try world.finished_chunks.append(.{ .key = .{ .x = 0, .y = 1, .z = 0 }, .chunk = Chunk.initFree(0) });
    try world.drainFinishedChunks();
    try std.testing.expectEqual(@as(usize, 0), world.dirty_chunks.items.len);
    try std.testing.expect(world.blockIsEmpty(.{ 0, 16, 0 }));
    try world.finished_chunks.append(.{ .key = .{ .x = 1, .y = 1, .z = 0 }, .chunk = Chunk.initMono(0, Voxel.rgb(255, 255, 255)) });
    try world.drainFinishedChunks();
    try std.testing.expectEqual(@as(usize, 1), world.dirty_chunks.items.len);
}

test "generation delivery is budgeted and preserves pending chunks" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    world.generation_budget = 1;
    for (0..3) |x| try world.finished_chunks.append(.{
        .key = .{ .x = @intCast(x), .y = 2, .z = 0 },
        .chunk = Chunk.initFree(0),
    });
    for (0..3) |i| {
        try world.drainFinishedChunks();
        try std.testing.expectEqual(2 - i, world.finished_chunks.items.len);
        try std.testing.expectEqual(i + 1, world.chunks.count());
    }
}

test "derived hierarchy rebuilds all ancestors after a negative-coordinate edit" {
    var world = try World.initCpu(std.testing.allocator);
    defer world.deinit() catch unreachable;
    var block = try Block.initVoxel(std.testing.allocator, 9);
    defer block.deinit(std.testing.allocator);
    block.blockData.voxel.setPaletteEntry(1, Voxel.rgb(255, 255, 255));
    block.blockData.voxel.setVoxel(15, 15, 15, 1);
    try world.setBlock(.{ -1, 0, -1 }, &block);
    const key = World.ChunkKey{ .x = -1, .y = 0, .z = -1 };
    world.slot_keys[0] = key;
    try world.packChunkToGpu(0, world.chunks.getPtr(key).?);
    var root = world.readSummary(world.chunk_headers_cpu[0].data2);
    try std.testing.expectEqual(@as(u32, 1), root.occupied);
    try std.testing.expectEqual(@as(u32, hierarchy.mixed), root.flags & 3);
    _ = try world.removeVoxel(.{ -1, 15, -1 });
    try world.packChunkToGpu(0, world.chunks.getPtr(key).?);
    root = world.readSummary(world.chunk_headers_cpu[0].data2);
    try std.testing.expectEqual(@as(u32, 0), root.occupied);
    try std.testing.expectEqual(@as(u32, hierarchy.empty), root.flags & 3);
}

test "terrain queries defer proxies and edits survive replacement and eviction" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    try world.enableTerrain(.{ .flat = true, .base_height = -3 });
    const stream = world.terrain_stream.?;
    var focus = render_policy.FocusState{};
    const snapshot = try focus.resolve(render_policy.terrain_settings, .{ -8, 0, -8 });
    stream.update(snapshot, snapshot.focus);
    const batch = try a.create(terrain_streaming.Batch);
    batch.* = .{ .request = stream.request.?, .config_revision = 1, .coarse = false };
    stream.resident = batch;
    var sampler = try terrain_generator.Sampler.init(a, stream.config);
    defer sampler.deinit();
    var builder = try terrain.Builder.init(a, -256, -256, snapshot, 1, 2 * 1024 * 1024);
    defer builder.deinit();
    while (!try builder.advance(&sampler, 4096, std.time.ns_per_s)) {}
    const index: usize = @intCast((-1 - batch.request.origin[0]) + (-1 - batch.request.origin[1]) * STREAM_CHUNKS_XZ);
    batch.tiles[index] = try builder.finish(1);
    batch.ready[index] = true;
    try std.testing.expect(world.queryVoxel(.{ -1, -4, -1 }) == .solid);
    try std.testing.expect(world.queryVoxel(.{ -1, -3, -1 }) == .air);
    try std.testing.expect(world.queryVoxel(.{ 10000, 0, 10000 }) == .unavailable);
    try std.testing.expectError(error.TerrainUnavailable, world.raycastChecked(.{ 10000, 0, 10000 }, .{ 0, -1, 0 }, 16));
    const hit = (try world.raycastChecked(.{ -0.5, 5, -0.5 }, .{ 0, -1, 0 }, 16)).?;
    try std.testing.expectEqual([3]i32{ -1, -4, -1 }, hit.voxel);
    try std.testing.expect(try world.removeVoxel(.{ -1, -4, -1 }));
    try std.testing.expect(world.queryVoxel(.{ -1, -4, -1 }) == .air);
    try std.testing.expect(world.queryVoxel(.{ -2, -4, -1 }) == .solid);
    batch.deinit(a);
    stream.resident = null;
    try std.testing.expect(world.queryVoxel(.{ -1, -4, -1 }) == .air);
    try std.testing.expect(world.queryVoxel(.{ -2, -4, -1 }) == .solid);
    try std.testing.expect(world.queryVoxel(.{ -17, -4, -1 }) == .unavailable);
    const model = Block.initMono(0, Voxel.rgb(1, 2, 3));
    try std.testing.expectError(error.TerrainUnavailable, world.setBlock(.{ 100, 0, 100 }, &model));
    try std.testing.expectEqual(@as(usize, 1), world.chunks.count());
}

test "capture readiness excludes intermediate terrain, stale requests and pending publication" {
    const a = std.testing.allocator;
    var world = try World.initCpu(a);
    defer world.deinit() catch unreachable;
    try world.enableTerrain(.{ .flat = true });
    try std.testing.expect(!world.captureReady());
    var focus = render_policy.FocusState{};
    const snapshot = try focus.resolve(render_policy.terrain_settings, .{ 0, 32, 0 });
    const stream = world.terrain_stream.?;
    stream.update(snapshot, snapshot.focus);
    const batch = try a.create(terrain_streaming.Batch);
    batch.* = .{ .request = stream.request.?, .config_revision = 1, .coarse = true };
    stream.resident = batch;
    world.gpu_region_valid = true;
    world.upload_config_revision = 1;
    world.upload_terrain_token = batch.request.token;
    world.terrain_dirty = false;
    try std.testing.expect(!world.captureReady());
    batch.coarse = false;
    try std.testing.expect(world.captureReady());
    world.upload_active = true;
    try std.testing.expect(!world.captureReady());
    world.upload_active = false;
    world.terrain_edit_revision += 1;
    try std.testing.expect(!world.captureReady());
    world.upload_edit_revision = world.terrain_edit_revision;
    try std.testing.expect(world.captureReady());
    stream.request.?.token += 1;
    try std.testing.expect(!world.captureReady());
}
