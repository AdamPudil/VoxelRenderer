const std = @import("std");
const side = @import("worldConstants.zig").BLOCK_VOXEL_CNT;

pub const Mode = enum { none, yaw };

/// Direction of the authored +Z front after rotation about world Y.
pub const Orientation = enum {
    positive_z,
    positive_x,
    negative_z,
    negative_x,

    pub fn voxel(self: Orientation, p: [3]usize) [3]usize {
        return switch (self) {
            .positive_z => p,
            .positive_x => .{ p[2], p[1], side - 1 - p[0] },
            .negative_z => .{ side - 1 - p[0], p[1], side - 1 - p[2] },
            .negative_x => .{ side - 1 - p[2], p[1], p[0] },
        };
    }

    /// Continuous positions rotate about side/2, not the voxel index center.
    pub fn point(self: Orientation, p: [3]f32) [3]f32 {
        return switch (self) {
            .positive_z => p,
            .positive_x => .{ p[2], p[1], side - p[0] },
            .negative_z => .{ side - p[0], p[1], side - p[2] },
            .negative_x => .{ side - p[2], p[1], p[0] },
        };
    }
};

/// Face the player. Yaw follows main.zig: zero looks +Z, pi/2 looks +X.
pub fn forPlacement(mode: Mode, forward: [3]f32, yaw: f32) Orientation {
    if (mode == .none) return .positive_z;
    var x = forward[0];
    var z = forward[2];
    if (x * x + z * z < 1e-12) {
        x = @sin(yaw);
        z = @cos(yaw);
    }
    if (@abs(x) > @abs(z)) return if (x > 0) .negative_x else .positive_x;
    return if (z > 0) .negative_z else .positive_z;
}

test "placement faces the player, resolves diagonals and retains heading at vertical views" {
    const Case = struct { forward: [3]f32, expected: Orientation };
    for ([_]Case{
        .{ .forward = .{ 0, 0, 1 }, .expected = .negative_z },
        .{ .forward = .{ 1, 0, 0 }, .expected = .negative_x },
        .{ .forward = .{ 0, 0, -1 }, .expected = .positive_z },
        .{ .forward = .{ -1, 0, 0 }, .expected = .positive_x },
        .{ .forward = .{ 1, 0, 1 }, .expected = .negative_z },
        .{ .forward = .{ -1, 0, -1 }, .expected = .positive_z },
        .{ .forward = .{ 1, 0, -1 }, .expected = .positive_z },
        .{ .forward = .{ -1, 0, 1 }, .expected = .negative_z },
        .{ .forward = .{ 1.001, 0, 1 }, .expected = .negative_x },
        .{ .forward = .{ 0.999, 0, 1 }, .expected = .negative_z },
    }) |case| {
        try std.testing.expectEqual(case.expected, forPlacement(.yaw, case.forward, 0));
        try std.testing.expectEqual(Orientation.positive_z, forPlacement(.none, case.forward, 0));
    }
    try std.testing.expectEqual(Orientation.negative_x, forPlacement(.yaw, .{ 0, 1, 0 }, std.math.pi / 2.0));
    try std.testing.expectEqual(Orientation.positive_x, forPlacement(.yaw, .{ 1e-8, -1, 1e-8 }, -std.math.pi / 2.0));
}
