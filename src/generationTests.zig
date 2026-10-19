const std = @import("std");
const positions = @import("world/position.zig");
const region = @import("world/generation/superchunk.zig");
const ds = @import("world/generation/noises/diamondSquare.zig");
const allocator = std.testing.allocator;
const steps = [_]i32{ 4096, 1800, 1200, 800, 650, 400, 300, 180, 120, 80, 50, 30, 20, 10, 6, 3, 1, 4, 2, 1, 0, 2, 1, 1, 0 };
const Noise = ds.DiamondSquare(&steps);

fn superchunk(x: i52, z: i52) region.GenerationSuperchunk {
    return .{ .position = .{ .x = .{ .superchunk = x }, .y = .{ .superchunk = z } }, .seed = 0x123456789abcdef0 };
}

test {
    _ = positions;
}

test "superchunk origins and negative coordinates" {
    const sc = superchunk(-2, 3);
    try std.testing.expectEqual(region.Point{ .x = -32, .z = 48 }, sc.chunkOrigin());
    try std.testing.expectEqual(region.Point{ .x = -8192, .z = 12288 }, sc.voxelOrigin());
    try std.testing.expectEqual(@as(usize, 0), try region.levelForResolution(4096));
    try std.testing.expectEqual(@as(usize, 4), try region.levelForResolution(256));
    try std.testing.expectEqual(@as(usize, 8), try region.levelForResolution(16));
    try std.testing.expectEqual(@as(usize, 12), try region.levelForResolution(1));
    try std.testing.expectError(error.CoordinateOverflow, Noise.init(allocator, superchunk(std.math.maxInt(i52), 0)));
    try std.testing.expectError(error.CoordinateOverflow, Noise.init(allocator, superchunk(0, std.math.minInt(i52))));
}

test "root geometry and first split use external support without clamping corners" {
    var gen = try Noise.init(allocator, superchunk(0, 0));
    defer gen.deinit();
    try std.testing.expect(gen.grid().sample(4096, 4096) != null);
    try std.testing.expect(gen.grid().sample(4095, 4095) == null);
    // Roots exist in surrounding superchunks; first-pass edges must not depend
    // on an ungenerated interior center or on clamped voxel 4095 coordinates.
    try std.testing.expect(gen.grid().sample(-4096, 0) != null);
    try gen.advance();
    try std.testing.expectEqual(ds.Phase.square, gen.grid().phase);
    try std.testing.expect(gen.grid().sample(2048, 2048) == null);
    const left = gen.grid().sample(0, 2048).?;
    const right = gen.grid().sample(4096, 2048).?;
    const top = gen.grid().sample(2048, 0).?;
    const bottom = gen.grid().sample(2048, 4096).?;
    try gen.advance();
    const center: i32 = @intCast(@divTrunc(@as(i64, left) + right + top + bottom, 4));
    try std.testing.expectEqual(center + gen.displacement(2, 2048, 2048), gen.grid().sample(2048, 2048).?);
    try std.testing.expectEqual(left, gen.grid().sample(0, 2048).?);
    try std.testing.expectEqual(ds.Phase.complete, gen.grid().phase);
}

fn compareOverlap(a: *const Noise, b: *const Noise, horizontal: bool, resolution: i64) !void {
    var along: i64 = -16;
    while (along <= region.side + 16) : (along += resolution) {
        var across: i64 = -16;
        while (across <= 16) : (across += resolution) {
            const av = if (horizontal) a.grid().sample(region.side + across, along) else a.grid().sample(along, region.side + across);
            const bv = if (horizontal) b.grid().sample(across, along) else b.grid().sample(along, across);
            try std.testing.expect(av != null);
            try std.testing.expectEqual(av, bv);
        }
    }
}

test "generate every superchunk in a 3 by 3 neighborhood and compare all shared borders" {
    // Generate in reverse order to exercise negative, zero, and positive origins.
    var generators: [9]Noise = undefined;
    var initialized: usize = 0;
    defer for (generators[0..initialized]) |*gen| gen.deinit();
    for (0..9) |i| {
        const x: i52 = 1 - @as(i52, @intCast(i % 3));
        const z: i52 = 1 - @as(i52, @intCast(i / 3));
        generators[i] = try Noise.init(allocator, superchunk(x, z));
        initialized += 1;
        try generators[i].refineToComptime(16);
    }
    for (0..9) |i| {
        if (i % 3 != 0) try compareOverlap(&generators[i], &generators[i - 1], true, 16);
        if (i / 3 != 0) try compareOverlap(&generators[i], &generators[i - 3], false, 16);
    }
}

