const std = @import("std");

const p: [512]u8 = [_]u8{
    0x97, 0xA0, 0x89, 0x5B, 0x5A, 0x0F, 0x83, 0x0D, 0xC9, 0x5F, 0x60, 0x35, 0xC2, 0xE9, 0x07, 0xE1,
    0x8C, 0x24, 0x67, 0x1E, 0x45, 0x8E, 0x08, 0x63, 0x25, 0xF0, 0x15, 0x0A, 0x17, 0xBE, 0x06, 0x94,
    0xF7, 0x78, 0xEA, 0x4B, 0x00, 0x1A, 0xC5, 0x3E, 0x5E, 0xFC, 0xDB, 0xCB, 0x75, 0x23, 0x0B, 0x20,
    0x39, 0xB1, 0x21, 0x58, 0xED, 0x95, 0x38, 0x57, 0xAE, 0x14, 0x7D, 0x88, 0xAB, 0xA8, 0x44, 0xAF,
    0x4A, 0xA5, 0x47, 0x86, 0x8B, 0x30, 0x1B, 0xA6, 0x4D, 0x92, 0x9E, 0xE7, 0x53, 0x6F, 0xE5, 0x7A,
    0x3C, 0xD3, 0x85, 0xE6, 0xDC, 0x69, 0x5C, 0x29, 0x37, 0x2E, 0xF5, 0x28, 0xF4, 0x66, 0x8F, 0x36,
    0x41, 0x19, 0x3F, 0xA1, 0x01, 0xD8, 0x50, 0x49, 0xD1, 0x4C, 0x84, 0xBB, 0xD0, 0x59, 0x12, 0xA9,
    0xC8, 0xC4, 0x87, 0x82, 0x74, 0xBC, 0x9F, 0x56, 0xA4, 0x64, 0x6D, 0xC6, 0xAD, 0xBA, 0x03, 0x40,
    0x34, 0xD9, 0xE2, 0xFA, 0x7C, 0x7B, 0x05, 0xCA, 0x26, 0x93, 0x76, 0x7E, 0xFF, 0x52, 0x55, 0xD4,
    0xCF, 0xCE, 0x3B, 0xE3, 0x2F, 0x10, 0x3A, 0x11, 0xB6, 0xBD, 0x1C, 0x2A, 0xDF, 0xB7, 0xAA, 0xD5,
    0x77, 0xF8, 0x98, 0x02, 0x2C, 0x9A, 0xA3, 0x46, 0xDD, 0x99, 0x65, 0x9B, 0xA7, 0x2B, 0xAC, 0x09,
    0x81, 0x16, 0x27, 0xFD, 0x13, 0x62, 0x6C, 0x6E, 0x4F, 0x71, 0xE0, 0xE8, 0xB2, 0xB9, 0x70, 0x68,
    0xDA, 0xF6, 0x61, 0xE4, 0xFB, 0x22, 0xF2, 0xC1, 0xEE, 0xD2, 0x90, 0x0C, 0xBF, 0xB3, 0xA2, 0xF1,
    0x51, 0x33, 0x91, 0xEB, 0xF9, 0x0E, 0xEF, 0x6B, 0x31, 0xC0, 0xD6, 0x1F, 0xB5, 0xC7, 0x6A, 0x9D,
    0xB8, 0x54, 0xCC, 0xB0, 0x73, 0x79, 0x32, 0x2D, 0x7F, 0x04, 0x96, 0xFE, 0x8A, 0xEC, 0xCD, 0x5D,
    0xDE, 0x72, 0x43, 0x1D, 0x18, 0x48, 0xF3, 0x8D, 0x80, 0xC3, 0x4E, 0x42, 0xD7, 0x3D, 0x9C, 0xB4,

    0x97, 0xA0, 0x89, 0x5B, 0x5A, 0x0F, 0x83, 0x0D, 0xC9, 0x5F, 0x60, 0x35, 0xC2, 0xE9, 0x07, 0xE1,
    0x8C, 0x24, 0x67, 0x1E, 0x45, 0x8E, 0x08, 0x63, 0x25, 0xF0, 0x15, 0x0A, 0x17, 0xBE, 0x06, 0x94,
    0xF7, 0x78, 0xEA, 0x4B, 0x00, 0x1A, 0xC5, 0x3E, 0x5E, 0xFC, 0xDB, 0xCB, 0x75, 0x23, 0x0B, 0x20,
    0x39, 0xB1, 0x21, 0x58, 0xED, 0x95, 0x38, 0x57, 0xAE, 0x14, 0x7D, 0x88, 0xAB, 0xA8, 0x44, 0xAF,
    0x4A, 0xA5, 0x47, 0x86, 0x8B, 0x30, 0x1B, 0xA6, 0x4D, 0x92, 0x9E, 0xE7, 0x53, 0x6F, 0xE5, 0x7A,
    0x3C, 0xD3, 0x85, 0xE6, 0xDC, 0x69, 0x5C, 0x29, 0x37, 0x2E, 0xF5, 0x28, 0xF4, 0x66, 0x8F, 0x36,
    0x41, 0x19, 0x3F, 0xA1, 0x01, 0xD8, 0x50, 0x49, 0xD1, 0x4C, 0x84, 0xBB, 0xD0, 0x59, 0x12, 0xA9,
    0xC8, 0xC4, 0x87, 0x82, 0x74, 0xBC, 0x9F, 0x56, 0xA4, 0x64, 0x6D, 0xC6, 0xAD, 0xBA, 0x03, 0x40,
    0x34, 0xD9, 0xE2, 0xFA, 0x7C, 0x7B, 0x05, 0xCA, 0x26, 0x93, 0x76, 0x7E, 0xFF, 0x52, 0x55, 0xD4,
    0xCF, 0xCE, 0x3B, 0xE3, 0x2F, 0x10, 0x3A, 0x11, 0xB6, 0xBD, 0x1C, 0x2A, 0xDF, 0xB7, 0xAA, 0xD5,
    0x77, 0xF8, 0x98, 0x02, 0x2C, 0x9A, 0xA3, 0x46, 0xDD, 0x99, 0x65, 0x9B, 0xA7, 0x2B, 0xAC, 0x09,
    0x81, 0x16, 0x27, 0xFD, 0x13, 0x62, 0x6C, 0x6E, 0x4F, 0x71, 0xE0, 0xE8, 0xB2, 0xB9, 0x70, 0x68,
    0xDA, 0xF6, 0x61, 0xE4, 0xFB, 0x22, 0xF2, 0xC1, 0xEE, 0xD2, 0x90, 0x0C, 0xBF, 0xB3, 0xA2, 0xF1,
    0x51, 0x33, 0x91, 0xEB, 0xF9, 0x0E, 0xEF, 0x6B, 0x31, 0xC0, 0xD6, 0x1F, 0xB5, 0xC7, 0x6A, 0x9D,
    0xB8, 0x54, 0xCC, 0xB0, 0x73, 0x79, 0x32, 0x2D, 0x7F, 0x04, 0x96, 0xFE, 0x8A, 0xEC, 0xCD, 0x5D,
    0xDE, 0x72, 0x43, 0x1D, 0x18, 0x48, 0xF3, 0x8D, 0x80, 0xC3, 0x4E, 0x42, 0xD7, 0x3D, 0x9C, 0xB4,
};

