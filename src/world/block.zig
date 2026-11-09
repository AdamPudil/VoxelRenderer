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
    light: ?@import("../lighting.zig").PointLight = null,

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

    pub fn clone(self: *const Block, allocator: std.mem.Allocator) !Block {
        var copy = self.*;
        if (self.blockData == .voxel) {
            const ptr = try allocator.create(VoxelBlock);
            ptr.* = self.blockData.voxel.*;
            copy.blockData = .{ .voxel = ptr };
        }
        return copy;
    }

    /// Bake orientation into a private copy; all world consumers use these voxels.
    pub fn cloneOriented(self: *const Block, allocator: std.mem.Allocator, orientation: @import("blockRotation.zig").Orientation) !Block {
        if (orientation == .positive_z) return self.clone(allocator);
        var copy = self.*;
        if (self.blockData == .voxel) {
            const source = self.blockData.voxel;
            const dest = try allocator.create(VoxelBlock);
            dest.* = VoxelBlock.initEmpty();
            dest.pallete = source.pallete;
            for (0..VOXEL_CNT) |z| for (0..VOXEL_CNT) |y| for (0..VOXEL_CNT) |x| {
                if (source.getVoxelPaletteIndex(x, y, z)) |index| {
                    const p = orientation.voxel(.{ x, y, z });
                    dest.setVoxel(p[0], p[1], p[2], index);
                }
            };
            dest.dirty = true;
            copy.blockData = .{ .voxel = dest };
        }
        if (copy.light) |*light| light.position = orientation.point(light.position);
        return copy;
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        switch (self.blockData) {
            .voxel => |ptr| allocator.destroy(ptr),
            else => {},
        }
    }

    pub fn setFree(self: *Block, allocator: std.mem.Allocator, blockID: u32) void {
        self.deinit(allocator);
        self.light = null;
        self.blockID = blockID;
        self.blockData = .{ .free = {} };
    }

    pub fn setMono(self: *Block, allocator: std.mem.Allocator, blockID: u32, voxel: Voxel) void {
        self.deinit(allocator);
        self.light = null;
        self.blockID = blockID;
        self.blockData = .{ .mono = voxel };
    }

    pub fn setVoxel(self: *Block, allocator: std.mem.Allocator, blockID: u32) !void {
        self.deinit(allocator);

        const ptr = try allocator.create(VoxelBlock);
        ptr.* = VoxelBlock.initEmpty();

        self.light = null;
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

test "rotated clones preserve asymmetric geometry, materials and lights" {
    const a = std.testing.allocator;
    const Orientation = @import("blockRotation.zig").Orientation;
    var source = try Block.initVoxel(a, 42);
    defer source.deinit(a);
    const vb = source.blockData.voxel;
    vb.setPaletteEntry(1, Voxel.rgb(20, 40, 60));
    vb.setPaletteEntry(2, Voxel.getVoxel(90, 80, 70, 12, 100, 200, 30));
    vb.setVoxel(1, 2, 3, 1);
    vb.setVoxel(4, 5, 6, 2);
    source.light = .{ .position = .{ 1.5, 2.5, 3.5 } };
    const first = [_][3]usize{ .{ 1, 2, 3 }, .{ 3, 2, 14 }, .{ 14, 2, 12 }, .{ 12, 2, 1 } };
    const second = [_][3]usize{ .{ 4, 5, 6 }, .{ 6, 5, 11 }, .{ 11, 5, 9 }, .{ 9, 5, 4 } };
    for (std.enums.values(Orientation), first, second) |orientation, p, q| {
        var copy = try source.cloneOriented(a, orientation);
        defer copy.deinit(a);
        const dest = copy.blockData.voxel;
        try std.testing.expect(dest != vb);
        try std.testing.expectEqual(@as(u32, 42), copy.blockID);
        try std.testing.expectEqualSlices(Voxel, &vb.pallete, &dest.pallete);
        try std.testing.expectEqual(@as(u32, 2), dest.solid_count);
        try std.testing.expect(dest.dirty);
        for (0..VOXEL_CNT) |z| for (0..VOXEL_CNT) |y| for (0..VOXEL_CNT) |x| {
            const index: ?u8 = if (x == p[0] and y == p[1] and z == p[2]) 1 else if (x == q[0] and y == q[1] and z == q[2]) 2 else null;
            try std.testing.expectEqual(index, dest.getVoxelPaletteIndex(x, y, z));
        };
        var expected_light = source.light.?;
        for (0..3) |axis| expected_light.position[axis] = @as(f32, @floatFromInt(p[axis])) + 0.5;
        try std.testing.expectEqualDeep(expected_light, copy.light.?);
        dest.clearVoxel(p[0], p[1], p[2]);
        try std.testing.expectEqual(@as(u32, 2), vb.solid_count);
    }
    var cycle = try source.clone(a);
    defer cycle.deinit(a);
    for (0..4) |_| {
        const next = try cycle.cloneOriented(a, .positive_x);
        cycle.deinit(a);
        cycle = next;
    }
    try std.testing.expectEqualDeep(vb.*, cycle.blockData.voxel.*);
    try std.testing.expectEqualDeep(source.light, cycle.light);
    var mono = Block.initMono(7, Voxel.rgb(10, 20, 30));
    mono.light = source.light;
    var rotated_mono = try mono.cloneOriented(a, .negative_x);
    defer rotated_mono.deinit(a);
    try std.testing.expectEqual(mono.blockData.mono, rotated_mono.blockData.mono);
    try std.testing.expectEqual([3]f32{ 12.5, 2.5, 1.5 }, rotated_mono.light.?.position);
    const empty = Block.initEmpty(0);
    var rotated_empty = try empty.cloneOriented(a, .positive_x);
    defer rotated_empty.deinit(a);
    try std.testing.expect(rotated_empty.isFree());
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(allocator: std.mem.Allocator, model: *const Block) !void {
            for (std.enums.values(Orientation)) |orientation| {
                var copy = try model.cloneOriented(allocator, orientation);
                defer copy.deinit(allocator);
            }
        }
    }.run, .{&source});
}
