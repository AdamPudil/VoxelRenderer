const std = @import("std");

const perlin = @import("./noises/perlin.zig");
const domain_warped = @import("./noises/domainWarped.zig");
const remap = @import("./remapingFunctions/basic.zig");

const WIDTH: usize = 8192;
const HEIGHT: usize = 8192;
const BLOCK_SIZE: usize = 256;
const BLOCK_PIXELS: usize = BLOCK_SIZE * BLOCK_SIZE;
const BLOCKS_X: usize = WIDTH / BLOCK_SIZE;
const BLOCKS_Y: usize = HEIGHT / BLOCK_SIZE;

const WORLD_SEED: u64 = 0xA1B2_C3D4_51E7_90F3;
const SEA_LEVEL: f32 = 0.345;

const Color = struct {
    r: f32,
    g: f32,
    b: f32,
};

inline fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

inline fn normalizeNoise(x: f32) f32 {
    return clamp01(x * 0.5 + 0.5);
}

inline fn mix(a: f32, b: f32, t_: f32) f32 {
    const t = clamp01(t_);
    return a + (b - a) * t;
}

inline fn smoothRange(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge0 == edge1) return if (x >= edge1) 1.0 else 0.0;
    return remap.smoothStep(clamp01((x - edge0) / (edge1 - edge0)));
}

inline fn mixColor(a: Color, b: Color, t_: f32) Color {
    const t = clamp01(t_);
    return .{
        .r = mix(a.r, b.r, t),
        .g = mix(a.g, b.g, t),
        .b = mix(a.b, b.b, t),
    };
}

inline fn writeColor(dst: []u8, index: usize, color: Color) void {
    dst[index + 0] = @intFromFloat(clamp01(color.r) * 255.0);
    dst[index + 1] = @intFromFloat(clamp01(color.g) * 255.0);
    dst[index + 2] = @intFromFloat(clamp01(color.b) * 255.0);
}

const VORONOI_SAMPLE_STEP: usize = 4;
const VORONOI_SCALE: i32 = 3;
const VORONOI_GRID_SIDE: usize = BLOCK_SIZE / VORONOI_SAMPLE_STEP + 1;
const VORONOI_GRID_PIXELS: usize = VORONOI_GRID_SIDE * VORONOI_GRID_SIDE;

fn generateWarpedVoronoiBlock(
    origin_x: i32,
    origin_y: i32,
    sample_grid: *[VORONOI_GRID_PIXELS]f32,
    output: *[BLOCK_PIXELS]f32,
) void {
    // warpedVoronoi1() internally performs the domain warp and smooth Voronoi.
    // We evaluate it on a 4-pixel lattice because it is currently scalar and
    // expensive, then bilinearly reconstruct the full 512x512 tectonic block.
    for (0..VORONOI_GRID_SIDE) |gy| {
        for (0..VORONOI_GRID_SIDE) |gx| {
            const wx = origin_x + @as(i32, @intCast(gx * VORONOI_SAMPLE_STEP));
            const wy = origin_y + @as(i32, @intCast(gy * VORONOI_SAMPLE_STEP));

            sample_grid[gy * VORONOI_GRID_SIDE + gx] =
                domain_warped.warpedVoronoi1(
                    @divFloor(wx, VORONOI_SCALE),
                    @divFloor(wy, VORONOI_SCALE),
                );
        }
    }

    const step_f: f32 = @floatFromInt(VORONOI_SAMPLE_STEP);

    for (0..BLOCK_SIZE) |y| {
        const gy = y / VORONOI_SAMPLE_STEP;
        const ty = @as(f32, @floatFromInt(y % VORONOI_SAMPLE_STEP)) / step_f;

        for (0..BLOCK_SIZE) |x| {
            const gx = x / VORONOI_SAMPLE_STEP;
            const tx = @as(f32, @floatFromInt(x % VORONOI_SAMPLE_STEP)) / step_f;

            const a = sample_grid[gy * VORONOI_GRID_SIDE + gx];
            const b = sample_grid[gy * VORONOI_GRID_SIDE + gx + 1];
            const c = sample_grid[(gy + 1) * VORONOI_GRID_SIDE + gx];
            const d = sample_grid[(gy + 1) * VORONOI_GRID_SIDE + gx + 1];

            const top = mix(a, b, tx);
            const bottom = mix(c, d, tx);
            output[y * BLOCK_SIZE + x] = mix(top, bottom, ty);
        }
    }
}

