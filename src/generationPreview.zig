const std = @import("std");
const logging = @import("core/logging/logging.zig");
const region = @import("world/generation/superchunk.zig");
const ds = @import("world/generation/noises/diamondSquare.zig");
const c = @cImport({
    @cInclude("stb_image_write.h");
});

// A rougher preview profile: retain detail in the middle levels instead of
// letting the root values dominate the entire landscape.
const amplitudes = [_]i32{ 2600, 1500, 1900, 1100, 850, 750, 580, 470, 350, 280, 210, 155, 115, 80, 60, 42, 30, 20, 14, 10, 7, 4, 3, 2, 1 };
const Noise = ds.DiamondSquare(&amplitudes);
const Color = struct { r: f32, g: f32, b: f32 };

const Timings = struct {
    chunk_generation: u64 = 0,
    block_generation: u64 = 0,
    voxel_generation: u64 = 0,
    chunk_samples: usize = 0,
    block_samples: usize = 0,
    voxel_samples: usize = 0,
    block_chunks: usize = 0,
    voxel_chunks: usize = 0,
    generation: u64 = 0,
    assembly: u64 = 0,
    heightmap: u64 = 0,
    coloring: u64 = 0,
};

const HeightRange = struct {
    min: i32,
    max: i32,

    fn measure(heights: []const i32) HeightRange {
        var result = HeightRange{ .min = std.math.maxInt(i32), .max = std.math.minInt(i32) };
        for (heights) |height| {
            result.min = @min(result.min, height);
            result.max = @max(result.max, height);
        }
        return result;
    }
};

const Preview = struct {
    pixels: []u8,
    heightmap: []u8,
    range: HeightRange,

    fn deinit(self: Preview, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.heightmap);
    }
};

pub fn main() !void {
    var timings = Timings{};
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const circular_lod = args.len > 1 and std.mem.eql(u8, args[1], "--lod");
    const arg_start: usize = if (circular_lod) 2 else 1;
    const output_path = if (args.len > arg_start) args[arg_start] else "testOut/hierarchical";
    if (circular_lod and args.len > arg_start + 1) return error.UnexpectedArgument;
    const resolution = if (!circular_lod and args.len > arg_start + 1) try std.fmt.parseInt(u32, args[arg_start + 1], 10) else 1;
    const superchunks_per_side = if (!circular_lod and args.len > arg_start + 2) try std.fmt.parseInt(usize, args[arg_start + 2], 10) else 1;
    if (superchunks_per_side != 1 and superchunks_per_side != 3) return error.InvalidSuperchunkCount;
    try region.validateResolution(resolution);

    try std.fs.cwd().makePath("logs");
    const log_path = if (circular_lod) "logs/generation_lod.log" else "logs/generation_preview.log";
    const log_file = try std.fs.cwd().createFile(log_path, .{});
    defer log_file.close();
    logging.logger = .{ .file = log_file.writer(), .stage = .TESTING, .initialized = true };
    logging.logger.printBoth("Preview log: {s}\n", .{log_path});

    const tile_width: usize = region.side / resolution;
    const width = tile_width * superchunks_per_side;
    const preview = if (circular_lod)
        try renderCircularPreview(allocator, &timings)
    else
        try renderPreview(allocator, tile_width, superchunks_per_side, resolution, &timings);
    defer preview.deinit(allocator);
    // Benchmark the same seed and area densely, without preparing or exporting
    // another image. Release the sparse generator before allocating this baseline.
    const naive_ns = if (circular_lod) try benchmarkNaive(allocator) else timings.generation;
    logTimingReport(timings, circular_lod, naive_ns, superchunks_per_side, resolution);

    try std.fs.cwd().makePath(output_path);
    var layout_buffer: [32]u8 = undefined;
    const layout_name = if (circular_lod) "lod" else try std.fmt.bufPrint(&layout_buffer, "{d}x{d}", .{ superchunks_per_side, superchunks_per_side });
    try exportPng(allocator, output_path, "heightmap", layout_name, width, 1, preview.heightmap);
    try exportPng(allocator, output_path, "overview", layout_name, width, 3, preview.pixels);
    logging.logger.printBoth("Preview images saved to {s}\n", .{output_path});
}

