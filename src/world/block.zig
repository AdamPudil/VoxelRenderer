const std = @import("std");
const Voxel = @import("voxel.zig").Voxel;

const worldConst = @import("worldConstants.zig");

const VOXEL_CNT = worldConst.BLOCK_VOXEL_CNT;
// should throw error when not exact, bigger powers of two should always multiply to be divisible...
const OCCUPANCY_SIZE = @divExact(VOXEL_CNT * VOXEL_CNT * VOXEL_CNT, 32); // 32 bits in u32
const PALLETE_SIZE = worldConst.BLOCK_PALLETE_SIZE;

pub const BlockKind = enum {
    free,
    mono,
    voxel,
};

pub const BlockU = union(BlockKind) {
    free: void,
    mono: Voxel,
    voxel: *VoxelBlock,
};

pub const VoxelBlock = struct {
    occupance: [OCCUPANCY_SIZE]u32,
    voxels: [VOXEL_CNT][VOXEL_CNT][VOXEL_CNT]u8,
    pallete: [PALLETE_SIZE]Voxel,
    solid_count: u32,
    dirty: bool,

    pub fn initEmpty() VoxelBlock {
        return .{
            .occupance = [_]u32{0} ** OCCUPANCY_SIZE,
            .voxels = [_][VOXEL_CNT][VOXEL_CNT]u8{[_][VOXEL_CNT]u8{[_]u8{0} ** VOXEL_CNT} ** VOXEL_CNT} ** VOXEL_CNT,
            .pallete = [_]Voxel{std.mem.zeroes(Voxel)} ** PALLETE_SIZE,
            .solid_count = 0,
            .dirty = false,
        };
    }

    pub inline fn voxelIndex(x: usize, y: usize, z: usize) usize {
        return x + y * VOXEL_CNT + z * VOXEL_CNT * VOXEL_CNT;
    }

    pub inline fn occupancyWordIndex(index: usize) usize {
        return index >> 5;
    }

    pub inline fn occupancyBitIndex(index: usize) u5 {
        return @intCast(index & 31);
    }

    pub fn isOccupied(self: *const VoxelBlock, x: usize, y: usize, z: usize) bool {
        const index = voxelIndex(x, y, z);
        const wi = occupancyWordIndex(index);
        const bi = occupancyBitIndex(index);
        return ((self.occupance[wi] >> bi) & 1) != 0;
    }

    pub fn setPaletteEntry(self: *VoxelBlock, index: u8, voxel: Voxel) void {
        self.pallete[index] = voxel;
        self.dirty = true;
    }

    pub fn getPaletteEntry(self: *const VoxelBlock, index: u8) Voxel {
        return self.pallete[index];
    }

    pub fn setVoxel(self: *VoxelBlock, x: usize, y: usize, z: usize, palette_index: u8) void {
        const index = voxelIndex(x, y, z);
        const wi = occupancyWordIndex(index);
        const bi = occupancyBitIndex(index);
        const mask = @as(u32, 1) << bi;

        if ((self.occupance[wi] & mask) == 0) {
            self.occupance[wi] |= mask;
            self.solid_count += 1;
        }

        self.voxels[z][y][x] = palette_index;
        self.dirty = true;
    }

    pub fn clearVoxel(self: *VoxelBlock, x: usize, y: usize, z: usize) void {
        const index = voxelIndex(x, y, z);
        const wi = occupancyWordIndex(index);
        const bi = occupancyBitIndex(index);
        const mask = @as(u32, 1) << bi;

        if ((self.occupance[wi] & mask) != 0) {
            self.occupance[wi] &= ~mask;
            self.voxels[z][y][x] = 0;
            self.solid_count -= 1;
            self.dirty = true;
        }
    }

    pub fn getVoxelPaletteIndex(self: *const VoxelBlock, x: usize, y: usize, z: usize) ?u8 {
        if (!self.isOccupied(x, y, z)) return null;
        return self.voxels[z][y][x];
    }

    pub fn getVoxel(self: *const VoxelBlock, x: usize, y: usize, z: usize) ?Voxel {
        if (!self.isOccupied(x, y, z)) return null;
        return self.pallete[self.voxels[z][y][x]];
    }

    pub fn clearAll(self: *VoxelBlock) void {
        self.occupance = [_]u32{0} ** OCCUPANCY_SIZE;
        self.voxels = [_][VOXEL_CNT][VOXEL_CNT]u8{[_][VOXEL_CNT]u8{[_]u8{0} ** VOXEL_CNT} ** VOXEL_CNT} ** VOXEL_CNT;
        self.solid_count = 0;
        self.dirty = true;
    }

    pub fn recountSolid(self: *VoxelBlock) void {
        var count: u32 = 0;

        for (0..VOXEL_CNT) |z| {
            for (0..VOXEL_CNT) |y| {
                for (0..VOXEL_CNT) |x| {
                    if (self.isOccupied(x, y, z)) count += 1;
                }
            }
        }

        self.solid_count = count;
    }

    pub fn clearDirty(self: *VoxelBlock) void {
        self.dirty = false;
    }
};