pub fn getPerlin(comptime gridSize: comptime_int) fn (i32, i32) f32 {
    comptime {
        if (gridSize <= 0) {
            @compileError("gridSize must be greater than zero");
        }
    }

    const Local = struct {
        fn fade(t: f32) f32 {
            return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
        }

        fn lerp(a: f32, b: f32, t: f32) f32 {
            return a + t * (b - a);
        }

        fn dotGrad(h: u8, xf: f32, yf: f32) f32 {
            return switch (h & 0x7) {
                0x0 => xf + yf,
                0x1 => xf,
                0x2 => xf - yf,
                0x3 => -yf,
                0x4 => -xf - yf,
                0x5 => -xf,
                0x6 => -xf + yf,
                0x7 => yf,
                else => unreachable,
            };
        }

        fn hash(x: usize, y: usize) u8 {
            return p[@as(usize, p[x]) + y];
        }

        fn perlin(x: i32, y: i32) f32 {
            const cell_x: i32 = @divFloor(x, gridSize);
            const cell_y: i32 = @divFloor(y, gridSize);

            const local_x: i32 = @mod(x, gridSize);
            const local_y: i32 = @mod(y, gridSize);

            const grid_size_f: f32 = @floatFromInt(gridSize);

            const xf0: f32 = @as(f32, @floatFromInt(local_x)) / grid_size_f;
            const yf0: f32 = @as(f32, @floatFromInt(local_y)) / grid_size_f;

            const xf1: f32 = xf0 - 1.0;
            const yf1: f32 = yf0 - 1.0;

            const xi: usize = @intCast(@mod(cell_x, 256));
            const yi: usize = @intCast(@mod(cell_y, 256));

            const u: f32 = fade(xf0);
            const v: f32 = fade(yf0);

            const h00: u8 = hash(xi, yi);
            const h01: u8 = hash(xi, yi + 1);
            const h10: u8 = hash(xi + 1, yi);
            const h11: u8 = hash(xi + 1, yi + 1);

            const x0: f32 = lerp(
                dotGrad(h00, xf0, yf0),
                dotGrad(h10, xf1, yf0),
                u,
            );

            const x1: f32 = lerp(
                dotGrad(h01, xf0, yf1),
                dotGrad(h11, xf1, yf1),
                u,
            );

            return std.math.clamp(lerp(x0, x1, v), -1.0, 1.0);
        }
    };

    return Local.perlin;
}