// Release the height mosaic before the PNG encoder allocates its buffers.
fn renderPreview(allocator: std.mem.Allocator, tile_width: usize, superchunks_per_side: usize, resolution: u32, timings: *Timings) !Preview {
    const width = tile_width * superchunks_per_side;
    const heights = try allocator.alloc(i32, width * width);
    defer allocator.free(heights);
    for (0..superchunks_per_side * superchunks_per_side) |i| {
        const tile_x = i % superchunks_per_side;
        const tile_z = i / superchunks_per_side;
        const sc = region.GenerationSuperchunk{
            .position = .{
                .x = .{ .superchunk = @as(i52, @intCast(tile_x)) - @as(i52, @intCast(superchunks_per_side / 2)) },
                .y = .{ .superchunk = @as(i52, @intCast(tile_z)) - @as(i52, @intCast(superchunks_per_side / 2)) },
            },
            .seed = 777,
        };
        logging.logger.printBoth("Generating superchunk {d}/{d} at voxel spacing {d}...\n", .{ i + 1, superchunks_per_side * superchunks_per_side, resolution });
        var stage_timer = try std.time.Timer.start();
        var generator = try Noise.init(allocator, sc);
        defer generator.deinit();
        var result = try generator.result(allocator, resolution);
        defer result.deinit();
        const generation_ns = stage_timer.read();
        timings.generation += generation_ns;
        logging.logger.printBoth("Generated in {d:.3} s\n", .{seconds(generation_ns)});
        stage_timer.reset();
        for (0..tile_width) |z| {
            const offset = (tile_z * tile_width + z) * width + tile_x * tile_width;
            @memcpy(heights[offset..][0..tile_width], result.values[z * tile_width ..][0..tile_width]);
        }
        timings.assembly += stage_timer.read();
    }

    return makePreview(allocator, heights, width, resolution, timings);
}

fn renderCircularPreview(allocator: std.mem.Allocator, timings: *Timings) !Preview {
    const layout = region.CircularLod{};
    try layout.validate();
    var timer = try std.time.Timer.start();
    var generator = try Noise.Sparse.init(allocator, .{
        .position = .{ .x = .{ .superchunk = 0 }, .y = .{ .superchunk = 0 } },
        .seed = 777,
    }, region.voxels_per_chunk);
    defer generator.deinit();
    const coarse_ns = timer.read();
    timings.chunk_generation = coarse_ns;
    timings.chunk_samples = generator.base.generated_samples;
    timings.generation += coarse_ns;
    logging.logger.printBoth("Chunk-level base complete; refining block detail...\n", .{});

    timer.reset();
    try generator.refineParentCircle(layout.blockCircle(), region.voxels_per_block, region.voxels_per_chunk);
    const block_ns = timer.read();
    const block_samples = generator.cache.count();
    timings.block_generation = block_ns;
    timings.block_samples = block_samples;
    timings.generation += block_ns;
    logging.logger.printBoth("Block-level circle complete; refining voxel detail...\n", .{});

    timer.reset();
    try generator.refineParentCircle(layout.voxelCircle(), 1, region.voxels_per_block);
    const voxel_ns = timer.read();
    timings.voxel_generation = voxel_ns;
    timings.voxel_samples = generator.cache.count() - block_samples;
    timings.generation += voxel_ns;
    logging.logger.printBoth("Voxel-level circle complete; preparing preview images...\n", .{});

    timer.reset();
    const width: usize = region.side;
    const heights = try allocator.alloc(i32, width * width);
    defer allocator.free(heights);
    // Select whole chunks, then whole blocks. Coarse cells need just one
    // cache lookup and row fills; only selected fine blocks read per voxel.
    var chunk_z: u32 = 0;
    while (chunk_z < region.side) : (chunk_z += region.voxels_per_chunk) {
        var chunk_x: u32 = 0;
        while (chunk_x < region.side) : (chunk_x += region.voxels_per_chunk) {
            if (!layout.blockCircle().containsParentCell(chunk_x, chunk_z, region.voxels_per_chunk)) {
                const value = generator.sampleCached(chunk_x, chunk_z) orelse return error.MissingLodSample;
                fillHeightCell(heights, width, chunk_x, chunk_z, region.voxels_per_chunk, value);
                continue;
            }
            timings.block_chunks += 1;
            var has_voxel_detail = false;
            var block_z = chunk_z;
            while (block_z < chunk_z + region.voxels_per_chunk) : (block_z += region.voxels_per_block) {
                var block_x = chunk_x;
                while (block_x < chunk_x + region.voxels_per_chunk) : (block_x += region.voxels_per_block) {
                    if (layout.resolutionAt(block_x, block_z) == region.voxels_per_block) {
                        const value = generator.sampleCached(block_x, block_z) orelse return error.MissingLodSample;
                        fillHeightCell(heights, width, block_x, block_z, region.voxels_per_block, value);
                    } else {
                        has_voxel_detail = true;
                        var z = block_z;
                        while (z < block_z + region.voxels_per_block) : (z += 1) {
                            var x = block_x;
                            while (x < block_x + region.voxels_per_block) : (x += 1)
                                heights[@as(usize, z) * width + x] = generator.sampleCached(x, z) orelse return error.MissingLodSample;
                        }
                    }
                }
            }
            if (has_voxel_detail) timings.voxel_chunks += 1;
        }
    }
    timings.assembly = timer.read();
    return makePreview(allocator, heights, width, 1, timings);
}

