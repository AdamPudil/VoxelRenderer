const std = @import("std");
const Chunk = @import("worldChunk.zig").Chunk;
const BlockChunk = @import("worldChunk.zig").BlockChunk;
const Block = @import("block.zig").Block;
const VoxelBlock = @import("block.zig").VoxelBlock;
const Voxel = @import("voxel.zig").Voxel;
const wc = @import("worldConstants.zig");
const gl = @import("../graphics/gl.zig");

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

    chunks: std.AutoHashMap(ChunkKey, Chunk),
    dirty_chunks: std.ArrayList(ChunkKey),

    generator_thread: ?std.Thread = null,
    stream_mutex: std.Thread.Mutex = .{},
    stream_cv: std.Thread.Condition = .{},
    latest_cam_chunk: [3]i32 = .{ 0, 0, 0 },
    stop_generator: bool = false,

    ready_set: std.AutoHashMap(ChunkKey, void),
    inflight_set: std.AutoHashMap(ChunkKey, void),
    finished_chunks: std.ArrayList(FinishedChunk),

    gpu_region_origin_chunk: [3]i32 = .{ 0, 0, 0 },
    gpu_region_valid: bool = false,

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

        return self;
    }

    pub fn deinit(self: *Self) !void {
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
        return (@as(u32, v.r)) | (@as(u32, v.g) << 8) | (@as(u32, v.b) << 16) | (@as(u32, v.transparency) << 24);
    }

    fn packVoxelHi(v: Voxel) u32 {
        return (@as(u32, v.opacity)) | (@as(u32, v.reflectiveness) << 8) | (@as(u32, v.luminescence) << 16) | (@as(u32, v.padding) << 24);
    }

    // generation
    pub fn startGenerator(self: *Self) !void {
        if (self.generator_thread != null) return;
        self.generator_thread = try std.Thread.spawn(.{}, generatorMain, .{self});
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
        return dx * dx + dy * dy + dz * dz;
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
        std.mem.swap(std.ArrayList(FinishedChunk), &local_finished, &self.finished_chunks);
        self.stream_mutex.unlock();

        // The worker reads these sets under the same mutex.
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        for (local_finished.items) |*item| {
            const gop = try self.chunks.getOrPut(item.key);
            if (!gop.found_existing) {
                gop.value_ptr.* = item.chunk;
                try self.ready_set.put(item.key, {});
                try self.dirty_chunks.append(item.key);
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
            step[i] = if (dir > 0) 1 else if (dir < 0) -1 else 0;
            delta[i] = if (dir == 0) std.math.inf(f32) else @abs(1 / dir);
            const boundary = @as(f32, @floatFromInt(voxel[i] + @max(step[i], 0)));
            next[i] = if (dir == 0) std.math.inf(f32) else (boundary - origin[i]) / dir;
        }
        var normal = [3]i32{ 0, 0, 0 };
        var distance: f32 = 0;
        // A unit ray crosses at most sqrt(3) voxel planes per world unit.
        while (distance <= reach) {
            if (self.voxelAt(voxel) != null) return .{ .voxel = voxel, .normal = normal, .distance = distance };
            const axis: usize = if (next[0] < next[1] and next[0] < next[2]) 0 else if (next[1] < next[2]) 1 else 2;
            distance = next[axis];
            voxel[axis] += step[axis];
            next[axis] += delta[axis];
            normal = .{ 0, 0, 0 };
            normal[axis] = -step[axis];
        }
        return null;
    }

    pub fn blockIsEmpty(self: *const Self, coord: [3]i32) bool {
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
        vb.clearVoxel(@intCast(@mod(pos[0], BLOCK_VOXEL_CNT)), @intCast(@mod(pos[1], BLOCK_VOXEL_CNT)), @intCast(@mod(pos[2], BLOCK_VOXEL_CNT)));
        if (vb.solid_count == 0) edited.setFree(self.allocator, source.blockID);
        try self.setBlock(coord, &edited);
        return true;
    }

    /// coord is in 16-voxel block units. The world owns a deep copy of model.
    /// Converting a mono chunk preserves all its other blocks.
    pub fn setBlock(self: *Self, coord: [3]i32, model: *const Block) !void {
        var copy = try model.clone(self.allocator);
        errdefer copy.deinit(self.allocator);
        const key = ChunkKey{ .x = @divFloor(coord[0], CHUNK_BLOCK_CNT), .y = @divFloor(coord[1], CHUNK_BLOCK_CNT), .z = @divFloor(coord[2], CHUNK_BLOCK_CNT) };
        try self.dirty_chunks.ensureUnusedCapacity(1);
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        try self.ready_set.ensureUnusedCapacity(1);
        const gop = try self.chunks.getOrPut(key);
        if (!gop.found_existing) gop.value_ptr.* = try generateChunkStatic(self.allocator, key.x, key.y, key.z);
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
    }

    // pack for gpu
    fn rebuildGpuRegion(self: *Self, new_origin: [3]i32) !void {
        self.gpu_region_origin_chunk = new_origin;

        for (self.chunk_headers_cpu) |*h| {
            h.* = .{ .state = 0, .data0 = 0, .data1 = 0, .data2 = 0 };
        }

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

        try self.uploadWholeGpuState();
        self.gpu_region_valid = true;
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
                        }
                    }
                }

                self.chunk_headers_cpu[slot] = .{
                    .state = @intFromEnum(ChunkState.block),
                    .data0 = block_base,
                    .data1 = CHUNK_BLOCK_TOTAL,
                    .data2 = 0,
                };
            },
        }
    }

    fn packBlockToGpu(self: *Self, block: *Block) !void {
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

                try self.block_headers_cpu.append(.{
                    .state = @intFromEnum(BlockState.voxel),
                    .data0 = hdr_index,
                    .data1 = 0,
                    .data2 = 0,
                });
            },
        }
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
        try gl.bindBuffer(c.GL_TEXTURE_BUFFER, buf);
        try gl.bufferData(
            c.GL_TEXTURE_BUFFER,
            @intCast(data.len * @sizeOf(T)),
            if (data.len == 0) null else data.ptr,
            c.GL_DYNAMIC_DRAW,
        );
        gl.bindTexture(c.GL_TEXTURE_BUFFER, tex);
        try gl.texBuffer(c.GL_TEXTURE_BUFFER, c.GL_R32UI, buf);
    }

    // render
    pub fn render(self: *Self, cam_pos: [3]f32) !void {
        self.updateLatestCameraChunk(cam_pos);
        try self.drainFinishedChunks();

        const new_origin = computeRegionChunkOrigin(cam_pos);

        if (!self.gpu_region_valid or
            self.gpu_region_origin_chunk[0] != new_origin[0] or
            self.gpu_region_origin_chunk[1] != new_origin[1] or
            self.gpu_region_origin_chunk[2] != new_origin[2] or
            self.dirty_chunks.items.len > 0)
        {
            try self.rebuildGpuRegion(new_origin);
            self.dirty_chunks.clearRetainingCapacity();
        }
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
