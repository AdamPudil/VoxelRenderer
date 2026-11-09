//! Reproducible stationary captures. Timings keep their original four-column CSV.
const std = @import("std");

pub const Options = struct {
    frames: u32 = 0,
    visible: bool = false,
    warmup: u32 = 120,
    settle: u32 = 60,
    max_frames: u32 = 10000,
    position: ?[3]f32 = null,
    angles: [2]f32 = .{ 3.14, 0 }, // yaw, pitch, radians
    size: ?[2]u32 = null,
    swap_interval: ?i32 = null, // null preserves GLFW/platform default
    diagnostic_stride: u32 = 0,

    pub fn parse(self: *Options, arg: []const u8) !bool {
        if (std.mem.eql(u8, arg, "--benchmark-visible")) {
            self.visible = true;
        } else if (value(arg, "--benchmark-frames=")) |v| {
            self.frames = try positive(v);
        } else if (value(arg, "--benchmark-warmup=")) |v| {
            self.warmup = try std.fmt.parseInt(u32, v, 10);
        } else if (value(arg, "--benchmark-settle=")) |v| {
            self.settle = try positive(v);
        } else if (value(arg, "--benchmark-max-frames=")) |v| {
            self.max_frames = try positive(v);
        } else if (value(arg, "--camera=")) |v| {
            self.position = try vector(3, v);
            for (self.position.?) |component| if (@abs(component) > 1000000) return error.CameraOutOfRange;
        } else if (value(arg, "--camera-angles=")) |v| {
            self.angles = try vector(2, v);
            if (@abs(self.angles[1]) > 1.5) return error.InvalidPitch;
        } else if (value(arg, "--framebuffer=")) |v| {
            var parts = std.mem.splitScalar(u8, v, 'x');
            const width = try positive(parts.next() orelse return error.InvalidFramebuffer);
            const height = try positive(parts.next() orelse return error.InvalidFramebuffer);
            if (parts.next() != null or width > 16384 or height > 16384) return error.InvalidFramebuffer;
            self.size = .{ width, height };
        } else if (value(arg, "--swap-interval=")) |v| {
            self.swap_interval = try std.fmt.parseInt(i32, v, 10);
            if (self.swap_interval.? < 0 or self.swap_interval.? > 1) return error.InvalidSwapInterval;
        } else if (value(arg, "--direct-diagnostics=")) |v| {
            self.diagnostic_stride = try positive(v);
            if (!std.math.isPowerOfTwo(self.diagnostic_stride) or self.diagnostic_stride > 65536) return error.InvalidDiagnosticStride;
        } else return false;
        return true;
    }
    fn value(arg: []const u8, prefix: []const u8) ?[]const u8 {
        return if (std.mem.startsWith(u8, arg, prefix)) arg[prefix.len..] else null;
    }
    fn positive(v: []const u8) !u32 {
        const n = try std.fmt.parseInt(u32, v, 10);
        if (n == 0) return error.ExpectedPositiveInteger;
        return n;
    }
    fn vector(comptime n: usize, v: []const u8) ![n]f32 {
        var parts = std.mem.splitScalar(u8, v, ',');
        var result: [n]f32 = undefined;
        for (&result) |*component| {
            component.* = try std.fmt.parseFloat(f32, parts.next() orelse return error.InvalidCamera);
            if (!std.math.isFinite(component.*)) return error.InvalidCamera;
        }
        if (parts.next() != null) return error.InvalidCamera;
        return result;
    }
};

pub const Phase = enum { settling, warmup, measured, unstable, interactive };
pub const Run = struct {
    options: Options,
    stable: u32 = 0,
    warmed: u32 = 0,
    measured: u32 = 0,
    first_measured: ?u64 = null,
    last_measured: ?u64 = null,
    previous: ?[2]u64 = null,
    invalid: bool = false,

    /// Called once for each rendered frame, with the revisions used by that draw.
    pub fn advance(self: *Run, frame: u64, ready: bool, geometry: u64, lights: u64) Phase {
        if (self.options.frames == 0) return .interactive;
        const revisions = [2]u64{ geometry, lights };
        const same = if (self.previous) |old| std.meta.eql(old, revisions) else false;
        self.previous = revisions;
        if (self.measured > 0 and (!same or !ready)) self.invalid = true;
        if (self.invalid) return .unstable;
        if (!same or !ready) {
            self.stable = 0;
            self.warmed = 0;
            return .settling;
        }
        if (self.stable < self.options.settle) {
            self.stable += 1;
            return .settling;
        }
        if (self.warmed < self.options.warmup) {
            self.warmed += 1;
            return .warmup;
        }
        self.measured += 1;
        if (self.first_measured == null) self.first_measured = frame;
        self.last_measured = frame;
        return .measured;
    }
    pub fn complete(self: Run) bool {
        return self.options.frames > 0 and self.measured == self.options.frames and !self.invalid;
    }
};