fn printTime(label: []const u8, ns: u64) void {
    std.debug.print("  {s:<28} {d:>10.3} ms\n", .{
        label,
        @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms,
    });
}

test "generate 8192x8192 colored layered terrain map" {
    comptime {
        if (WIDTH % BLOCK_SIZE != 0 or HEIGHT % BLOCK_SIZE != 0)
            @compileError("WIDTH and HEIGHT must be divisible by BLOCK_SIZE");
    }

    const allocator = std.testing.allocator;

    // Low-frequency region / climate fields.
    const gen_continent = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 2048);
    const gen_region = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 1024);
    const gen_temperature = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 1536);
    const gen_moisture = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 1280);

    // Explicit terrain layers. No FBM helper is used here.
    const gen_broad = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 512);
    const gen_medium = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 256);
    const gen_ridges = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 192);
    const gen_detail = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 64);

    // River-network fields.
    const gen_river_a = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 768);
    const gen_river_b = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 384);
    const gen_river_width = perlin.getPerlinBlock(BLOCK_SIZE, BLOCK_SIZE, 1536);

    // Heap arrays are used intentionally: 512x512 f32 arrays are 1 MiB each.
    const continent = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(continent);
    const region = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(region);
    const temperature = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(temperature);
    const moisture = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(moisture);

    const broad = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(broad);
    const medium = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(medium);
    const ridges = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(ridges);
    const detail = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(detail);

    const voronoi_samples = try allocator.create([VORONOI_GRID_PIXELS]f32);
    defer allocator.destroy(voronoi_samples);
    const tectonic = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(tectonic);

    const river_a = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(river_a);
    const river_b = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(river_b);
    const river_width = try allocator.create([BLOCK_PIXELS]f32);
    defer allocator.destroy(river_width);

    // One 512-row RGB band. This lets the test stream the 8192² image without
    // keeping a ~192 MiB RGB image plus all terrain maps in memory.
    const band_bytes = WIDTH * BLOCK_SIZE * 3;
    const band = try allocator.alloc(u8, band_bytes);
    defer allocator.free(band);

    try std.fs.cwd().makePath("testOut/noise/out");

    var file = try std.fs.cwd().createFile(
        "testOut/noise/out/terrain_8192_defined_rivers.ppm",
        .{ .truncate = true },
    );
    defer file.close();

    var header: [64]u8 = undefined;
    const header_text = try std.fmt.bufPrint(
        &header,
        "P6\n{d} {d}\n255\n",
        .{ WIDTH, HEIGHT },
    );
    try file.writeAll(header_text);

    var region_ns: u64 = 0;
    var terrain_ns: u64 = 0;
    var voronoi_ns: u64 = 0;
    var river_ns: u64 = 0;
    var compose_ns: u64 = 0;
    var write_ns: u64 = 0;

    var total_timer = try std.time.Timer.start();
    var stage_timer = try std.time.Timer.start();

    // PPM rows are written top-to-bottom. Noise coordinates remain world-like:
    // (0,0) is the bottom-left, so we generate the top band first.
    for (0..BLOCKS_Y) |file_block_y| {
        @memset(band, 0);

        const world_block_y = BLOCKS_Y - 1 - file_block_y;
        const origin_y: i32 = @intCast(world_block_y * BLOCK_SIZE);

        for (0..BLOCKS_X) |block_x| {
            const origin_x: i32 = @intCast(block_x * BLOCK_SIZE);

            // -----------------------------------------------------------------
            // Stage 1: continent shape + climate / biome-scale masks.
            // -----------------------------------------------------------------
            stage_timer.reset();
            gen_continent(origin_x, origin_y, WORLD_SEED +% 0x0101, continent);
            gen_region(origin_x, origin_y, WORLD_SEED +% 0x0202, region);
            gen_temperature(origin_x, origin_y, WORLD_SEED +% 0x0303, temperature);
            gen_moisture(origin_x, origin_y, WORLD_SEED +% 0x0404, moisture);
            region_ns += stage_timer.read();

            // -----------------------------------------------------------------
            // Stage 2: explicit terrain layers.
            // -----------------------------------------------------------------
            stage_timer.reset();
            gen_broad(origin_x, origin_y, WORLD_SEED +% 0x1101, broad);
            gen_medium(origin_x, origin_y, WORLD_SEED +% 0x1202, medium);
            gen_ridges(origin_x, origin_y, WORLD_SEED +% 0x1303, ridges);
            gen_detail(origin_x, origin_y, WORLD_SEED +% 0x1404, detail);
            terrain_ns += stage_timer.read();

            // -----------------------------------------------------------------
            // Stage 3: the project's actual domain-warped Voronoi noise.
            // -----------------------------------------------------------------
            stage_timer.reset();
            generateWarpedVoronoiBlock(
                origin_x,
                origin_y,
                voronoi_samples,
                tectonic,
            );
            voronoi_ns += stage_timer.read();

            // -----------------------------------------------------------------
            // Stage 4: low-frequency contour fields used as river corridors.
            // -----------------------------------------------------------------
            stage_timer.reset();
            gen_river_a(origin_x, origin_y, WORLD_SEED +% 0x2101, river_a);
            gen_river_b(origin_x, origin_y, WORLD_SEED +% 0x2202, river_b);
            gen_river_width(origin_x, origin_y, WORLD_SEED +% 0x2303, river_width);
            river_ns += stage_timer.read();

            // -----------------------------------------------------------------
            // Stage 5: combine, shape, carve rivers and choose material colors.
            // -----------------------------------------------------------------
            stage_timer.reset();

            for (0..BLOCK_SIZE) |local_y| {
                const world_y = world_block_y * BLOCK_SIZE + local_y;
                const latitude01 = @as(f32, @floatFromInt(world_y)) /
                    @as(f32, @floatFromInt(HEIGHT - 1));
                const equator_distance = @abs(latitude01 * 2.0 - 1.0);

                // Output band is top-to-bottom, while local_y is bottom-to-top.
                const band_y = BLOCK_SIZE - 1 - local_y;

                for (0..BLOCK_SIZE) |local_x| {
                    const i = local_y * BLOCK_SIZE + local_x;

                    const c0 = normalizeNoise(continent[i]);
                    const r0 = normalizeNoise(region[i]);
                    const t0 = normalizeNoise(temperature[i]);
                    const m0 = normalizeNoise(moisture[i]);

                    // Continental mask: broad oceans, shelves, islands and large
                    // land masses. Region noise prevents coastlines from simply
                    // following one Perlin contour.
                    var land = c0 * 0.78 + r0 * 0.22;
                    land = remap.smootherStep(clamp01((land - 0.24) / 0.46));

                    // A small secondary island mask gives isolated archipelagos.
                    const island = remap.power(
                        clamp01((r0 - 0.58) / 0.42),
                        2.2,
                    );
                    land = clamp01(land + island * (1.0 - land) * 0.22);

                    // Climate is partly noise-driven and partly latitude-driven.
                    // The latitude term makes the top/bottom of the map colder.
                    const latitude_cold = remap.power(equator_distance, 1.55);
                    const heat = clamp01(t0 * 0.78 + (1.0 - latitude_cold) * 0.52 - 0.18);
                    const wet = clamp01(m0 * 0.82 + r0 * 0.18);
                    const dryness = 1.0 - wet;

                    const hot = smoothRange(0.57, 0.78, heat);
                    const cold = smoothRange(0.58, 0.90, 1.0 - heat);
                    const dry = smoothRange(0.55, 0.82, dryness);
                    const humid = smoothRange(0.55, 0.82, wet);

                    // Large-scale biome masks overlap intentionally and are later
                    // blended rather than thresholded into hard regions.
                    const desert_mask = clamp01(hot * dry * (0.65 + r0 * 0.35));
                    const forest_mask = clamp01(humid * (1.0 - desert_mask) * (0.55 + r0 * 0.45));
                    const alpine_mask = clamp01(cold * (0.45 + r0 * 0.55));

                    const broad01 = normalizeNoise(broad[i]);
                    const medium01 = normalizeNoise(medium[i]);
                    const detail_signed = detail[i];

                    // Plains / rolling terrain.
                    var plains = (broad01 - 0.5) * 0.095 +
                        (medium01 - 0.5) * 0.040 +
                        detail_signed * 0.009;

                    // Mountains: ridge() folds the noise around 0.5. Squaring it
                    // makes narrow mountain chains instead of large soft blobs.
                    var ridge_shape = remap.ridge(normalizeNoise(ridges[i]));
                    ridge_shape = remap.power(ridge_shape, 2.65);

                    // Smooth Voronoi gets larger between feature points. After
                    // thresholding, those high-distance zones form broad, crooked
                    // tectonic belts. The Perlin ridge layer adds sharp local peaks.
                    const tectonic_distance = clamp01(tectonic[i]);
                    var tectonic_belt = smoothRange(0.43, 0.70, tectonic_distance);
                    tectonic_belt = remap.power(tectonic_belt, 1.65);

                    // A second narrower band produces a distinct mountain spine
                    // inside the broader uplift zone.
                    var tectonic_spine = smoothRange(0.56, 0.78, tectonic_distance);
                    tectonic_spine = remap.power(tectonic_spine, 2.25);

                    const mountain_region = remap.smoothStep(clamp01(
                        (r0 * 0.72 + broad01 * 0.28 - 0.48) / 0.34,
                    ));
                    const mountain_mask = clamp01(
                        mountain_region * (0.72 + alpine_mask * 0.38) * (1.0 - desert_mask * 0.25),
                    );
                    const local_mountains = ridge_shape * mountain_mask * 0.29;
                    const range_mask = clamp01(
                        tectonic_belt * (0.58 + mountain_region * 0.52) *
                            (1.0 - desert_mask * 0.12),
                    );
                    const mountain_ranges = range_mask * 0.22 +
                        tectonic_spine * ridge_shape * 0.25;
                    const mountains = local_mountains + mountain_ranges;

                    // Dry regions become flatter plateaus/mesas. Terracing is only
                    // mixed into deserts so the whole map does not look stepped.
                    const mesa_source = clamp01(broad01 * 0.72 + medium01 * 0.28);
                    const mesa_terraced = remap.terrace(mesa_source, 9.0);
                    const mesa = (mesa_terraced - 0.5) * 0.19 + ridge_shape * 0.055;
                    plains = mix(plains, mesa, desert_mask * 0.78);

                    // Base elevation: ocean floor -> coast -> inland terrain.
                    var height = 0.285 + land * 0.245 + plains + mountains;

                    // Deepen open ocean while retaining a continental shelf near
                    // coastlines.
                    const ocean_depth = remap.power(1.0 - land, 1.8);
                    height -= ocean_depth * 0.095;

                    // River field. Two related zero-contours form long paths and
                    // tributary-like branches without requiring a full flow map.
                    const rv_a = river_a[i];
                    const rv_b = river_b[i];
                    const main_distance = @abs(rv_a * 0.78 + rv_b * 0.22);
                    const branch_distance = @abs(rv_a * 0.46 - rv_b * 0.54);
                    const river_distance = @min(main_distance, branch_distance * 1.18);

                    const width_noise = normalizeNoise(river_width[i]);
                    const river_width_value = mix(0.014, 0.030, width_noise);

                    // Build three nested river masks from the same contour.
                    // The valley is broad and subtle, the channel is clearly
                    // defined, and the core is narrow/deep. This prevents rivers
                    // from looking like fuzzy blue noise bands.
                    var river_valley = 1.0 - smoothRange(
                        river_width_value * 1.35,
                        river_width_value * 3.10,
                        river_distance,
                    );
                    var river_channel = 1.0 - smoothRange(
                        river_width_value * 0.42,
                        river_width_value * 1.12,
                        river_distance,
                    );
                    var river_core = 1.0 - smoothRange(
                        river_width_value * 0.12,
                        river_width_value * 0.43,
                        river_distance,
                    );

                    // Sharpen the actual watercourse while keeping a soft valley.
                    river_valley = remap.smoothStep(clamp01(river_valley));
                    river_channel = remap.power(clamp01(river_channel), 1.55);
                    river_core = remap.power(clamp01(river_core), 2.20);

                    // Rivers exist mainly on real land and lose strength on the
                    // highest mountain spines. Wet climates make the whole system
                    // somewhat more persistent.
                    // Keep channels alive all the way through the coastal transition.
                    // The previous land_factor faded to zero too early, which made
                    // otherwise-good rivers stop a short distance before the sea.
                    const inland_factor = smoothRange(0.42, 0.60, land);
                    const outlet_factor = smoothRange(0.20, 0.46, land);
                    const river_land_factor = @max(inland_factor, outlet_factor * 0.92);

                    const mountain_block = 1.0 - clamp01(
                        ridge_shape * mountain_mask * 0.48 + tectonic_spine * 0.40,
                    );
                    const climate_factor = 0.72 + wet * 0.40;

                    river_valley = clamp01(river_valley * river_land_factor * mountain_block * climate_factor);
                    river_channel = clamp01(river_channel * river_land_factor * mountain_block * climate_factor);
                    river_core = clamp01(river_core * river_land_factor * mountain_block * climate_factor);

                    // Carve rivers RELATIVE TO THE LOCAL LAND HEIGHT.
                    // Previously the channel was forced toward SEA_LEVEL, which
                    // caused rivers to vanish on higher continental interiors.
                    const pre_river_height = height;

                    const valley_cut =
                        river_valley * (0.010 + 0.014 * width_noise);
                    const channel_cut =
                        river_channel * (0.018 + 0.020 * width_noise);
                    const core_cut =
                        river_core * (0.010 + 0.014 * width_noise);

                    height -= valley_cut + channel_cut + core_cut;

                    const river_strength = clamp01(
                        river_channel * 0.86 + river_core * 0.58,
                    );

                    // In the coastal transition, turn the river contour into an
                    // actual outlet. Inland, rivers remain local cuts; near water,
                    // they smoothly descend to/below sea level and punch through
                    // the last strip of beach instead of fading out.
                    const coast_zone = clamp01(
                        1.0 - smoothRange(0.46, 0.64, land),
                    ) * smoothRange(0.18, 0.42, land);
                    const outlet_strength = clamp01(
                        river_channel * coast_zone * 1.35 +
                            river_core * coast_zone * 0.85,
                    );

                    if (outlet_strength > 0.001) {
                        const outlet_bed = SEA_LEVEL -
                            0.008 - river_core * 0.012;
                        height = mix(height, outlet_bed, outlet_strength);
                    }

                    // River water now persists into the coastal transition as well.
                    // The height term keeps isolated low-strength contours on dry
                    // inland terrain from being painted as water.
                    const river_water = river_strength *
                        smoothRange(0.24, 0.50, land) *
                        @max(
                            smoothRange(SEA_LEVEL + 0.010, SEA_LEVEL + 0.065, pre_river_height),
                            outlet_strength,
                        );

                    height = clamp01(height);

                    // ---------------------------------------------------------
                    // Color/material preview.
                    // ---------------------------------------------------------
                    const deep_water = Color{ .r = 0.025, .g = 0.105, .b = 0.235 };
                    const water = Color{ .r = 0.035, .g = 0.245, .b = 0.430 };
                    const shallow = Color{ .r = 0.070, .g = 0.410, .b = 0.500 };
                    const beach = Color{ .r = 0.76, .g = 0.69, .b = 0.45 };
                    const grass = Color{ .r = 0.25, .g = 0.49, .b = 0.20 };
                    const lush_grass = Color{ .r = 0.16, .g = 0.43, .b = 0.16 };
                    const forest = Color{ .r = 0.075, .g = 0.285, .b = 0.105 };
                    const desert = Color{ .r = 0.73, .g = 0.54, .b = 0.27 };
                    const mesa_color = Color{ .r = 0.56, .g = 0.30, .b = 0.17 };
                    const rock = Color{ .r = 0.40, .g = 0.39, .b = 0.37 };
                    const dark_rock = Color{ .r = 0.28, .g = 0.285, .b = 0.29 };
                    const snow = Color{ .r = 0.90, .g = 0.93, .b = 0.94 };

                    var color: Color = undefined;

                    if (height < SEA_LEVEL) {
                        const depth = clamp01((SEA_LEVEL - height) / 0.18);
                        const shallow_mix = smoothRange(0.0, 0.035, SEA_LEVEL - height);
                        color = mixColor(shallow, water, shallow_mix);
                        color = mixColor(color, deep_water, remap.smoothStep(depth));
                    } else if (river_water > 0.035) {
                        // Inland rivers stay visible even high above sea level.
                        // The narrow core receives the deeper water color.
                        const river_depth = clamp01(
                            river_core * 0.72 + river_channel * 0.28,
                        );
                        color = mixColor(water, deep_water, river_depth * 0.58);
                    } else {
                        const above_water = height - SEA_LEVEL;
                        const beach_mask = 1.0 - smoothRange(0.012, 0.035, above_water);

                        var ground = mixColor(grass, lush_grass, wet * 0.60);
                        ground = mixColor(ground, forest, forest_mask * 0.82);
                        ground = mixColor(ground, desert, desert_mask * 0.92);
                        ground = mixColor(ground, mesa_color, desert_mask * ridge_shape * 0.58);

                        const rock_height = smoothRange(0.585, 0.71, height);
                        const exposed_ridge = clamp01(
                            ridge_shape * mountain_mask * 1.05 +
                                tectonic_belt * 0.48 +
                                tectonic_spine * 0.70,
                        );
                        const rock_mask = clamp01(@max(rock_height, exposed_ridge * 0.74));
                        ground = mixColor(ground, rock, rock_mask);
                        ground = mixColor(ground, dark_rock, rock_mask * ridge_shape * 0.36);

                        const snow_line = mix(0.73, 0.61, cold);
                        const snow_mask = smoothRange(snow_line, snow_line + 0.075, height) *
                            clamp01(0.50 + cold * 0.75);
                        ground = mixColor(ground, snow, snow_mask);

                        color = mixColor(ground, beach, beach_mask * (1.0 - river_strength));

                        // Riparian vegetation occupies the valley immediately
                        // outside the water channel. Using valley-channel instead
                        // of the water mask itself produces a visible green border
                        // along rivers, especially through deserts and grasslands.
                        const river_bank = clamp01(river_valley - river_channel * 0.72) *
                            smoothRange(SEA_LEVEL - 0.004, SEA_LEVEL + 0.050, height);
                        color = mixColor(color, lush_grass, river_bank * 0.52);
                    }

                    const band_x = block_x * BLOCK_SIZE + local_x;
                    const out_index = (band_y * WIDTH + band_x) * 3;
                    writeColor(band, out_index, color);
                }
            }

            compose_ns += stage_timer.read();
        }

        stage_timer.reset();
        try file.writeAll(band);
        write_ns += stage_timer.read();

        std.debug.print(
            "terrain map: band {d:>2}/{d} finished\n",
            .{ file_block_y + 1, BLOCKS_Y },
        );
    }

    const total_ns = total_timer.read();
    const generation_ns = region_ns + terrain_ns + voronoi_ns + river_ns + compose_ns;
    const pixels: f64 = @floatFromInt(WIDTH * HEIGHT);
    const generation_s = @as(f64, @floatFromInt(generation_ns)) / std.time.ns_per_s;

    std.debug.print("\n8192x8192 terrain generation timings\n", .{});
    std.debug.print("----------------------------------\n", .{});
    printTime("region + climate noises", region_ns);
    printTime("terrain noise layers", terrain_ns);
    printTime("domain-warped Voronoi", voronoi_ns);
    printTime("river noise layers", river_ns);
    printTime("terrain combine + colors", compose_ns);
    printTime("PPM file writing", write_ns);
    printTime("total", total_ns);

    std.debug.print(
        "  generation throughput         {d:.2} MPix/s\n",
        .{(pixels / 1_000_000.0) / generation_s},
    );
    std.debug.print(
        "  output                        testOut/noise/out/terrain_8192_defined_rivers.ppm\n\n",
        .{},
    );
}
