const std = @import("std");
const region = @import("world/generation/superchunk.zig");
const ds = @import("world/generation/noises/diamondSquare.zig");
const amplitudes = [_]i32{ 4096, 1800, 1200, 800, 650, 400, 300, 180, 120, 80, 50, 30, 20, 10, 6, 3, 1, 4, 2, 1, 0, 2, 1, 1, 0 };
const Noise = ds.DiamondSquare(&amplitudes);

test "all nine neighboring superchunks reach voxel resolution with identical boundaries" {
    const allocator = std.testing.allocator;
    // Keep only shared edges of previous results; full-resolution grids are
    // generated and released one at a time, keeping peak memory bounded.
    const Edges = struct { left: [4097]i32, right: [4097]i32, top: [4097]i32, bottom: [4097]i32 };
    const edges = try allocator.alloc(Edges, 9);
    defer allocator.free(edges);
    for (0..9) |i| {
        const x: i52 = @as(i52, @intCast(i % 3)) - 1;
        const z: i52 = @as(i52, @intCast(i / 3)) - 1;
        const sc = region.GenerationSuperchunk{ .position = .{ .x = .{ .superchunk = x }, .y = .{ .superchunk = z } }, .seed = 777 };
        var gen = try Noise.init(allocator, sc);
        defer gen.deinit();
        var coarse = try gen.result(allocator, 256);
        defer coarse.deinit();
        try gen.refineToComptime(1);
        try std.testing.expectEqual(@as(usize, 25), gen.next_step);
        try std.testing.expectError(error.FinestResolution, gen.advance());
        for (0..4097) |j| {
            const c: u32 = @intCast(j);
            edges[i].left[j] = gen.sample(0, c).?;
            edges[i].right[j] = gen.sample(4096, c).?;
            edges[i].top[j] = gen.sample(c, 0).?;
            edges[i].bottom[j] = gen.sample(c, 4096).?;
        }
        for (0..16) |cz| {
            for (0..16) |cx| {
                try std.testing.expectEqual(coarse.at(cx, cz), gen.sample(@intCast(cx * 256), @intCast(cz * 256)).?);
                var chunk = try gen.resultChunk(allocator, @intCast(cx), @intCast(cz), 1);
                defer chunk.deinit();
                try std.testing.expectEqual(@as(usize, 256 * 256), chunk.values.len);
                try std.testing.expectEqual(gen.sample(@intCast(cx * 256 + 255), @intCast(cz * 256 + 255)).?, chunk.at(255, 255));
            }
        }
        // Exercise the complete owned crop at full voxel resolution too.
        if (i == 4) {
            var whole = try gen.result(allocator, 1);
            defer whole.deinit();
            try std.testing.expectEqual(@as(usize, 4096 * 4096), whole.values.len);
            try std.testing.expectEqual(gen.sample(4095, 4095).?, whole.at(4095, 4095));
        }
    }
    for (0..9) |i| {
        if (i % 3 != 0) try std.testing.expectEqualSlices(i32, &edges[i - 1].right, &edges[i].left);
        if (i / 3 != 0) try std.testing.expectEqualSlices(i32, &edges[i - 3].bottom, &edges[i].top);
    }
}

test "sparse voxel circles match full resolution including shared boundary dependencies" {
    const allocator = std.testing.allocator;
    const sc = region.GenerationSuperchunk{ .position = .{ .x = .{ .superchunk = -1 }, .y = .{ .superchunk = -2 } }, .seed = 777 };
    var dense = try Noise.init(allocator, sc);
    defer dense.deinit();
    try dense.refineTo(1);
    var sparse = try Noise.Sparse.init(allocator, sc, 256);
    defer sparse.deinit();
    const old_center = sparse.sampleCached(2048, 2048).?;
    try sparse.refineParentCircle(.{ .x = 2048, .z = 2048, .radius = 256 }, 16, 256);
    const block_center = try sparse.sampleAt(2064, 2064, 16);
    const circle = region.Circle{ .x = 2048, .z = 2048, .radius = 64 };
    try sparse.refineParentCircle(circle, 1, 16);
    try sparse.refineParentCircle(.{ .x = 0, .z = 4096, .radius = 16 }, 1, 16);
    for (1984..2113) |z| {
        for (1984..2113) |x| {
            if (circle.containsParentCell(@intCast(x), @intCast(z), 16))
                try std.testing.expectEqual(dense.sample(@intCast(x), @intCast(z)).?, sparse.sampleCached(@intCast(x), @intCast(z)).?);
        }
    }
    try std.testing.expectEqual(dense.sample(0, 4095).?, try sparse.sampleAt(0, 4095, 1));
    try std.testing.expectEqual(dense.sample(4096, 4095).?, try sparse.sampleAt(4096, 4095, 1));
    var iterator = sparse.cache.iterator();
    while (iterator.next()) |entry| {
        const x = entry.key_ptr.x;
        const z = entry.key_ptr.z;
        if (x >= 0 and x <= 4096 and z >= 0 and z <= 4096)
            try std.testing.expectEqual(dense.sample(@intCast(x), @intCast(z)).?, entry.value_ptr.*);
    }
    try std.testing.expectEqual(old_center, sparse.sampleCached(2048, 2048).?);
    try std.testing.expectEqual(block_center, sparse.sampleCached(2064, 2064).?);
    try std.testing.expect(sparse.sampleCached(1, 1) == null);
    try std.testing.expect(sparse.sampleCached(1025, 1025) == null);
    try std.testing.expectEqual(@as(u32, 256), sparse.base.current.resolution);
    try std.testing.expect(sparse.cache.count() < 20000);
    const count = sparse.cache.count();
    try sparse.refineParentCircle(circle, 1, 16);
    try std.testing.expectEqual(count, sparse.cache.count());
}