// perlin optimised to generate larger arrays.
pub fn getPerlinBlock(
    comptime width: comptime_int,
    comptime height: comptime_int,
    comptime gridSize: comptime_int,
) fn (
    origin_x: i32,
    origin_y: i32,
    seed: u64,
    output: *[width * height]f32,
) void {
    comptime {
        if (width <= 0)
            @compileError("width must be greater than zero");

        if (height <= 0)
            @compileError("height must be greater than zero");

        if (gridSize <= 0)
            @compileError("gridSize must be greater than zero");
    }

    const Local = struct {
        inline fn hash(x: i32, y: i32, seed: u64) u32 {
            var h: u64 = seed;

            h ^= @as(u64, @bitCast(@as(i64, x))) *% 0x9E3779B185EBCA87;
            h ^= @as(u64, @bitCast(@as(i64, y))) *% 0xC2B2AE3D27D4EB4F;

            h ^= h >> 30;
            h *%= 0xBF58476D1CE4E5B9;

            h ^= h >> 27;
            h *%= 0x94D049BB133111EB;

            h ^= h >> 31;

            return @truncate(h);
        }

        inline fn fade(t: f32) f32 {
            return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
        }

        inline fn lerp(a: f32, b: f32, t: f32) f32 {
            return a + t * (b - a);
        }

        inline fn dotGrad(hash_value: u32, x: f32, y: f32) f32 {
            return switch (hash_value & 7) {
                0 => x,
                1 => -x,
                2 => y,
                3 => -y,

                4 => 0.70710678 * (x + y),
                5 => 0.70710678 * (-x + y),
                6 => 0.70710678 * (x - y),
                7 => 0.70710678 * (-x - y),

                else => unreachable,
            };
        }

        fn generate(
            origin_x: i32,
            origin_y: i32,
            seed: u64,
            output: *[width * height]f32,
        ) void {
            const grid_size_f: f32 = @floatFromInt(gridSize);

            //
            // Number of grid points required to cover the output.
            //
            // +2 because the output may start in the middle of a cell,
            // and every cell needs the point on its right/bottom side.
            //

            const grid_width =
                @divFloor(width + gridSize - 1, gridSize) + 2;

            const grid_height =
                @divFloor(height + gridSize - 1, gridSize) + 2;

            //
            // Starting Perlin grid coordinate.
            //

            const first_cell_x = @divFloor(origin_x, gridSize);
            const first_cell_y = @divFloor(origin_y, gridSize);

            //
            // Precalculate all hashes once.
            //

            var hashes: [grid_width * grid_height]u32 = undefined;

            for (0..grid_height) |gy| {
                for (0..grid_width) |gx| {
                    const grid_x =
                        first_cell_x + @as(i32, @intCast(gx));

                    const grid_y =
                        first_cell_y + @as(i32, @intCast(gy));

                    hashes[gy * grid_width + gx] =
                        hash(grid_x, grid_y, seed);
                }
            }

            //
            // Generate pixels.
            //

            for (0..height) |py| {
                const world_y =
                    origin_y + @as(i32, @intCast(py));

                const cell_y = @divFloor(world_y, gridSize);
                const local_y = @mod(world_y, gridSize);

                const yf0 =
                    @as(f32, @floatFromInt(local_y)) /
                    grid_size_f;

                const yf1 = yf0 - 1.0;

                const v = fade(yf0);

                const cache_y: usize =
                    @intCast(cell_y - first_cell_y);

                for (0..width) |px| {
                    const world_x =
                        origin_x + @as(i32, @intCast(px));

                    const cell_x =
                        @divFloor(world_x, gridSize);

                    const local_x =
                        @mod(world_x, gridSize);

                    const xf0 =
                        @as(f32, @floatFromInt(local_x)) /
                        grid_size_f;

                    const xf1 = xf0 - 1.0;

                    const u = fade(xf0);

                    const cache_x: usize =
                        @intCast(cell_x - first_cell_x);

                    //
                    // No hashes here anymore.
                    //
                    // Just four array reads.
                    //

                    const h00 =
                        hashes[
                            cache_y * grid_width +
                                cache_x
                        ];

                    const h10 =
                        hashes[
                            cache_y * grid_width +
                                cache_x + 1
                        ];

                    const h01 =
                        hashes[
                            (cache_y + 1) * grid_width +
                                cache_x
                        ];

                    const h11 =
                        hashes[
                            (cache_y + 1) * grid_width +
                                cache_x + 1
                        ];

                    const x0 = lerp(
                        dotGrad(h00, xf0, yf0),
                        dotGrad(h10, xf1, yf0),
                        u,
                    );

                    const x1 = lerp(
                        dotGrad(h01, xf0, yf1),
                        dotGrad(h11, xf1, yf1),
                        u,
                    );

                    output[py * width + px] =
                        std.math.clamp(
                            lerp(x0, x1, v),
                            -1.0,
                            1.0,
                        );
                }
            }
        }
    };

    return Local.generate;
}

