const std = @import("std");

const perlin = @import("perlin.zig");
const voronoi = @import("voronoi.zig");

pub fn warpedPerlin1(x: i32, y: i32) f32 {
    const perl = perlin.getPerlin(100);

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);

    const qx = perl(
        x,
        y,
    );

    const qy = perl(
        x + 83,
        y + 20,
    );

    const displacement: f32 = 128.0;

    return perlin.fbm(
        xf + displacement * qx,
        yf + displacement * qy,
    );
}

pub fn warpedPerlin2(x: i32, y: i32) f32 {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);

    const qx = perlin.fbm(
        xf,
        yf,
    );

    const qy = perlin.fbm(
        xf + 83.2,
        yf + 20.8,
    );

    const displacement: f32 = 128.0;

    return perlin.fbm(
        xf + displacement * qx,
        yf + displacement * qy,
    );
}

pub fn warpedVoronoi1(x: i32, y: i32) f32 {
    const perl = perlin.getPerlin(100);

    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);

    const qx = perl(
        @as(i32, @intFromFloat(xf)),
        @as(i32, @intFromFloat(yf)),
    );

    const qy = perl(
        @as(i32, @intFromFloat(xf + 83.2)),
        @as(i32, @intFromFloat(yf + 20.8)),
    );

    const displacement: f32 = 128.0;

    return voronoi.smoothVoronoi(
        @as(i32, @intFromFloat(xf + displacement * qx)),
        @as(i32, @intFromFloat(yf + displacement * qy)),
        256,
    );
}

pub fn warpedVoronoi2(x: i32, y: i32) f32 {
    const xf: f32 = @floatFromInt(x);
    const yf: f32 = @floatFromInt(y);

    const qx = perlin.fbm(
        xf,
        yf,
    );

    const qy = perlin.fbm(
        xf + 83.2,
        yf + 20.8,
    );

    const displacement: f32 = 128.0;

    return voronoi.smoothVoronoi(
        @as(i32, @intFromFloat(xf + displacement * qx)),
        @as(i32, @intFromFloat(yf + displacement * qy)),
        256,
    );
}

test "export Perlin domain warp image" {
    const width: usize = 1024;
    const height: usize = 1024;

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/perlin_domain1.pgm",
        .{ .truncate = true },
    );
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P5\n{} {}\n255\n",
        .{ width, height },
    );

    var row: [width]u8 = undefined;

    for (0..height) |y| {
        for (0..width) |x| {
            const value: f32 = warpedPerlin1(
                @intCast(x),
                @intCast(y),
            );

            const normalized: f32 = std.math.clamp(
                value * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }
}

test "export Perlin domain warp 2 image" {
    const width: usize = 1024;
    const height: usize = 1024;

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/perlin_domain2.pgm",
        .{ .truncate = true },
    );
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P5\n{} {}\n255\n",
        .{ width, height },
    );

    var row: [width]u8 = undefined;

    for (0..height) |y| {
        for (0..width) |x| {
            const value: f32 = warpedPerlin2(
                @intCast(x),
                @intCast(y),
            );

            const normalized: f32 = std.math.clamp(
                value * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }
}

test "export Voronoi domain warp image" {
    const width: usize = 1024;
    const height: usize = 1024;

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/voronoi_domain1.pgm",
        .{ .truncate = true },
    );
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P5\n{} {}\n255\n",
        .{ width, height },
    );

    var row: [width]u8 = undefined;

    for (0..height) |y| {
        for (0..width) |x| {
            const value: f32 = warpedVoronoi1(
                @intCast(x),
                @intCast(y),
            );

            const normalized: f32 = 1.0 - std.math.clamp(
                value * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }
}

test "export Voronoi domain warp 2 image" {
    const width: usize = 1024;
    const height: usize = 1024;

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/voronoi_domain2.pgm",
        .{ .truncate = true },
    );
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P5\n{} {}\n255\n",
        .{ width, height },
    );

    var row: [width]u8 = undefined;

    for (0..height) |y| {
        for (0..width) |x| {
            const value: f32 = warpedVoronoi2(
                @intCast(x),
                @intCast(y),
            );

            const normalized: f32 = 1.0 - std.math.clamp(
                value * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }
}
