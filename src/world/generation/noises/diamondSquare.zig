const std = @import("std");
const position = @import("../../position.zig");
const region = @import("../superchunk.zig");

pub const Phase = enum { complete, square, diamond };

/// A dense lattice including neighboring support samples. Local coordinates can
/// be negative. Missing samples in a partial pass are exposed as null by sample().
pub const Grid = struct {
    allocator: std.mem.Allocator,
    resolution: u32,
    padding: i64,
    width: usize,
    values: []i32,
    phase: Phase = .complete,

    fn init(allocator: std.mem.Allocator, resolution: u32) !Grid {
        // Two lattice intervals for parent dependencies outside the public
        // 0..4096 sample domain. This support is never part of a result.
        const r: i64 = resolution;
        const padding = 2 * r;
        const width: usize = @intCast(@divTrunc(region.side + 2 * padding, r) + 1);
        const values = try allocator.alloc(i32, width * width);
        @memset(values, 0);
        return .{ .allocator = allocator, .resolution = resolution, .padding = padding, .width = width, .values = values };
    }

    fn deinit(self: *Grid) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }

    fn index(self: Grid, x: i64, z: i64) ?usize {
        if (x < -self.padding or z < -self.padding or x > region.side + self.padding or z > region.side + self.padding)
            return null;
        if (@mod(x, self.resolution) != 0 or @mod(z, self.resolution) != 0) return null;
        const ix: usize = @intCast(@divTrunc(x + self.padding, self.resolution));
        const iz: usize = @intCast(@divTrunc(z + self.padding, self.resolution));
        return iz * self.width + ix;
    }

    pub fn sample(self: Grid, x: i64, z: i64) ?i32 {
        const i = self.index(x, z) orelse return null;
        const odd_x = @mod(@divExact(x, self.resolution), 2) == 1;
        const odd_z = @mod(@divExact(z, self.resolution), 2) == 1;
        if (self.phase == .square and odd_x and odd_z) return null;
        if (self.phase == .diamond and odd_x != odd_z) return null;
        return self.values[i];
    }

    fn at(self: Grid, x: i64, z: i64) i32 {
        return self.sample(x, z) orelse unreachable;
    }

    /// Includes support border; ungenerated samples are black. Call after each
    /// advance() to export root, Square, Diamond, and subsequent individual passes.
    pub fn writePgm(self: Grid, writer: anytype, min: i32, max: i32) !void {
        std.debug.assert(min < max);
        try writer.print("P5\n{d} {d}\n255\n", .{ self.width, self.width });
        const row = try self.allocator.alloc(u8, self.width);
        defer self.allocator.free(row);
        for (0..self.width) |iz| {
            const z = @as(i64, @intCast(iz)) * self.resolution - self.padding;
            for (row, 0..) |*pixel, ix| {
                const x = @as(i64, @intCast(ix)) * self.resolution - self.padding;
                pixel.* = if (self.sample(x, z)) |value|
                    @intCast(@divTrunc((@as(i64, std.math.clamp(value, min, max)) - min) * 255, @as(i64, max) - min))
                else
                    0;
            }
            try writer.writeAll(row);
        }
    }
};