fn fillHeightCell(heights: []i32, width: usize, x: u32, z: u32, size: u32, value: i32) void {
    for (z..z + size) |row| @memset(heights[row * width + x ..][0..size], value);
}

fn makePreview(allocator: std.mem.Allocator, heights: []const i32, width: usize, resolution: u32, timings: *Timings) !Preview {
    var stage_timer = try std.time.Timer.start();
    const height_range = HeightRange.measure(heights);
    const heightmap = try allocator.alloc(u8, heights.len);
    errdefer allocator.free(heightmap);
    const span = @max(@as(i64, height_range.max) - height_range.min, 1);
    // One global scale, including underwater elevations; no palette or lighting.
    for (heights, heightmap) |height, *pixel| {
        pixel.* = @intCast(@divTrunc((@as(i64, height) - height_range.min) * 255, span));
    }
    timings.heightmap = stage_timer.read();
    stage_timer.reset();
    const pixels = try allocator.alloc(u8, width * width * 3);
    colorTerrain(heights, width, resolution, height_range, pixels);
    timings.coloring = stage_timer.read();
    return .{ .pixels = pixels, .heightmap = heightmap, .range = height_range };
}

fn blend(a: Color, b: Color, t: f32) Color {
    const f = std.math.clamp(t, 0, 1);
    return .{ .r = a.r + (b.r - a.r) * f, .g = a.g + (b.g - a.g) * f, .b = a.b + (b.b - a.b) * f };
}

fn smooth(a: f32, b: f32, value: f32) f32 {
    const t = std.math.clamp((value - a) / (b - a), 0, 1);
    return t * t * (3 - 2 * t);
}

fn elevation(heights: []const i32, width: usize, x: usize, z: usize) f32 {
    return @floatFromInt(heights[z * width + x]);
}

fn colorTerrain(heights: []const i32, width: usize, resolution: u32, height_range: HeightRange, pixels: []u8) void {
    // Normalize once for the entire mosaic: never independently per superchunk.
    const low: f32 = @floatFromInt(height_range.min);
    const range: f32 = @floatFromInt(@max(@as(i64, height_range.max) - height_range.min, 1));
    const sea: f32 = 0.43;
    const spacing: f32 = @floatFromInt(resolution);
    for (0..width) |z| {
        for (0..width) |x| {
            const raw = elevation(heights, width, x, z);
            const h = (raw - low) / range;
            const left = x -| 1;
            const right = @min(x + 1, width - 1);
            const top = z -| 1;
            const bottom = @min(z + 1, width - 1);
            // Sample the stitched field so lighting has no tile-boundary seams.
            const dx = (elevation(heights, width, right, z) - elevation(heights, width, left, z)) / (@as(f32, @floatFromInt(@max(right - left, 1))) * spacing);
            const dz = (elevation(heights, width, x, bottom) - elevation(heights, width, x, top)) / (@as(f32, @floatFromInt(@max(bottom - top, 1))) * spacing);
            const slope = @sqrt(dx * dx + dz * dz);
            const nx = -dx * 1.4;
            const nz = -dz * 1.4;
            const light = std.math.clamp((nx * -0.48 + 0.80 + nz * -0.36) / @sqrt(nx * nx + 1 + nz * nz), 0, 1);
            var color: Color = undefined;
            var shade: f32 = 1;
            if (h < sea) {
                color = blend(.{ .r = 12, .g = 31, .b = 58 }, .{ .r = 29, .g = 88, .b = 120 }, smooth(0.04, sea - 0.025, h));
                color = blend(color, .{ .r = 75, .g = 166, .b = 168 }, smooth(sea - 0.035, sea, h));
            } else {
                color = blend(.{ .r = 205, .g = 192, .b = 143 }, .{ .r = 106, .g = 144, .b = 78 }, smooth(sea + 0.004, sea + 0.025, h));
                color = blend(color, .{ .r = 48, .g = 91, .b = 65 }, smooth(sea + 0.03, 0.65, h));
                color = blend(color, .{ .r = 133, .g = 139, .b = 100 }, smooth(0.64, 0.77, h));
                const rock = @max(smooth(0.75, 0.87, h), smooth(0.6, 2.5, slope) * smooth(sea + 0.04, 0.76, h) * 0.75);
                color = blend(color, .{ .r = 139, .g = 130, .b = 119 }, rock);
                color = blend(color, .{ .r = 236, .g = 240, .b = 232 }, smooth(0.83, 0.94, h) * (1 - smooth(1.5, 4, slope) * 0.45));
                shade = 0.56 + 0.64 * light;
            }
            const index = (z * width + x) * 3;
            pixels[index] = @intFromFloat(std.math.clamp(color.r * shade, 0, 255));
            pixels[index + 1] = @intFromFloat(std.math.clamp(color.g * shade, 0, 255));
            pixels[index + 2] = @intFromFloat(std.math.clamp(color.b * shade, 0, 255));
        }
    }
}

