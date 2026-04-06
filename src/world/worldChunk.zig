const std = @import("std");
const Block = @import("block.zig").Block;
const Voxel = @import("voxel.zig").Voxel;

const worldConst = @import("worldConstants.zig");

const CHUNK_BLOCK_CNT = worldConst.CHUNK_BLOCK_CNT;
const CHUNK_BLOCK_TOTAL = worldConst.CHUNK_BLOCK_TOTAL;

pub const ChunkKind = enum {
    free,
    mono,
    block,
};

pub const BlockChunk = struct {
    blocks: [CHUNK_BLOCK_CNT][CHUNK_BLOCK_CNT][CHUNK_BLOCK_CNT]Block,
    solid_count: u32,
    dirty: bool,

    pub fn initFree() BlockChunk {
        var ret: BlockChunk = undefined;
        ret.solid_count = 0;
        ret.dirty = false;

        for (0..CHUNK_BLOCK_CNT) |z| {
            for (0..CHUNK_BLOCK_CNT) |y| {
                for (0..CHUNK_BLOCK_CNT) |x| {
                    ret.blocks[z][y][x] = Block.initEmpty(0);
                }
            }
        }

        return ret;
    }

    pub fn deinit(self: *BlockChunk, allocator: std.mem.Allocator) void {
        for (0..CHUNK_BLOCK_CNT) |z| {
            for (0..CHUNK_BLOCK_CNT) |y| {
                for (0..CHUNK_BLOCK_CNT) |x| {
                    self.blocks[z][y][x].deinit(allocator);
                }
            }
        }
    }
};

pub const ChunkU = union(ChunkKind) {
    free: void,
    mono: Voxel, // blockID
    block: *BlockChunk,
};

pub const Chunk = struct {
    chunkID: u32,
    chunkData: ChunkU,

    pub fn initFree(chunkID: u32) Chunk {
        return .{
            .chunkID = chunkID,
            .chunkData = .{ .free = {} },
        };
    }

    pub fn initMono(chunkID: u32, blockID: Voxel) Chunk {
        return .{
            .chunkID = chunkID,
            .chunkData = .{ .mono = blockID },
        };
    }

    pub fn initBlock(allocator: std.mem.Allocator, chunkID: u32) !Chunk {
        const ptr = try allocator.create(BlockChunk);
        ptr.* = BlockChunk.initFree();

        return .{
            .chunkID = chunkID,
            .chunkData = .{ .block = ptr },
        };
    }

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        switch (self.chunkData) {
            .block => |ptr| {
                ptr.deinit(allocator);
                allocator.destroy(ptr);
            },
            else => {},
        }
    }

    pub fn setFree(self: *Chunk, allocator: std.mem.Allocator, chunkID: u32) void {
        self.deinit(allocator);
        self.chunkID = chunkID;
        self.chunkData = .{ .free = {} };
    }

    pub fn setMono(self: *Chunk, allocator: std.mem.Allocator, chunkID: u32, blockID: u32) void {
        self.deinit(allocator);
        self.chunkID = chunkID;
        self.chunkData = .{ .mono = blockID };
    }

    pub fn setBlock(self: *Chunk, allocator: std.mem.Allocator, chunkID: u32) !void {
        self.deinit(allocator);

        const ptr = try allocator.create(BlockChunk);
        ptr.* = BlockChunk.initFree();

        self.chunkID = chunkID;
        self.chunkData = .{ .block = ptr };
    }

    pub fn kind(self: *const Chunk) ChunkKind {
        return std.meta.activeTag(self.chunkData);
    }

    pub fn isFree(self: *const Chunk) bool {
        return self.kind() == .free;
    }

    pub fn isMono(self: *const Chunk) bool {
        return self.kind() == .mono;
    }

    pub fn isBlock(self: *const Chunk) bool {
        return self.kind() == .block;
    }

    pub fn getMono(self: *const Chunk) ?u32 {
        return switch (self.chunkData) {
            .mono => |blockID| blockID,
            else => null,
        };
    }

    pub fn getBlockChunk(self: *Chunk) ?*BlockChunk {
        return switch (self.chunkData) {
            .block => |ptr| ptr,
            else => null,
        };
    }

    pub fn getBlockChunkConst(self: *const Chunk) ?*const BlockChunk {
        return switch (self.chunkData) {
            .block => |ptr| ptr,
            else => null,
        };
    }

    pub fn recountSolid(self: *Chunk) void {
        switch (self.chunkData) {
            .free => {},
            .mono => {
                // if blockID 0 = air
                self.chunkData = .{ .mono = self.chunkData.mono };
            },
            .block => |ptr| {
                var count: u32 = 0;

                for (0..CHUNK_BLOCK_CNT) |z| {
                    for (0..CHUNK_BLOCK_CNT) |y| {
                        for (0..CHUNK_BLOCK_CNT) |x| {
                            if (!ptr.blocks[z][y][x].isFree()) count += 1;
                        }
                    }
                }

                ptr.solid_count = count;
            },
        }
    }
};