pub const Block = struct {
    blockID: u32,
    blockData: BlockU,

    pub fn initEmpty(blockID: u32) Block {
        return .{
            .blockID = blockID,
            .blockData = .{ .free = {} },
        };
    }

    pub fn initMono(blockID: u32, voxel: Voxel) Block {
        return .{
            .blockID = blockID,
            .blockData = .{ .mono = voxel },
        };
    }

    pub fn initVoxel(allocator: std.mem.Allocator, blockID: u32) !Block {
        const ptr = try allocator.create(VoxelBlock);
        ptr.* = VoxelBlock.initEmpty();

        return .{
            .blockID = blockID,
            .blockData = .{ .voxel = ptr },
        };
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        switch (self.blockData) {
            .voxel => |ptr| allocator.destroy(ptr),
            else => {},
        }
    }

    pub fn setFree(self: *Block, allocator: std.mem.Allocator, blockID: u32) void {
        self.deinit(allocator);
        self.blockID = blockID;
        self.blockData = .{ .free = {} };
    }

    pub fn setMono(self: *Block, allocator: std.mem.Allocator, blockID: u32, voxel: Voxel) void {
        self.deinit(allocator);
        self.blockID = blockID;
        self.blockData = .{ .mono = voxel };
    }

    pub fn setVoxel(self: *Block, allocator: std.mem.Allocator, blockID: u32) !void {
        self.deinit(allocator);

        const ptr = try allocator.create(VoxelBlock);
        ptr.* = VoxelBlock.initEmpty();

        self.blockID = blockID;
        self.blockData = .{ .voxel = ptr };
    }

    pub fn kind(self: *const Block) BlockKind {
        return std.meta.activeTag(self.blockData);
    }

    pub fn isFree(self: *const Block) bool {
        return self.kind() == .free;
    }

    pub fn isMono(self: *const Block) bool {
        return self.kind() == .mono;
    }

    pub fn isVoxel(self: *const Block) bool {
        return self.kind() == .voxel;
    }

    pub fn getMono(self: *const Block) ?Voxel {
        return switch (self.blockData) {
            .mono => |v| v,
            else => null,
        };
    }

    pub fn getVoxelBlock(self: *Block) ?*VoxelBlock {
        return switch (self.blockData) {
            .voxel => |ptr| ptr,
            else => null,
        };
    }

    pub fn getVoxelBlockConst(self: *const Block) ?*const VoxelBlock {
        return switch (self.blockData) {
            .voxel => |ptr| ptr,
            else => null,
        };
    }
};

//pub fn Block(comptime SIZE: usize) type {
//   return struct {
//       const Self = @This();
//       const VOXEL_COUNT = SIZE * SIZE * SIZE;
//       const BIT_WORDS = (VOXEL_COUNT + 31) / 32;
//
//       voxels: []Voxel,
//       occupancy: []u32,
//       solid_count: u32,
//       dirty: bool,
//       allocator: std.mem.Allocator,
//
//       pub fn init(allocator: std.mem.Allocator) !Self {
//           const voxels = try allocator.alloc(Voxel, VOXEL_COUNT);
//           errdefer allocator.free(voxels);
//
//           const occupancy = try allocator.alloc(u32, BIT_WORDS);
//           errdefer allocator.free(occupancy);
//
//           @memset(voxels, Voxel.empty());
//           @memset(occupancy, 0);
//
//           return .{
//               .voxels = voxels,
//               .occupancy = occupancy,
//               .solid_count = 0,
//               .dirty = false,
//               .allocator = allocator,
//           };
//       }
//
//       pub fn deinit(self: *Self) void {
//           self.allocator.free(self.voxels);
//           self.allocator.free(self.occupancy);
//       }
//
//       inline fn index(x: usize, y: usize, z: usize) usize {
//           return x + y * SIZE + z * SIZE * SIZE;
//       }
//
//       inline fn bitPos(i: usize) struct { word: usize, bit: u5 } {
//           return .{ .word = i >> 5, .bit = @intCast(i & 31) };
//       }
//
//       pub fn getVoxel(self: *const Self, x: usize, y: usize, z: usize) Voxel {
//           return self.voxels[index(x, y, z)];
//       }
//
//       pub fn setVoxel(self: *Self, x: usize, y: usize, z: usize, v: Voxel) void {
//           const i = index(x, y, z);
//           const p = bitPos(i);
//           const mask: u32 = (@as(u32, 1) << p.bit);
//
//           const was_solid = (self.occupancy[p.word] & mask) != 0;
//           const solid = !v.isEmpty();
//
//           self.voxels[i] = v;
//
//           if (solid) {
//               if (!was_solid) {
//                   self.occupancy[p.word] |= mask;
//                   self.solid_count += 1;
//               }
//           } else {
//               if (was_solid) {
//                   self.occupancy[p.word] &= ~mask;
//                   self.solid_count -= 1;
//               }
//           }
//
//           self.dirty = true;
//       }
//   };
//}
