const std = @import("std");

const perlin = @import("../noises/perlin.zig");

pub fn linear(x: f32) f32 {
    return x;
}

pub fn invert(x: f32) f32 {
    return 1 - x;
}

pub fn power(x: f32, pow: f32) f32 {
    return std.math.pow(f32, x, pow);
}

pub fn root(x: f32, pow: f32) f32 {
    return std.math.pow(f32, x, 1 / pow);
}

pub fn smoothStep(x: f32) f32 {
    return x * x * (3 - (2 * x));
}

pub fn smootherStep(x: f32) f32 {
    return x * x * x * (x * (6 * x - 15) + 10);
}

pub fn treshold(x: f32, t: f32) f32 {
    return if (x > t) 1.0 else 0.0;
}

pub fn terrace(x: f32, n: f32) f32 {
    return @floor(x * n) / n;
}

pub fn ridge(x: f32) f32 {
    return 1.0 - @abs(2.0 * x - 1.0);
}

pub fn valley(x: f32) f32 {
    return @abs(2.0 * x - 1.0);
}

test "shaped perlin outputs" {
    const width: usize = 1024;
    const height: usize = 1024;
    const pixel_count = width * height;

    const allocator = std.testing.allocator;

    const output_count = 10;

    // Parameters for transforms that need one.
    const power_value: f32 = 4.0;
    const root_value: f32 = 3.0;
    const threshold_value: f32 = 0.8;
    const terrace_steps: f32 = 12.0;

    const names = [_][]const u8{
        "linear",
        "invert",
        "power",
        "root",
        "smoothStep",
        "smootherStep",
        "treshold",
        "terrace",
        "ridge",
        "valley",
    };

    var images: [output_count][]u8 = undefined;

    for (&images) |*image| {
        image.* = try allocator.alloc(u8, pixel_count);
    }

    defer {
        for (images) |image| {
            allocator.free(image);
        }
    }

    // Generate FBM only once per pixel.
    for (0..height) |y| {
        for (0..width) |x| {
            const index = y * width + x;

            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);

            const base = perlin.fbm(xf, yf) + 0.5;

            const values = [_]f32{
                linear(base),
                invert(base),
                power(base, power_value),
                root(base, root_value),
                smoothStep(base),
                smootherStep(base),
                treshold(base, threshold_value),
                terrace(base, terrace_steps),
                ridge(base),
                valley(base),
            };

            for (values, 0..) |value, i| {
                const normalized = std.math.clamp(value, 0.0, 1.0);

                images[i][index] = @intFromFloat(
                    normalized * 255.0,
                );
            }
        }
    }

    // Ensure output directory exists.
    try std.fs.cwd().makePath("testOut/noise/out");

    // Write all images.
    for (names, 0..) |name, i| {
        var path_buffer: [256]u8 = undefined;

        const path = try std.fmt.bufPrint(
            &path_buffer,
            "testOut/noise/out/shaped_perlin_{s}.pgm",
            .{name},
        );

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var header_buffer: [64]u8 = undefined;

        const header = try std.fmt.bufPrint(
            &header_buffer,
            "P5\n{d} {d}\n255\n",
            .{ width, height },
        );

        try file.writeAll(header);
        try file.writeAll(images[i]);
    }
}