test "progressive refinement preserves coarse samples and matches direct regeneration" {
    var gen = try Noise.init(allocator, superchunk(-3, 2));
    defer gen.deinit();
    var coarse = try gen.result(allocator, 256);
    defer coarse.deinit();
    const count = gen.generated_samples;
    try gen.refineTo(256);
    try gen.refineTo(4096);
    try std.testing.expectEqual(count, gen.generated_samples);
    try gen.refineTo(16);
    var after = try gen.result(allocator, 256);
    defer after.deinit();
    try std.testing.expectEqualSlices(i32, coarse.values, after.values);
    var fine = try gen.result(allocator, 16);
    defer fine.deinit();
    var regenerated = try Noise.generate(allocator, superchunk(-3, 2), 16);
    defer regenerated.deinit();
    try std.testing.expectEqualSlices(i32, fine.values, regenerated.values);
    try std.testing.expectEqual(@as(usize, 256), fine.width);
    try std.testing.expectEqual(@as(usize, 256 * 256), fine.values.len);
    // Returned data ends at 4080; boundary sample 4096 is not exported.
    try std.testing.expectEqual(gen.grid().sample(4080, 4080).?, fine.at(255, 255));
    try std.testing.expect(gen.grid().sample(-16, -16) != null);
    try std.testing.expect(gen.grid().sample(4112, 4112) != null);
}

// Independent recursive oracle. It classifies global lattice coordinates by
// parity rather than using the production pass loops or superchunk storage.
fn reference(comptime amplitudes: []const i32, seed: u64, x: i64, z: i64, spacing: i64) i32 {
    const level: usize = @intCast(@ctz(@as(u64, @intCast(region.side))) - @ctz(@as(u64, @intCast(spacing))));
    const ox = @mod(@divExact(x, spacing), 2) == 1;
    const oz = @mod(@divExact(z, spacing), 2) == 1;
    if (spacing == region.side) return positions.hashToSignedRange(positions.hash2D(positions.mixSeed(seed, 0), x, z), amplitudes[0]);
    if (!ox and !oz) return reference(amplitudes, seed, x, z, spacing * 2);
    const square = ox != oz;
    const step = if (level == 1) (if (square) @as(usize, 1) else 2) else (2 * level - @as(usize, if (square) 0 else 1));
    var sum: i64 = 0;
    var count: i64 = 4;
    if (square and level == 1) {
        count = 2;
        if (ox) {
            sum = @as(i64, reference(amplitudes, seed, x - spacing, z, spacing * 2)) + reference(amplitudes, seed, x + spacing, z, spacing * 2);
        } else {
            sum = @as(i64, reference(amplitudes, seed, x, z - spacing, spacing * 2)) + reference(amplitudes, seed, x, z + spacing, spacing * 2);
        }
    } else if (square or level == 1) {
        sum = @as(i64, reference(amplitudes, seed, x - spacing, z, spacing)) + reference(amplitudes, seed, x + spacing, z, spacing) + reference(amplitudes, seed, x, z - spacing, spacing) + reference(amplitudes, seed, x, z + spacing, spacing);
    } else {
        sum = @as(i64, reference(amplitudes, seed, x - spacing, z - spacing, spacing * 2)) + reference(amplitudes, seed, x + spacing, z - spacing, spacing * 2) + reference(amplitudes, seed, x - spacing, z + spacing, spacing * 2) + reference(amplitudes, seed, x + spacing, z + spacing, spacing * 2);
    }
    const avg: i32 = @intCast(@divTrunc(sum, count));
    return avg + positions.hashToSignedRange(positions.hash2D(positions.mixSeed(seed, step), x, z), amplitudes[step]);
}

test "every amplitude index independently controls its Square or Diamond pass" {
    inline for (0..7) |active| {
        const amplitudes = comptime blk: {
            var values = [_]i32{0} ** 7;
            values[active] = 100 + active * 73;
            break :blk values;
        };
        const TestNoise = ds.DiamondSquare(&amplitudes);
        var gen = try TestNoise.init(allocator, superchunk(-1, 1));
        defer gen.deinit();
        try gen.refineTo(512);
        const origin = gen.superchunk.voxelOrigin();
        var z: i64 = -512;
        while (z <= 4608) : (z += 512) {
            var x: i64 = -512;
            while (x <= 4608) : (x += 512) {
                try std.testing.expectEqual(reference(&amplitudes, gen.superchunk.seed, origin.x + x, origin.z + z, 512), gen.grid().sample(x, z).?);
            }
        }
    }
}