pub fn fbm(x: f32, y: f32) f32 {
    const noise_128 = getPerlin(128);
    const noise_64 = getPerlin(64);
    const noise_32 = getPerlin(32);
    const noise_16 = getPerlin(16);

    const xi: i32 = @intFromFloat(x);
    const yi: i32 = @intFromFloat(y);

    return noise_128(xi, yi) * 0.5333333 +
        noise_64(xi, yi) * 0.2666667 +
        noise_32(xi, yi) * 0.1333333 +
        noise_16(xi, yi) * 0.0666667;
}

pub fn pattern2(x: f32, y: f32) f32 {
    const qx = fbm(
        x,
        y,
    );

    const qy = fbm(
        x + 5.2,
        y + 1.3,
    );

    const rx = fbm(
        x + 4.0 * qx + 1.7,
        y + 4.0 * qy + 9.2,
    );

    const ry = fbm(
        x + 4.0 * qx + 8.3,
        y + 4.0 * qy + 2.8,
    );

    return fbm(
        x + 4.0 * rx,
        y + 4.0 * ry,
    );
}

test "export Perlin noise image" {
    const width: usize = 1024;
    const height: usize = 1024;

    const perlin = getPerlin(64);

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/perlin_noise.pgm",
        .{ .truncate = true },
    );
    defer file.close();

    var writer = file.writer();

    try writer.print(
        "P5\n{} {}\n255\n",
        .{ width, height },
    );

    var row: [width]u8 = undefined;

    var timer = try std.time.Timer.start();

    for (0..height) |y| {
        for (0..width) |x| {
            const noise = perlin(
                @intCast(x),
                @intCast(y),
            );

            const normalized = std.math.clamp(
                noise * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }

    const elapsed_ns = timer.read();

    std.debug.print(
        "Perling noise generation took: {d:.3} ms\n",
        .{@as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms},
    );
}

test "export layered Perlin noise image" {
    const width: usize = 1024;
    const height: usize = 1024;

    const noise_256 = getPerlin(256);
    const noise_128 = getPerlin(128);
    const noise_64 = getPerlin(64);
    const noise_32 = getPerlin(32);
    const noise_16 = getPerlin(16);

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/perlin_layered.pgm",
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
            const xi: i32 = @intCast(x);
            const yi: i32 = @intCast(y);

            const value =
                (noise_256(xi, yi) +
                    noise_128(xi, yi) * 0.5333333 +
                    noise_64(xi, yi) * 0.2666667 +
                    noise_32(xi, yi) * 0.1333333 +
                    noise_16(xi, yi) * 0.0666667) / 2.0;

            const normalized = std.math.clamp(
                value * 0.5 + 0.5,
                0.0,
                1.0,
            );

            row[x] = @intFromFloat(normalized * 255.0);
        }

        try writer.writeAll(&row);
    }
}