fn exportPng(allocator: std.mem.Allocator, directory: []const u8, prefix: []const u8, layout_name: []const u8, width: usize, channels: usize, pixels: []const u8) !void {
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "{s}_{s}.png", .{ prefix, layout_name });
    const filename = try std.fs.path.joinZ(allocator, &.{ directory, name });
    defer allocator.free(filename);
    logging.logger.printBoth("Exporting {s} ({d}x{d})...\n", .{ filename, width, width });
    if (c.stbi_write_png(filename.ptr, @intCast(width), @intCast(width), @intCast(channels), pixels.ptr, @intCast(width * channels)) == 0)
        return error.ImageWriteFailed;
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

// Same dense path used by the uniform preview, including result extraction.
fn benchmarkNaive(allocator: std.mem.Allocator) !u64 {
    logging.logger.printBoth("Benchmarking naive full-area generation at voxel spacing 1...\n", .{});
    var timer = try std.time.Timer.start();
    var generator = try Noise.init(allocator, .{
        .position = .{ .x = .{ .superchunk = 0 }, .y = .{ .superchunk = 0 } },
        .seed = 777,
    });
    defer generator.deinit();
    var result = try generator.result(allocator, 1);
    defer result.deinit();
    return timer.read();
}

fn logTimingSection(label: []const u8, ns: u64, chunks: usize, final_chunks: ?usize) void {
    const ms = @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
    const per_chunk = if (chunks == 0) 0 else ms / @as(f64, @floatFromInt(chunks));
    logging.logger.printBoth(
        "[{s}]\n\tTotal time - {d:.3} [ms]\n\tTime per chunk - {d:.6} [ms/chunk]\n\t{s} - {d} [chunks]\n",
        .{ label, ms, per_chunk, if (final_chunks != null) "Refined chunks" else "Chunk count", chunks },
    );
    if (final_chunks) |count| logging.logger.printBoth("\tFinal chunk count - {d} [chunks]\n", .{count});
}

fn logTimingReport(timings: Timings, lod: bool, naive_ns: u64, superchunks_per_side: usize, resolution: u32) void {
    const chunks = superchunks_per_side * superchunks_per_side * region.chunks_per_side * region.chunks_per_side;
    // Raw output preserves the report layout in both the terminal and log file.
    logging.logger.printBoth("-=={s}==-\n", .{if (lod) "Naive generation" else "Normal generation"});
    logTimingSection("Naive", naive_ns, chunks, null);
    logging.logger.printBoth("\tSpacing - {d} [voxels]\n", .{if (lod) @as(u32, 1) else resolution});
    if (lod) {
        logging.logger.printBoth("-==Hierarchical generation==-\n", .{});
        logTimingSection("Chunk detail", timings.chunk_generation, chunks, chunks - timings.block_chunks);
        logTimingSection("Block detail", timings.block_generation, timings.block_chunks, timings.block_chunks - timings.voxel_chunks);
        logTimingSection("Voxel detail", timings.voxel_generation, timings.voxel_chunks, timings.voxel_chunks);
        logTimingSection("Total", timings.generation, chunks, null);
        logging.logger.printBoth("Refinement counts overlap; averages use refined chunks. Final counts use each chunk's finest detail.\n", .{});
    }
    logging.logger.printBoth("Generation only; image preparation and exports excluded.\n", .{});
}
