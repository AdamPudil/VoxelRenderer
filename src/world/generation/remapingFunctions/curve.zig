const std = @import("std");

const perlin = @import("../noises/perlin.zig");

pub const CurveInterpolation = enum {
    linear,
    smooth,
    smoother,
    constant,
};

pub const CurvePoint = struct {
    x: f32,
    y: f32,
    interpolation: CurveInterpolation = .linear,
};

pub const Curve = struct {
    points: []const CurvePoint,

    pub fn sample(self: Curve, x: f32) f32 {
        if (self.points.len == 0)
            return x;

        if (x <= self.points[0].x)
            return self.points[0].y;

        if (x >= self.points[self.points.len - 1].x)
            return self.points[self.points.len - 1].y;

        for (0..self.points.len - 1) |i| {
            const a = self.points[i];
            const b = self.points[i + 1];

            if (x >= a.x and x <= b.x) {
                var t = (x - a.x) / (b.x - a.x);

                t = switch (a.interpolation) {
                    .linear => t,

                    .smooth => t * t * (3.0 - 2.0 * t),

                    .smoother => t * t * t * (t * (t * 6.0 - 15.0) + 10.0),

                    .constant => 0.0,
                };

                return a.y + (b.y - a.y) * t;
            }
        }

        unreachable;
    }
};

test "curve shaped perlin outputs" {
    const width: usize = 1024;
    const height: usize = 1024;
    const pixel_count = width * height;

    const allocator = std.testing.allocator;

    const curves = [_]Curve{
        // curve-1:
        // Suppress low values, then strongly lift mid/high values.
        .{
            .points = &.{
                .{ .x = 0.0, .y = 0.0, .interpolation = .smooth },
                .{ .x = 0.25, .y = 0.05, .interpolation = .smoother },
                .{ .x = 0.45, .y = 0.15, .interpolation = .smooth },
                .{ .x = 0.60, .y = 0.75, .interpolation = .smoother },
                .{ .x = 0.80, .y = 0.90, .interpolation = .linear },
                .{ .x = 1.0, .y = 1.0 },
            },
        },

        // curve-2:
        // Creates a broad elevated middle band.
        .{
            .points = &.{
                .{ .x = 0.0, .y = 0.0, .interpolation = .smooth },
                .{ .x = 0.20, .y = 0.08, .interpolation = .smoother },
                .{ .x = 0.40, .y = 0.75, .interpolation = .smooth },
                .{ .x = 0.65, .y = 0.82, .interpolation = .smoother },
                .{ .x = 0.85, .y = 0.40, .interpolation = .smooth },
                .{ .x = 1.0, .y = 1.0 },
            },
        },

        // curve-3:
        // Non-monotonic: low -> high -> low -> high.
        // Useful for turning different noise ranges into separate bands.
        .{
            .points = &.{
                .{ .x = 0.0, .y = 0.05, .interpolation = .smoother },
                .{ .x = 0.25, .y = 0.85, .interpolation = .smooth },
                .{ .x = 0.50, .y = 0.20, .interpolation = .smoother },
                .{ .x = 0.72, .y = 0.75, .interpolation = .smooth },
                .{ .x = 1.0, .y = 0.30 },
            },
        },

        // curve-4:
        // Multiple flat-ish regions mixed with smooth transitions.
        .{
            .points = &.{
                .{ .x = 0.0, .y = 0.10, .interpolation = .constant },
                .{ .x = 0.18, .y = 0.25, .interpolation = .smooth },
                .{ .x = 0.38, .y = 0.28, .interpolation = .constant },
                .{ .x = 0.55, .y = 0.62, .interpolation = .smoother },
                .{ .x = 0.75, .y = 0.65, .interpolation = .constant },
                .{ .x = 0.90, .y = 0.92, .interpolation = .smooth },
                .{ .x = 1.0, .y = 1.0 },
            },
        },

        // curve-5:
        // Strong inversion-like deformation, but not a simple invert.
        .{
            .points = &.{
                .{ .x = 0.0, .y = 0.90, .interpolation = .smoother },
                .{ .x = 0.20, .y = 0.65, .interpolation = .smooth },
                .{ .x = 0.42, .y = 0.72, .interpolation = .smoother },
                .{ .x = 0.58, .y = 0.25, .interpolation = .smooth },
                .{ .x = 0.82, .y = 0.35, .interpolation = .smoother },
                .{ .x = 1.0, .y = 0.05 },
            },
        },
    };

    const names = [_][]const u8{
        "curve-1",
        "curve-2",
        "curve-3",
        "curve-4",
        "curve-5",
    };

    var images: [curves.len][]u8 = undefined;

    for (&images) |*image| {
        image.* = try allocator.alloc(u8, pixel_count);
    }

    defer {
        for (images) |image| {
            allocator.free(image);
        }
    }

    // Generate base FBM only once per pixel.
    for (0..height) |y| {
        for (0..width) |x| {
            const index = y * width + x;

            const base = perlin.fbm(
                @floatFromInt(x),
                @floatFromInt(y),
            ) + 0.5;

            for (curves, 0..) |curve, i| {
                const value = curve.sample(base);
                const normalized = std.math.clamp(value, 0.0, 1.0);

                images[i][index] = @intFromFloat(
                    normalized * 255.0,
                );
            }
        }
    }

    try std.fs.cwd().makePath("testOut/noise/out");

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