test "export Perlin domain warp pattern2 image" {
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
            const value: f32 = pattern2(
                @floatFromInt(x),
                @floatFromInt(y),
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

test "generate two seeded perlin images in 512x512 batches" {
    const WIDTH = 1024;
    const HEIGHT = 1024;

    const BLOCK_SIZE = 512;
    const GRID_SIZE = 64;

    const BLOCKS_X = WIDTH / BLOCK_SIZE;
    const BLOCKS_Y = HEIGHT / BLOCK_SIZE;

    const SEED_1: u64 = 12345;
    const SEED_2: u64 = 987654321;

    const allocator = std.testing.allocator;

    const perlinBlock = getPerlinBlock(
        BLOCK_SIZE,
        BLOCK_SIZE,
        GRID_SIZE,
    );

    var block: [BLOCK_SIZE * BLOCK_SIZE]f32 = undefined;

    const image1 = try allocator.alloc(u8, WIDTH * HEIGHT);
    defer allocator.free(image1);

    const image2 = try allocator.alloc(u8, WIDTH * HEIGHT);
    defer allocator.free(image2);

    //
    // Generate first image.
    //

    var timer = try std.time.Timer.start();

    for (0..BLOCKS_Y) |block_y| {
        for (0..BLOCKS_X) |block_x| {
            const origin_x: i32 =
                @intCast(block_x * BLOCK_SIZE);

            const origin_y: i32 =
                @intCast(block_y * BLOCK_SIZE);

            perlinBlock(
                origin_x,
                origin_y,
                SEED_1,
                &block,
            );

            for (0..BLOCK_SIZE) |local_y| {
                const world_y =
                    block_y * BLOCK_SIZE + local_y;

                for (0..BLOCK_SIZE) |local_x| {
                    const world_x =
                        block_x * BLOCK_SIZE + local_x;

                    const value = std.math.clamp(
                        block[
                            local_y * BLOCK_SIZE +
                                local_x
                        ] * 0.5 + 0.5,
                        0.0,
                        1.0,
                    );

                    //
                    // PGM starts at top-left,
                    // while our noise coordinates start at bottom-left.
                    //
                    const file_y =
                        HEIGHT - 1 - world_y;

                    image1[
                        file_y * WIDTH + world_x
                    ] = @intFromFloat(value * 255.0);
                }
            }
        }
    }

    const elapsed_ns = timer.read();

    std.debug.print(
        "Perling noise block 1 generation took: {d:.3} ms\n",
        .{@as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms},
    );

    timer.reset();

    //
    // Generate second image.
    //

    for (0..BLOCKS_Y) |block_y| {
        for (0..BLOCKS_X) |block_x| {
            const origin_x: i32 =
                @intCast(block_x * BLOCK_SIZE);

            const origin_y: i32 =
                @intCast(block_y * BLOCK_SIZE);

            perlinBlock(
                origin_x,
                origin_y,
                SEED_2,
                &block,
            );

            for (0..BLOCK_SIZE) |local_y| {
                const world_y =
                    block_y * BLOCK_SIZE + local_y;

                for (0..BLOCK_SIZE) |local_x| {
                    const world_x =
                        block_x * BLOCK_SIZE + local_x;

                    const value = std.math.clamp(
                        block[
                            local_y * BLOCK_SIZE +
                                local_x
                        ] * 0.5 + 0.5,
                        0.0,
                        1.0,
                    );

                    const file_y =
                        HEIGHT - 1 - world_y;

                    image2[
                        file_y * WIDTH + world_x
                    ] = @intFromFloat(value * 255.0);
                }
            }
        }
    }

    const elapsed_ns2 = timer.read();

    std.debug.print(
        "Perling noise block 2 generation took: {d:.3} ms\n",
        .{@as(f64, @floatFromInt(elapsed_ns2)) / std.time.ns_per_ms},
    );
    //
    // Write binary PGM files.
    //
    // P5 = binary grayscale
    // WIDTH HEIGHT
    // 255 = max pixel value
    //

    {
        var file = try std.fs.cwd().createFile(
            "testOut/noise/out/perlin_block_seed_1.pgm",
            .{},
        );
        defer file.close();

        const writer = file.writer();

        try writer.print(
            "P5\n{} {}\n255\n",
            .{ WIDTH, HEIGHT },
        );

        try writer.writeAll(image1);
    }

    {
        var file = try std.fs.cwd().createFile(
            "testOut/noise/out/perlin_block_seed_2.pgm",
            .{},
        );
        defer file.close();

        const writer = file.writer();

        try writer.print(
            "P5\n{} {}\n255\n",
            .{ WIDTH, HEIGHT },
        );

        try writer.writeAll(image2);
    }
}
