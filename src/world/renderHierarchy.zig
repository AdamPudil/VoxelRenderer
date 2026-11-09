//! Derived summaries; authoritative assets/edits remain in their original storage.
const std = @import("std");
const Voxel = @import("voxel.zig").Voxel;
const policy = @import("../rendering.zig");
pub const children = policy.children;
pub const empty = 0;
pub const uniform = 1;
pub const mixed = 2;
pub const opaque_flag = 4;
pub const transmitting = 8;
pub const emissive = 16;

/// Four R32UI words, shared with hierarchy.glsl. Count is exact, never sampled.
/// Flags classify exact contents separately from the representative material.
pub const Summary = extern struct {
    flags: u32 = empty,
    lo: u32 = 0,
    hi: u32 = 0,
    occupied: u32 = 0,

    pub fn material(v: Voxel, count: u32) Summary {
        if (v.isEmpty()) return .{};
        const bits: u64 = @bitCast(v);
        return .{ .flags = uniform | (if (v.opacity == 255) @as(u32, opaque_flag) else transmitting) | (if (v.luminescence > 0) @as(u32, emissive) else 0), .lo = @truncate(bits), .hi = @truncate(bits >> 32), .occupied = count };
    }

    pub fn combine(nodes: []const Summary, child_volume: u32) Summary {
        var result = Summary{};
        var first: ?Summary = null;
        var same = true;
        var best: u32 = 0;
        for (nodes) |node| {
            result.occupied += node.occupied;
            result.flags |= node.flags & ~@as(u32, 3);
            if (node.occupied > best) {
                best = node.occupied;
                result.lo = node.lo;
                result.hi = node.hi;
            }
            if (node.flags & 3 != uniform or node.occupied != child_volume) same = false;
            if (node.occupied > 0) {
                if (first) |f| {
                    if (f.lo != node.lo or f.hi != node.hi) same = false;
                } else first = node;
            }
        }
        result.flags |= if (result.occupied == 0) @as(u32, empty) else if (same) @as(u32, uniform) else mixed;
        return result;
    }

    pub fn canApproximate(self: Summary, volume: u32) bool {
        return self.occupied == volume and self.flags & (transmitting | emissive) == 0;
    }
};

pub fn voxelNodes(vb: *const @import("block.zig").VoxelBlock) [children]Summary {
    var nodes: [children]Summary = undefined;
    for (0..4) |z| for (0..4) |y| for (0..4) |x| {
        var leaves: [children]Summary = undefined;
        for (0..4) |dz| for (0..4) |dy| for (0..4) |dx| {
            leaves[dx + 4 * dy + 16 * dz] = if (vb.getVoxel(x * 4 + dx, y * 4 + dy, z * 4 + dz)) |v| Summary.material(v, 1) else .{};
        };
        nodes[x + 4 * y + 16 * z] = Summary.combine(&leaves, 1);
    };
    return nodes;
}

test "summary never loses thin geometry, glass or small emitters" {
    var leaves = [_]Summary{.{}} ** children;
    leaves[63] = Summary.material(Voxel.rgb(1, 2, 3), 1);
    var s = Summary.combine(&leaves, 1);
    try std.testing.expectEqual(@as(u32, mixed), s.flags & 3);
    try std.testing.expectEqual(@as(u32, 1), s.occupied);
    try std.testing.expect(!s.canApproximate(64));
    @memset(&leaves, leaves[63]);
    s = Summary.combine(&leaves, 1);
    try std.testing.expectEqual(@as(u32, uniform), s.flags & 3);
    leaves[0] = Summary.material(Voxel.rgb(3, 2, 1), 1);
    s = Summary.combine(&leaves, 1);
    try std.testing.expectEqual(@as(u32, mixed), s.flags & 3);
    try std.testing.expect(s.canApproximate(64));
    var glass = Voxel.rgb(1, 2, 3);
    glass.opacity = 0;
    glass.refractive_index = Voxel.encodeIor(1.5);
    leaves[0] = Summary.material(glass, 1);
    try std.testing.expect(!Summary.combine(&leaves, 1).canApproximate(64));
    glass = Voxel.rgb(1, 2, 3);
    glass.luminescence = 1;
    leaves[0] = Summary.material(glass, 1);
    try std.testing.expect(!Summary.combine(&leaves, 1).canApproximate(64));
}