test "invalid requests do not mutate cache and partial passes can resume" {
    const ShortNoise = ds.DiamondSquare(&.{ 0, 100, 0 });
    var gen = try ShortNoise.init(allocator, superchunk(0, 0));
    defer gen.deinit();
    try std.testing.expectError(error.InvalidResolution, gen.refineTo(0));
    try std.testing.expectError(error.InvalidResolution, gen.refineTo(3));
    try std.testing.expectError(error.InvalidResolution, gen.refineTo(8192));
    try std.testing.expectError(error.InsufficientDisplacementSteps, gen.refineTo(1024));
    try std.testing.expectEqual(@as(usize, 1), gen.next_step);
    try gen.advance();
    try gen.refineTo(2048);
    try std.testing.expectEqual(@as(usize, 3), gen.next_step);
    try std.testing.expectEqual(@as(u32, 2048), gen.current.resolution);
    try std.testing.expectError(error.InsufficientDisplacementSteps, gen.advance());
}

fn allocationScenario(alloc: std.mem.Allocator) !void {
    var gen = try Noise.init(alloc, superchunk(-1, 1));
    defer gen.deinit();
    try gen.advance();
    var result = try gen.result(alloc, 512);
    defer result.deinit();
}

test "allocation failures release root pending grids and result storage" {
    try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{});
}

test "debug PGM exports cropped results and individual pass grids" {
    var gen = try Noise.init(allocator, superchunk(0, 0));
    defer gen.deinit();
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    try gen.advance();
    try gen.grid().writePgm(buffer.writer(), -10000, 10000);
    try std.testing.expect(std.mem.startsWith(u8, buffer.items, "P5\n7 7\n255\n"));
    try std.testing.expectEqual(@as(u8, 0), buffer.items["P5\n7 7\n255\n".len + 3 * 7 + 3]);
    buffer.clearRetainingCapacity();
    var result = try gen.result(allocator, 1024);
    defer result.deinit();
    try result.writePgm(buffer.writer(), -10000, 10000);
    try std.testing.expectEqual(@as(usize, "P5\n4 4\n255\n".len + 16), buffer.items.len);
}

test "whole area chunk rectangles and subareas return matching cropped values" {
    var gen = try Noise.init(allocator, superchunk(-2, 1));
    defer gen.deinit();
    var whole = try gen.result(allocator, 16);
    defer whole.deinit();
    const generated = gen.generated_samples;
    // Visit every one of the 16x16 chunks in this superchunk.
    for (0..16) |cz| {
        for (0..16) |cx| {
            var chunk = try gen.resultChunk(allocator, @intCast(cx), @intCast(cz), 16);
            defer chunk.deinit();
            try std.testing.expectEqual(@as(usize, 16), chunk.width);
            try std.testing.expectEqual(@as(usize, 16), chunk.height);
            try std.testing.expectEqual(@as(i64, -8192) + @as(i64, @intCast(cx)) * 256, chunk.origin.x);
            try std.testing.expectEqual(@as(i64, 4096) + @as(i64, @intCast(cz)) * 256, chunk.origin.z);
            for (0..16) |z| {
                for (0..16) |x| try std.testing.expectEqual(whole.at(cx * 16 + x, cz * 16 + z), chunk.at(x, z));
            }
        }
    }
    var chunks = try gen.resultChunks(allocator, .{ .x = 13, .z = 14, .width = 3, .height = 2 }, 16);
    defer chunks.deinit();
    try std.testing.expectEqual(@as(usize, 48), chunks.width);
    try std.testing.expectEqual(@as(usize, 32), chunks.height);
    for (0..chunks.height) |z| {
        for (0..chunks.width) |x| try std.testing.expectEqual(whole.at(13 * 16 + x, 14 * 16 + z), chunks.at(x, z));
    }
    var area = try gen.resultArea(allocator, .{ .x = 32, .z = 48, .width = 64, .height = 32 }, 16);
    defer area.deinit();
    for (0..area.height) |z| {
        for (0..area.width) |x| try std.testing.expectEqual(whole.at(2 + x, 3 + z), area.at(x, z));
    }
    try std.testing.expectEqual(generated, gen.generated_samples);
    try std.testing.expect(gen.sample(4096, 4096) != null);
    try std.testing.expect(gen.sample(4097, 0) == null);
    try std.testing.expectError(error.InvalidArea, gen.resultChunk(allocator, 16, 0, 16));
    try std.testing.expectError(error.InvalidArea, gen.resultChunks(allocator, .{ .x = 15, .z = 0, .width = std.math.maxInt(u32), .height = 1 }, 16));
    try std.testing.expectError(error.InvalidArea, gen.resultArea(allocator, .{ .x = 0, .z = 0, .width = 0, .height = 32 }, 16));
    try std.testing.expectError(error.UnalignedArea, gen.resultArea(allocator, .{ .x = 1, .z = 0, .width = 16, .height = 16 }, 16));
    try std.testing.expectError(error.UnalignedArea, gen.resultChunk(allocator, 0, 0, 512));
}

