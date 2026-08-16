const std = @import("std");

const vec = @import("../../../core/math/vector.zig");

const perlin = @import("perlin.zig");

pub fn hash(p: vec.Vec2f32) vec.Vec2f32 {
    var q: vec.Vec2f32 = vec.Vec2f32{
        .x = p.dot(
            vec.Vec2f32{ .x = 127.1, .y = 311.7 },
        ),
        .y = p.dot(
            vec.Vec2f32{ .x = 269.5, .y = 183.3 },
        ),
    };

    q.x = @sin(q.x);
    q.y = @sin(q.y);

    return q.scale(43758.5453).fract();
}

pub fn smoothVoronoi(x: i32, y: i32, gridSize: i32) f32 {
    const cell_x: i32 = @divFloor(x, gridSize);
    const cell_y: i32 = @divFloor(y, gridSize);

    const local_x: i32 = @mod(x, gridSize);
    const local_y: i32 = @mod(y, gridSize);

    const local_x_norm =
        @as(f32, @floatFromInt(local_x)) /
        @as(f32, @floatFromInt(gridSize));

    const local_y_norm =
        @as(f32, @floatFromInt(local_y)) /
        @as(f32, @floatFromInt(gridSize));

    var res: f32 = 0.0;

    const nums = [_]i8{ -1, 0, 1 };

    for (nums) |j| {
        for (nums) |i| {
            const h = hash(vec.Vec2f32{
                .x = @as(f32, @floatFromInt(cell_x + i)),
                .y = @as(f32, @floatFromInt(cell_y + j)),
            });

            const rx = @as(f32, @floatFromInt(i)) - local_x_norm + h.x;
            const ry = @as(f32, @floatFromInt(j)) - local_y_norm + h.y;
            const d = std.math.sqrt(rx * rx + ry * ry);

            res += std.math.exp2(-32.0 * d);
        }
    }

    return -(1.0 / 32.0) * std.math.log2(res);
}

test "smooth voronoi pgm" {
    const width: usize = 1024;
    const height: usize = 1024;
    const grid_size: u32 = 256;

    var file = try std.fs.cwd().createFile("testOut/noise/out/voronoi.pgm", .{});
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P2\n{d} {d}\n255\n",
        .{ width, height },
    );

    for (0..height) |y| {
        for (0..width) |x| {
            const value = smoothVoronoi(
                @intCast(x),
                @intCast(y),
                grid_size,
            );

            const normalized = std.math.clamp(value, 0.0, 1.0);
            const pixel: u8 = @intFromFloat(normalized * 255.0);

            try writer.print("{d} ", .{pixel});
        }

        try writer.writeByte('\n');
    }
}

test "smooth voronoi pgm inversed" {
    const width: usize = 1024;
    const height: usize = 1024;
    const grid_size: u32 = 256;

    var file = try std.fs.cwd().createFile("testOut/noise/out/voronoi_inv.pgm", .{});
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P2\n{d} {d}\n255\n",
        .{ width, height },
    );

    for (0..height) |y| {
        for (0..width) |x| {
            const value = smoothVoronoi(
                @intCast(x),
                @intCast(y),
                grid_size,
            );

            const normalized = 1.0 - std.math.clamp(value, 0.0, 1.0);
            const pixel: u8 = @intFromFloat(normalized * 255.0);

            try writer.print("{d} ", .{pixel});
        }

        try writer.writeByte('\n');
    }
}