/// Deterministic integer Diamond-Square on a global dyadic X/Z lattice.
/// Root samples are geometric superchunk boundaries (0/4096), never 4095 or
/// randomly placed interior corners. Neighbor data is generated independently.
/// A superchunk owns this cache; generate() returns only its cropped result.
pub fn DiamondSquare(comptime displacement_steps: []const i32) type {
    comptime {
        if (displacement_steps.len == 0 or displacement_steps.len > 25)
            @compileError("DiamondSquare needs a root amplitude and up to 24 individual pass amplitudes");
        var bound: i64 = 0;
        for (displacement_steps) |amplitude| {
            if (amplitude < 0) @compileError("Displacement amplitudes must be nonnegative");
            bound += amplitude;
        }
        if (bound > std.math.maxInt(i32)) @compileError("Sum of amplitudes must fit an i32 height");
    }
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        superchunk: region.GenerationSuperchunk,
        current: Grid,
        pending: ?Grid = null,
        /// Index of the next individual pass, not the refinement level.
        next_step: usize = 1,
        generated_samples: usize = 0,

        /// Selective refinement over a reusable dense coarse field. Only requested
        /// samples and their parent dependencies are generated; old values never
        /// change. Coordinates uniquely identify samples across all levels.
        pub const Sparse = struct {
            const SparseSelf = @This();
            const Key = struct { x: i32, z: i32 };
            base: Self,
            cache: std.AutoHashMap(Key, i32),
            generated_by_level: [13]usize = [_]usize{0} ** 13,

            pub fn init(allocator: std.mem.Allocator, superchunk: region.GenerationSuperchunk, coarse_resolution: u32) !SparseSelf {
                var base = try Self.init(allocator, superchunk);
                errdefer base.deinit();
                try base.refineTo(coarse_resolution);
                return .{ .base = base, .cache = std.AutoHashMap(Key, i32).init(allocator) };
            }

            pub fn deinit(self: *SparseSelf) void {
                self.cache.deinit();
                self.base.deinit();
                self.* = undefined;
            }

            fn validateTarget(resolution: u32) !void {
                const level = try region.levelForResolution(resolution);
                if (2 * level >= displacement_steps.len) return error.InsufficientDisplacementSteps;
            }

            /// Generates exactly this aligned sample and any missing dependencies.
            pub fn sampleAt(self: *SparseSelf, x: u32, z: u32, resolution: u32) !i32 {
                try validateTarget(resolution);
                if (x > region.side or z > region.side or x % resolution != 0 or z % resolution != 0)
                    return error.InvalidSample;
                return self.fetch(@intCast(x), @intCast(z), resolution);
            }

            /// Read-only lookup, without generating anything at finer resolution.
            pub fn sampleCached(self: *const SparseSelf, x: u32, z: u32) ?i32 {
                if (x > region.side or z > region.side) return null;
                return self.base.current.sample(x, z) orelse self.cache.get(.{ .x = @intCast(x), .z = @intCast(z) });
            }

            pub fn refineCircle(self: *SparseSelf, circle: region.Circle, resolution: u32) !void {
                try validateTarget(resolution);
                try circle.validate();
                const min_x = (circle.x -| circle.radius) / resolution * resolution;
                const min_z = (circle.z -| circle.radius) / resolution * resolution;
                const max_x = @min(circle.x + circle.radius, region.side - 1);
                const max_z = @min(circle.z + circle.radius, region.side - 1);
                var z = min_z;
                while (z <= max_z) : (z += resolution) {
                    var x = min_x;
                    while (x <= max_x) : (x += resolution) {
                        if (circle.intersectsCell(x, z, resolution))
                            _ = try self.fetch(@intCast(x), @intCast(z), resolution);
                    }
                }
            }

            /// Refine whole parent cells selected by their centers. Circle tests
            /// run once per parent, not once per fine sample; descendants are
            /// generated with simple rectangular loops. Parent dependencies may
            /// still extend outside selected cells.
            pub fn refineParentCircle(self: *SparseSelf, circle: region.Circle, resolution: u32, parent_size: u32) !void {
                try validateTarget(resolution);
                try circle.validate();
                try region.validateResolution(parent_size);
                if (resolution > parent_size) return error.InvalidParentResolution;
                const min_x = (circle.x -| circle.radius) / parent_size * parent_size;
                const min_z = (circle.z -| circle.radius) / parent_size * parent_size;
                const max_x = @min(circle.x + circle.radius, region.side - 1);
                const max_z = @min(circle.z + circle.radius, region.side - 1);
                var parent_z = min_z;
                while (parent_z <= max_z) : (parent_z += parent_size) {
                    var parent_x = min_x;
                    while (parent_x <= max_x) : (parent_x += parent_size) {
                        if (!circle.containsParentCell(parent_x, parent_z, parent_size)) continue;
                        var z = parent_z;
                        while (z < parent_z + parent_size) : (z += resolution) {
                            var x = parent_x;
                            while (x < parent_x + parent_size) : (x += resolution)
                                _ = try self.fetch(@intCast(x), @intCast(z), resolution);
                        }
                    }
                }
            }

            fn fetch(self: *SparseSelf, x: i32, z: i32, spacing: u32) std.mem.Allocator.Error!i32 {
                if (self.base.current.sample(x, z)) |value| return value;
                const key = Key{ .x = x, .z = z };
                if (self.cache.get(key)) |value| return value;
                const half: i32 = @intCast(spacing);
                const level: usize = 12 - @as(usize, @intCast(@ctz(spacing)));
                var value: i32 = undefined;
                if (spacing == region.side) {
                    value = self.base.displacement(0, x, z);
                } else {
                    const odd_x = @mod(@divExact(x, half), 2) == 1;
                    const odd_z = @mod(@divExact(z, half), 2) == 1;
                    if (!odd_x and !odd_z) return self.fetch(x, z, spacing * 2);
                    const square = odd_x != odd_z;
                    var average: i32 = undefined;
                    var step: usize = undefined;
                    if (level == 1 and square) {
                        const a = if (odd_x) try self.fetch(x - half, z, spacing * 2) else try self.fetch(x, z - half, spacing * 2);
                        const b = if (odd_x) try self.fetch(x + half, z, spacing * 2) else try self.fetch(x, z + half, spacing * 2);
                        average = Self.mean2(a, b);
                        step = 1;
                    } else if (level == 1 or square) {
                        // The first Diamond depends on new Square values; later
                        // Squares depend on neighboring Diamonds and old endpoints.
                        average = Self.mean4(
                            try self.fetch(x - half, z, spacing),
                            try self.fetch(x + half, z, spacing),
                            try self.fetch(x, z - half, spacing),
                            try self.fetch(x, z + half, spacing),
                        );
                        step = if (level == 1) 2 else level * 2;
                    } else {
                        average = Self.mean4(
                            try self.fetch(x - half, z - half, spacing * 2),
                            try self.fetch(x + half, z - half, spacing * 2),
                            try self.fetch(x - half, z + half, spacing * 2),
                            try self.fetch(x + half, z + half, spacing * 2),
                        );
                        step = level * 2 - 1;
                    }
                    value = average + self.base.displacement(step, x, z);
                }
                // Insert after recursion: recursive calls can grow the hash map.
                // If allocation fails, successfully generated parents remain valid.
                try self.cache.put(key, value);
                self.generated_by_level[level] += 1;
                return value;
            }
        };

        pub fn init(allocator: std.mem.Allocator, superchunk: region.GenerationSuperchunk) !Self {
            try superchunk.validate();
            var self = Self{ .allocator = allocator, .superchunk = superchunk, .current = try Grid.init(allocator, region.side) };
            for (0..self.current.width) |iz| {
                const z = @as(i64, @intCast(iz)) * region.side - self.current.padding;
                for (0..self.current.width) |ix| {
                    const x = @as(i64, @intCast(ix)) * region.side - self.current.padding;
                    self.current.values[iz * self.current.width + ix] = self.displacement(0, x, z);
                }
            }
            self.generated_samples = self.current.values.len;
            return self;
        }

        pub fn deinit(self: *Self) void {
            if (self.pending) |*pending_grid| pending_grid.deinit();
            self.current.deinit();
            self.* = undefined;
        }

        pub fn grid(self: *const Self) Grid {
            return self.pending orelse self.current;
        }

        pub fn displacement(self: *const Self, step: usize, x: i64, z: i64) i32 {
            const origin = self.superchunk.voxelOrigin();
            return position.hashToSignedRange(position.hash2D(position.mixSeed(self.superchunk.seed, step), origin.x + x, origin.z + z), displacement_steps[step]);
        }

        fn mean2(a: i32, b: i32) i32 {
            return @intCast(@divTrunc(@as(i64, a) + b, 2));
        }

        fn mean4(a: i32, b: i32, c: i32, d: i32) i32 {
            return @intCast(@divTrunc(@as(i64, a) + b + c + d, 4));
        }

        fn firstSquare(self: *const Self, x: i64, z: i64, half: i64) i32 {
            const horizontal = @mod(@divExact(x, half), 2) == 1;
            const a = if (horizontal) self.current.at(x - half, z) else self.current.at(x, z - half);
            const b = if (horizontal) self.current.at(x + half, z) else self.current.at(x, z + half);
            return mean2(a, b) + self.displacement(1, x, z);
        }

        fn diamond(self: *const Self, x: i64, z: i64, half: i64, step: usize) i32 {
            return mean4(self.current.at(x - half, z - half), self.current.at(x + half, z - half), self.current.at(x - half, z + half), self.current.at(x + half, z + half)) + self.displacement(step, x, z);
        }

        fn diamondNeighbor(self: *const Self, target: Grid, x: i64, z: i64, half: i64) i32 {
            // Only the outermost support row can need a diamond outside the
            // pending grid. Its coarse parents are still in the previous grid.
            return target.sample(x, z) orelse self.diamond(x, z, half, self.next_step - 1);
        }

        /// Runs exactly one configured operation. Completed old samples are copied
        /// unchanged; a failed allocation leaves the previous state usable.
        pub fn advance(self: *Self) !void {
            if (self.current.resolution == 1) return error.FinestResolution;
            if (self.next_step >= displacement_steps.len) return error.InsufficientDisplacementSteps;
            const first_pass = self.pending == null;
            const half: i64 = self.current.resolution / 2;
            if (first_pass) {
                self.pending = try Grid.init(self.allocator, @intCast(half));
                const target = &self.pending.?;
                for (0..target.width) |iz| {
                    const z = @as(i64, @intCast(iz)) * half - target.padding;
                    for (0..target.width) |ix| {
                        const x = @as(i64, @intCast(ix)) * half - target.padding;
                        if (@mod(x, self.current.resolution) == 0 and @mod(z, self.current.resolution) == 0)
                            target.values[iz * target.width + ix] = self.current.at(x, z);
                    }
                }
            }
            const target = &self.pending.?;
            const first_level = self.current.resolution == region.side;
            const square_pass = if (first_level) first_pass else !first_pass;
            for (0..target.width) |iz| {
                const z = @as(i64, @intCast(iz)) * half - target.padding;
                const odd_z = @mod(@divExact(z, half), 2) == 1;
                for (0..target.width) |ix| {
                    const x = @as(i64, @intCast(ix)) * half - target.padding;
                    const odd_x = @mod(@divExact(x, half), 2) == 1;
                    if (square_pass) {
                        if (odd_x == odd_z) continue;
                        if (first_level) {
                            target.values[iz * target.width + ix] = self.firstSquare(x, z, half);
                        } else {
                            const a = if (odd_x) self.current.at(x - half, z) else self.current.at(x, z - half);
                            const b = if (odd_x) self.current.at(x + half, z) else self.current.at(x, z + half);
                            const c = if (odd_x) self.diamondNeighbor(target.*, x, z - half, half) else self.diamondNeighbor(target.*, x - half, z, half);
                            const d = if (odd_x) self.diamondNeighbor(target.*, x, z + half, half) else self.diamondNeighbor(target.*, x + half, z, half);
                            target.values[iz * target.width + ix] = mean4(a, b, c, d) + self.displacement(self.next_step, x, z);
                        }
                    } else {
                        if (!odd_x or !odd_z) continue;
                        target.values[iz * target.width + ix] = if (first_level)
                            mean4(target.at(x - half, z), target.at(x + half, z), target.at(x, z - half), target.at(x, z + half)) + self.displacement(self.next_step, x, z)
                        else
                            self.diamond(x, z, half, self.next_step);
                    }
                    self.generated_samples += 1;
                }
            }
            self.next_step += 1;
            target.phase = if (!first_pass) .complete else if (square_pass) .square else .diamond;
            if (!first_pass) {
                self.current.deinit();
                self.current = target.*;
                self.pending = null;
            }
        }

        pub fn refineTo(self: *Self, resolution: u32) !void {
            const level = try region.levelForResolution(resolution);
            if (2 * level >= displacement_steps.len) return error.InsufficientDisplacementSteps;
            while (self.current.resolution > resolution) try self.advance();
        }

        pub fn refineToComptime(self: *Self, comptime resolution: u32) !void {
            comptime {
                const level = region.levelForResolution(resolution) catch @compileError("Invalid resolution");
                if (2 * level >= displacement_steps.len) @compileError("Insufficient displacement steps for requested resolution");
            }
            try self.refineTo(resolution);
        }

        /// Samples the inclusive 0..4096 generation domain without exposing
        /// neighboring parent support. Returns null until that sample exists.
        pub fn sample(self: *const Self, x: u32, z: u32) ?i32 {
            if (x > region.side or z > region.side) return null;
            return self.grid().sample(x, z);
        }

        /// Owned crop at requested spacing, even if the cache is already finer.
        /// The positive 4096 boundary belongs only to generation storage.
        pub fn result(self: *Self, allocator: std.mem.Allocator, resolution: u32) !region.Result {
            return self.resultArea(allocator, .{ .x = 0, .z = 0, .width = region.side, .height = region.side }, resolution);
        }

        pub fn resultChunk(self: *Self, allocator: std.mem.Allocator, chunk_x: u32, chunk_z: u32, resolution: u32) !region.Result {
            return self.resultChunks(allocator, .{ .x = chunk_x, .z = chunk_z, .width = 1, .height = 1 }, resolution);
        }

        /// Bounds are in local chunk units, each within [0, 16).
        pub fn resultChunks(self: *Self, allocator: std.mem.Allocator, chunks: region.Area, resolution: u32) !region.Result {
            try chunks.validate(region.chunks_per_side);
            return self.resultArea(allocator, .{
                .x = chunks.x * region.voxels_per_chunk,
                .z = chunks.z * region.voxels_per_chunk,
                .width = chunks.width * region.voxels_per_chunk,
                .height = chunks.height * region.voxels_per_chunk,
            }, resolution);
        }

        /// Bounds are local voxel coordinates, with an exclusive upper bound.
        /// Area origins and extents must align to the requested sample spacing.
        /// Refinement currently updates the complete superchunk cache; extraction
        /// allocates only the selected rectangle and never changes stored samples.
        pub fn resultArea(self: *Self, allocator: std.mem.Allocator, area: region.Area, resolution: u32) !region.Result {
            try region.validateResolution(resolution);
            try area.validate(region.side);
            if (area.x % resolution != 0 or area.z % resolution != 0 or area.width % resolution != 0 or area.height % resolution != 0)
                return error.UnalignedArea;
            try self.refineTo(resolution);
            const width: usize = area.width / resolution;
            const height: usize = area.height / resolution;
            const values = try allocator.alloc(i32, width * height);
            for (0..height) |z| {
                for (0..width) |x| values[z * width + x] = self.current.at(area.x + @as(i64, @intCast(x)) * resolution, area.z + @as(i64, @intCast(z)) * resolution);
            }
            const origin = self.superchunk.voxelOrigin();
            return .{ .allocator = allocator, .origin = .{ .x = origin.x + area.x, .z = origin.z + area.z }, .resolution = resolution, .width = width, .height = height, .values = values };
        }

        /// Stateless convenience entry point; destroys support storage on return.
        pub fn generate(allocator: std.mem.Allocator, superchunk: region.GenerationSuperchunk, resolution: u32) !region.Result {
            // Validate before allocating root storage.
            const level = try region.levelForResolution(resolution);
            if (2 * level >= displacement_steps.len) return error.InsufficientDisplacementSteps;
            var generator = try Self.init(allocator, superchunk);
            defer generator.deinit();
            return generator.result(allocator, resolution);
        }
    };
}