test "a configuration can end after an individual Square pass" {
    const SquareOnly = ds.DiamondSquare(&.{ 0, 100 });
    var gen = try SquareOnly.init(allocator, superchunk(0, 0));
    defer gen.deinit();
    try gen.advance();
    try std.testing.expectEqual(ds.Phase.square, gen.grid().phase);
    try std.testing.expect(gen.sample(2048, 0) != null);
    try std.testing.expect(gen.sample(2048, 2048) == null);
    try std.testing.expectError(error.InsufficientDisplacementSteps, gen.advance());
    try std.testing.expectError(error.InsufficientDisplacementSteps, gen.refineTo(2048));
}

test "circular LOD uses 12 chunk and 6 chunk diameters" {
    const layout = region.CircularLod{};
    try layout.validate();
    try std.testing.expectEqual(@as(u32, 256), layout.resolutionAt(0, 0));
    try std.testing.expectEqual(@as(u32, 256), layout.resolutionAt(511, 2048));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(512, 2048));
    try std.testing.expectEqual(@as(u32, 256), layout.resolutionAt(3584, 2048));
    try std.testing.expectEqual(@as(u32, 256), layout.resolutionAt(3585, 2048));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(1279, 2048));
    try std.testing.expectEqual(@as(u32, 1), layout.resolutionAt(1280, 2048));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(2816, 2048));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(2817, 2048));
    try std.testing.expectEqual(@as(u32, 1), layout.resolutionAt(2048, 1280));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(2048, 2816));
    // Corners of bounding squares lie outside the circles.
    try std.testing.expectEqual(@as(u32, 256), layout.resolutionAt(512, 512));
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(1280, 1280));
}

test "sparse block circle matches dense refinement without refining distant cells" {
    var sparse = try Noise.Sparse.init(allocator, superchunk(-2, 3), 256);
    defer sparse.deinit();
    var dense = try Noise.init(allocator, superchunk(-2, 3));
    defer dense.deinit();
    try dense.refineTo(16);
    const coarse_value = sparse.sampleCached(2048, 2048).?;
    const base_count = sparse.base.generated_samples;
    const circle = region.Circle{ .x = 2048, .z = 2048, .radius = 129 };
    try sparse.refineCircle(circle, 16);
    const count = sparse.cache.count();
    try std.testing.expect(count > 0 and count < 2000);
    try std.testing.expectEqual(@as(u32, 256), sparse.base.current.resolution);
    try std.testing.expectEqual(base_count, sparse.base.generated_samples);
    try std.testing.expectEqual(coarse_value, sparse.sampleCached(2048, 2048).?);
    try std.testing.expect(sparse.sampleCached(16, 16) == null);
    for (1900..2200) |z| {
        for (1900..2200) |x| {
            if (!circle.contains(@intCast(x), @intCast(z))) continue;
            const sx: u32 = @intCast(x / 16 * 16);
            const sz: u32 = @intCast(z / 16 * 16);
            // This includes cell anchors just outside the circular boundary.
            try std.testing.expectEqual(dense.sample(sx, sz).?, sparse.sampleCached(sx, sz).?);
        }
    }
    try sparse.refineCircle(circle, 16);
    try std.testing.expectEqual(count, sparse.cache.count());
    try std.testing.expectEqual(@as(usize, 0), sparse.generated_by_level[12]);
}

test "sparse sampler reconstructs the special first Square Diamond pair" {
    var sparse = try Noise.Sparse.init(allocator, superchunk(-1, -1), 4096);
    defer sparse.deinit();
    var dense = try Noise.init(allocator, superchunk(-1, -1));
    defer dense.deinit();
    try dense.refineTo(512);
    var z: u32 = 0;
    while (z <= 4096) : (z += 512) {
        var x: u32 = 0;
        while (x <= 4096) : (x += 512) {
            try std.testing.expectEqual(dense.sample(x, z).?, try sparse.sampleAt(x, z, 512));
        }
    }
    try std.testing.expectEqual(@as(u32, 4096), sparse.base.current.resolution);
}