pub fn writeJson(path: []const u8, object: anytype) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var writer = std.io.bufferedWriter(file.writer());
    try std.json.stringify(object, .{ .whitespace = .indent_2 }, writer.writer());
    try writer.writer().writeByte('\n');
    try writer.flush();
}

pub const FrameLog = struct {
    file: std.fs.File,
    writer: std.io.BufferedWriter(16384, std.fs.File.Writer),
    pub fn init(path: []const u8) !FrameLog {
        const file = try std.fs.cwd().createFile(path, .{});
        errdefer file.close();
        var self = FrameLog{ .file = file, .writer = .{ .unbuffered_writer = file.writer() } };
        try self.writer.writer().writeAll("frame,phase,geometry_revision,light_revision,cache_frame,cache_valid_from,geometry_ready,x,y,z,yaw,pitch,width,height,upload_bytes,gpu_bytes\n");
        return self;
    }
    pub fn deinit(self: *FrameLog) void {
        self.writer.flush() catch |err| std.debug.print("Capture frame log flush failed: {s}\n", .{@errorName(err)});
        self.file.close();
    }
};

test "benchmark validates camera, framebuffer and sampled instrumentation options" {
    var o = Options{};
    try std.testing.expect(try o.parse("--camera=-12,40,7.5"));
    try std.testing.expectEqual(@as(f32, -12), o.position.?[0]);
    try std.testing.expect(try o.parse("--framebuffer=1920x1008"));
    try std.testing.expect(try o.parse("--direct-diagnostics=64"));
    try std.testing.expectError(error.InvalidDiagnosticStride, o.parse("--direct-diagnostics=3"));
    try std.testing.expectError(error.InvalidCamera, o.parse("--camera=nan,0,0"));
    try std.testing.expectError(error.InvalidCamera, o.parse("--camera=0,0,0,1"));
    try std.testing.expectError(error.InvalidSwapInterval, o.parse("--swap-interval=2"));
    try std.testing.expectError(error.InvalidPitch, o.parse("--camera-angles=0,2"));
    try std.testing.expect(!try o.parse("--unrelated"));
}

test "capture requires published stable revisions, restarts warmup, rejects measured transitions" {
    var run = Run{ .options = .{ .frames = 2, .settle = 1, .warmup = 1 } };
    try std.testing.expectEqual(Phase.settling, run.advance(1, false, 1, 1));
    try std.testing.expectEqual(Phase.settling, run.advance(2, true, 1, 1));
    try std.testing.expectEqual(Phase.warmup, run.advance(3, true, 1, 1));
    try std.testing.expectEqual(Phase.settling, run.advance(4, true, 2, 1));
    try std.testing.expectEqual(Phase.settling, run.advance(5, true, 2, 1));
    try std.testing.expectEqual(Phase.warmup, run.advance(6, true, 2, 1));
    try std.testing.expectEqual(Phase.measured, run.advance(7, true, 2, 1));
    try std.testing.expectEqual(Phase.measured, run.advance(8, true, 2, 1));
    try std.testing.expect(run.complete());
    try std.testing.expectEqual(@as(?u64, 7), run.first_measured);
    try std.testing.expectEqual(Phase.unstable, run.advance(9, true, 2, 2));
    try std.testing.expect(!run.complete());
}

test "JSON sidecar escapes strings and preserves capture settings" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, "capture.meta.json" });
    defer std.testing.allocator.free(path);
    try writeJson(path, .{ .gpu = "driver \"quoted\"\nline", .benchmark = Options{ .frames = 300, .position = .{ -8, 32, 8 } } });
    const contents = try temp.dir.readFileAlloc(std.testing.allocator, "capture.meta.json", 8192);
    defer std.testing.allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, contents, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("driver \"quoted\"\nline", parsed.value.object.get("gpu").?.string);
    try std.testing.expectEqual(@as(i64, 300), parsed.value.object.get("benchmark").?.object.get("frames").?.integer);
}