test "sparse sample requests validate bounds alignment and available steps" {
    const ShortNoise = ds.DiamondSquare(&.{ 0, 100, 50 });
    var sparse = try ShortNoise.Sparse.init(allocator, superchunk(0, 0), 4096);
    defer sparse.deinit();
    try std.testing.expectError(error.InvalidResolution, sparse.sampleAt(0, 0, 3));
    try std.testing.expectError(error.InvalidSample, sparse.sampleAt(1, 0, 2048));
    try std.testing.expectError(error.InvalidSample, sparse.sampleAt(8192, 0, 2048));
    try std.testing.expectError(error.InsufficientDisplacementSteps, sparse.refineCircle(.{ .x = 2048, .z = 2048, .radius = 100 }, 1));
    try std.testing.expectError(error.InvalidCircle, sparse.refineCircle(.{ .x = 4097, .z = 0, .radius = 1 }, 2048));
    try std.testing.expectError(error.InvalidCircle, sparse.refineCircle(.{ .x = 0, .z = 0, .radius = 4097 }, 2048));
    try std.testing.expectEqual(@as(u32, 0), sparse.cache.count());
}

fn sparseAllocationScenario(alloc: std.mem.Allocator) !void {
    var sparse = try Noise.Sparse.init(alloc, superchunk(0, -1), 256);
    defer sparse.deinit();
    try sparse.refineCircle(.{ .x = 2000, .z = 2000, .radius = 20 }, 16);
}

test "sparse refinement frees partial dependency caches on allocation failure" {
    try std.testing.checkAllAllocationFailures(allocator, sparseAllocationScenario, .{});
}

test "LOD boundaries select whole chunks and whole blocks symmetrically" {
    const layout = region.CircularLod{};
    var block_z: u32 = 0;
    while (block_z < 4096) : (block_z += 16) {
        var block_x: u32 = 0;
        while (block_x < 4096) : (block_x += 16) {
            const spacing = layout.resolutionAt(block_x, block_z);
            try std.testing.expectEqual(spacing, layout.resolutionAt(block_x + 15, block_z));
            try std.testing.expectEqual(spacing, layout.resolutionAt(block_x, block_z + 15));
            try std.testing.expectEqual(spacing, layout.resolutionAt(block_x + 15, block_z + 15));
            try std.testing.expectEqual(spacing, layout.resolutionAt(4095 - block_x, block_z));
            try std.testing.expectEqual(spacing, layout.resolutionAt(block_x, 4095 - block_z));
            const chunk_x = block_x / 256 * 256;
            const chunk_z = block_z / 256 * 256;
            const chunk_is_coarse = layout.resolutionAt(chunk_x, chunk_z) == 256;
            try std.testing.expectEqual(chunk_is_coarse, spacing == 256);
        }
    }
    try std.testing.expectEqual(@as(u32, 16), layout.resolutionAt(3583, 2048));
    try std.testing.expectEqual(@as(u32, 1), layout.resolutionAt(2815, 2048));
}

test "parent-circle refinement includes whole selected parents and matches dense values" {
    var sparse = try Noise.Sparse.init(allocator, superchunk(-1, 1), 256);
    defer sparse.deinit();
    var dense = try Noise.init(allocator, superchunk(-1, 1));
    defer dense.deinit();
    try dense.refineTo(16);
    const circle = region.Circle{ .x = 2048, .z = 2048, .radius = 200 };
    // Only the four central chunk centers are within radius 200.
    try sparse.refineParentCircle(circle, 16, 256);
    var z: u32 = 1792;
    while (z < 2304) : (z += 16) {
        var x: u32 = 1792;
        while (x < 2304) : (x += 16)
            try std.testing.expectEqual(dense.sample(x, z).?, sparse.sampleCached(x, z).?);
    }
    try std.testing.expect(!circle.contains(1808, 1808));
    try std.testing.expect(sparse.sampleCached(1808, 1808) != null);
    try std.testing.expect(sparse.sampleCached(16, 16) == null);
    const count = sparse.cache.count();
    try sparse.refineParentCircle(circle, 16, 256);
    try std.testing.expectEqual(count, sparse.cache.count());
    try std.testing.expectEqual(@as(u32, 256), sparse.base.current.resolution);
    try std.testing.expectError(error.InvalidResolution, sparse.refineParentCircle(circle, 16, 3));
    try std.testing.expectError(error.InvalidParentResolution, sparse.refineParentCircle(circle, 16, 8));
    try std.testing.expectEqual(count, sparse.cache.count());
}
