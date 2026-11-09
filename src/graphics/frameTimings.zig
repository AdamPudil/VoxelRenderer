//! Opt-in main-thread wall times and asynchronous OpenGL pass timings.
//! Query results are read only when available; busy slots are never overwritten.
const std = @import("std");
const c = @cImport({
    @cInclude("GL/glew.h");
});

pub const CpuStage = enum { input, streaming, editing, prepare, world, lighting_cache, gi, menu, swap, housekeeping };
pub const GpuStage = enum { prepare, world, lighting_cache, gi, menu };
const cpu_count = std.meta.fields(CpuStage).len;
const gpu_count = std.meta.fields(GpuStage).len;
const query_count = gpu_count * 2;
const ring_size = 8;
const batch_size = 120;
const CsvWriter = std.io.BufferedWriter(16384, std.fs.File.Writer);

pub const Options = struct {
    cpu: bool = false,
    gpu: bool = false,
    csv_path: ?[]const u8 = null,
};

fn milliseconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

const Summary = struct {
    median: f64,
    p95: f64,
    p99: f64,
    max: f64,

    fn from(values: []f64) Summary {
        std.debug.assert(values.len > 0);
        std.mem.sort(f64, values, {}, std.sort.asc(f64));
        const middle = values.len / 2;
        return .{
            .median = if (values.len % 2 == 0) (values[middle - 1] + values[middle]) / 2 else values[middle],
            .p95 = values[(values.len * 95 + 99) / 100 - 1],
            .p99 = values[(values.len * 99 + 99) / 100 - 1],
            .max = values[values.len - 1],
        };
    }
};

fn Batch(comptime Stage: type) type {
    return struct {
        const Self = @This();
        const columns = std.meta.fields(Stage).len + 1;
        samples: [batch_size][columns]f64 = undefined,
        count: usize = 0,

        fn add(self: *Self, sample: [columns]f64, domain: []const u8) void {
            self.samples[self.count] = sample;
            self.count += 1;
            if (self.count == batch_size) self.report(domain);
        }

        fn report(self: *Self, domain: []const u8) void {
            if (self.count == 0) return;
            std.debug.print("{s} ms ({d} samples): stage median / p95 / p99 / max\n", .{ domain, self.count });
            for (0..columns) |column| {
                var values: [batch_size]f64 = undefined;
                for (self.samples[0..self.count], 0..) |sample, i| values[i] = sample[column];
                const summary = Summary.from(values[0..self.count]);
                const name = if (column == columns - 1) "total" else @tagName(@as(Stage, @enumFromInt(column)));
                std.debug.print("  {s}: {d:.3} / {d:.3} / {d:.3} / {d:.3}\n", .{ name, summary.median, summary.p95, summary.p99, summary.max });
            }
            self.count = 0;
        }
    };
}

pub const Timings = struct {
    options: Options,
    timer: ?std.time.Timer = null,
    cpu_values: [cpu_count + 1]f64 = .{0} ** (cpu_count + 1),
    cpu_last: u64 = 0,
    interval_timer: ?std.time.Timer = null,
    previous_begin: ?u64 = null,
    frame: u64 = 0,
    queries: [ring_size][query_count]c_uint = .{.{0} ** query_count} ** ring_size,
    pending: [ring_size]bool = .{false} ** ring_size,
    frame_ids: [ring_size]u64 = .{0} ** ring_size,
    cursor: usize = 0,
    recording: bool = false,
    gpu_started: [gpu_count]bool = .{false} ** gpu_count,
    gpu_ended: [gpu_count]bool = .{false} ** gpu_count,
    skipped_gpu: u64 = 0,
    cpu_batch: Batch(CpuStage) = .{},
    gpu_batch: Batch(GpuStage) = .{},
    csv_file: ?std.fs.File = null,
    csv: ?CsvWriter = null,

    /// Requires a current GL context only when GPU profiling is enabled.
    pub fn init(options: Options) !Timings {
        var self = Timings{ .options = options };
        if (options.cpu) {
            self.timer = try std.time.Timer.start();
            self.interval_timer = try std.time.Timer.start();
        }
        if (options.csv_path) |path| {
            self.csv_file = try std.fs.cwd().createFile(path, .{});
            errdefer self.csv_file.?.close();
            self.csv = .{ .unbuffered_writer = self.csv_file.?.writer() };
            try self.csv.?.writer().writeAll("frame,domain,stage,ms\n");
        }
        if (options.gpu) {
            var bits: c_int = 0;
            c.__glewGetQueryiv.?(c.GL_TIMESTAMP, c.GL_QUERY_COUNTER_BITS, &bits);
            if (bits == 0) {
                std.debug.print("GPU timestamp queries unsupported; GPU profiling disabled.\n", .{});
                self.options.gpu = false;
            } else c.__glewGenQueries.?(ring_size * query_count, @ptrCast(&self.queries));
        }
        return self;
    }

    pub fn deinit(self: *Timings) void {
        if (self.options.gpu) {
            self.collect();
            var outstanding: usize = 0;
            for (self.pending) |pending| outstanding += @intFromBool(pending);
            std.debug.print("GPU profiling: {d} frames skipped (query ring busy), {d} pending at shutdown.\n", .{ self.skipped_gpu, outstanding });
            c.__glewDeleteQueries.?(ring_size * query_count, @ptrCast(&self.queries));
        }
        self.cpu_batch.report("CPU wall");
        self.gpu_batch.report("GPU passes");
        if (self.csv) |*csv| csv.flush() catch |err| std.debug.print("Profile CSV flush failed: {s}\n", .{@errorName(err)});
        if (self.csv_file) |file| file.close();
    }

    pub fn begin(self: *Timings, frame: u64) void {
        self.closeInterval();
        self.frame = frame;
        if (self.interval_timer) |*timer| self.previous_begin = timer.read();
        if (self.options.gpu) {
            self.collect();
            self.reserveGpuFrame(frame);
        }
        if (self.timer) |*timer| {
            timer.reset();
            self.cpu_last = 0;
            self.cpu_values = .{0} ** (cpu_count + 1);
        }
    }

    fn reserveGpuFrame(self: *Timings, frame: u64) void {
        self.recording = false;
        // Use any free slot, even when earlier frames are still pending.
        for (0..ring_size) |offset| {
            const slot = (self.cursor + offset) % ring_size;
            if (!self.pending[slot]) {
                self.cursor = slot;
                self.recording = true;
                self.frame_ids[slot] = frame;
                break;
            }
        }
        if (!self.recording) self.skipped_gpu += 1;
        self.gpu_started = .{false} ** gpu_count;
        self.gpu_ended = .{false} ** gpu_count;
    }

    /// End the next exclusive CPU stage. Values include driver calls and waits.
    pub fn cpuEnd(self: *Timings, stage: CpuStage) void {
        if (self.timer) |*timer| {
            const now = timer.read();
            self.cpu_values[@intFromEnum(stage)] += milliseconds(now - self.cpu_last);
            self.cpu_last = now;
        }
    }

    pub fn gpuBegin(self: *Timings, stage: GpuStage) void {
        if (!self.recording) return;
        const index: usize = @intFromEnum(stage);
        std.debug.assert(!self.gpu_started[index]);
        self.gpu_started[index] = true;
        c.__glewQueryCounter.?(self.queries[self.cursor][index * 2], c.GL_TIMESTAMP);
    }

    pub fn gpuEnd(self: *Timings, stage: GpuStage) void {
        if (!self.recording) return;
        const index: usize = @intFromEnum(stage);
        std.debug.assert(self.gpu_started[index] and !self.gpu_ended[index]);
        self.gpu_ended[index] = true;
        c.__glewQueryCounter.?(self.queries[self.cursor][index * 2 + 1], c.GL_TIMESTAMP);
    }

    /// Called after the last GPU pass, before presentation.
    pub fn gpuSubmit(self: *Timings) void {
        if (!self.recording) return;
        for (self.gpu_ended) |ended| std.debug.assert(ended);
        self.pending[self.cursor] = true;
        self.cursor = (self.cursor + 1) % ring_size;
        self.recording = false;
    }

    pub fn end(self: *Timings) void {
        if (!self.options.cpu) return;
        self.cpuEnd(.housekeeping);
        self.cpu_values[cpu_count] = milliseconds(self.cpu_last);
        self.writeSample(CpuStage, "cpu", self.frame, self.cpu_values);
        self.cpu_batch.add(self.cpu_values, "CPU wall");
    }

    /// Close the preceding frame's full interval, including profiler/log overhead.
    /// Called at the next begin, or once before benchmark shutdown/draining.
    pub fn closeInterval(self: *Timings) void {
        const start = self.previous_begin orelse return;
        self.previous_begin = null;
        const ms = milliseconds(self.interval_timer.?.read() - start);
        // Separate domain preserves consumers that sum existing CPU stages.
        if (self.csv) |*csv| {
            csv.writer().print("{d},cadence,frame_interval,{d:.6}\n", .{ self.frame, ms }) catch |err| {
                std.debug.print("Profile interval write failed: {s}\n", .{@errorName(err)});
                self.csv = null;
            };
        }
    }

    /// Poll once; never flush, finish, spin or wait for the GPU.
    pub fn collect(self: *Timings) void {
        if (!self.options.gpu) return;
        for (0..ring_size) |slot| {
            if (!self.pending[slot]) continue;
            // Check every query, so no GL_QUERY_RESULT read can block.
            var ready = true;
            for (self.queries[slot]) |query| {
                var available: c_int = 0;
                c.__glewGetQueryObjectiv.?(query, c.GL_QUERY_RESULT_AVAILABLE, &available);
                if (available == 0) {
                    ready = false;
                    break;
                }
            }
            if (!ready) continue;
            var values: [gpu_count + 1]f64 = .{0} ** (gpu_count + 1);
            for (0..gpu_count) |index| {
                var start: u64 = 0;
                var finish: u64 = 0;
                c.__glewGetQueryObjectui64v.?(self.queries[slot][index * 2], c.GL_QUERY_RESULT, &start);
                c.__glewGetQueryObjectui64v.?(self.queries[slot][index * 2 + 1], c.GL_QUERY_RESULT, &finish);
                values[index] = milliseconds(finish -% start);
                values[gpu_count] += values[index];
            }
            self.writeSample(GpuStage, "gpu", self.frame_ids[slot], values);
            self.gpu_batch.add(values, "GPU passes");
            self.pending[slot] = false;
        }
    }

    pub fn pendingCount(self: *const Timings) usize {
        var count: usize = 0;
        for (self.pending) |pending| count += @intFromBool(pending);
        return count;
    }

    fn writeSample(self: *Timings, comptime Stage: type, domain: []const u8, frame: u64, values: [std.meta.fields(Stage).len + 1]f64) void {
        if (self.csv) |*csv| {
            for (values, 0..) |value, i| {
                const name = if (i == values.len - 1) "total" else @tagName(@as(Stage, @enumFromInt(i)));
                csv.writer().print("{d},{s},{s},{d:.6}\n", .{ frame, domain, name, value }) catch |err| {
                    std.debug.print("Profile CSV write failed: {s}; disabling CSV output.\n", .{@errorName(err)});
                    self.csv = null;
                    return;
                };
            }
        }
    }
};

test "percentiles use nearest rank and median averages the middle pair" {
    var values = [_]f64{ 120, 1, 10, 2 };
    const s = Summary.from(&values);
    try std.testing.expectEqual(@as(f64, 6), s.median);
    try std.testing.expectEqual(@as(f64, 120), s.p95);
    try std.testing.expectEqual(@as(f64, 120), s.p99);
    var single = [_]f64{7};
    try std.testing.expectEqual(@as(f64, 7), Summary.from(&single).median);
    var full: [120]f64 = undefined;
    for (&full, 0..) |*value, i| value.* = @floatFromInt(i + 1);
    const p = Summary.from(&full);
    try std.testing.expectEqual(@as(f64, 60.5), p.median);
    try std.testing.expectEqual(@as(f64, 114), p.p95);
    try std.testing.expectEqual(@as(f64, 119), p.p99);
}

test "disabled profiling needs no GL context and records nothing" {
    var timings = try Timings.init(.{});
    defer timings.deinit();
    timings.begin(1);
    timings.cpuEnd(.input);
    timings.gpuBegin(.world);
    timings.gpuEnd(.world);
    timings.gpuSubmit();
    timings.end();
    try std.testing.expectEqual(@as(usize, 0), timings.cpu_batch.count);
    try std.testing.expectEqual(@as(usize, 0), timings.gpu_batch.count);
    try std.testing.expectEqual(@as(?std.time.Timer, null), timings.timer);
}

test "CPU stages add to total and CSV retains frame identity" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var timings = try Timings.init(.{ .cpu = true });
    timings.csv_file = try temp.dir.createFile("profile.csv", .{ .read = true });
    timings.csv = .{ .unbuffered_writer = timings.csv_file.?.writer() };
    defer timings.deinit();
    timings.begin(42);
    timings.cpuEnd(.input);
    timings.cpuEnd(.streaming);
    timings.end();
    try std.testing.expectEqual(@as(usize, 1), timings.cpu_batch.count);
    const sample = timings.cpu_batch.samples[0];
    var sum: f64 = 0;
    for (sample[0..cpu_count]) |value| sum += value;
    try std.testing.expectApproxEqAbs(sample[cpu_count], sum, 0.000001);
    try timings.csv.?.flush();
    try timings.csv_file.?.seekTo(0);
    const contents = try timings.csv_file.?.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "42,cpu,input,") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "42,cpu,total,") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, ",gpu,") == null);
}

test "busy GPU ring skips without overwriting pending frames and reuses a free slot" {
    var timings = try Timings.init(.{});
    defer timings.deinit();
    timings.pending = .{true} ** ring_size;
    timings.frame_ids = .{99} ** ring_size;
    timings.reserveGpuFrame(100);
    try std.testing.expect(!timings.recording);
    try std.testing.expectEqual(@as(u64, 1), timings.skipped_gpu);
    for (timings.frame_ids) |frame| try std.testing.expectEqual(@as(u64, 99), frame);
    timings.pending[3] = false;
    timings.reserveGpuFrame(101);
    try std.testing.expect(timings.recording);
    try std.testing.expectEqual(@as(usize, 3), timings.cursor);
    try std.testing.expectEqual(@as(u64, 101), timings.frame_ids[3]);
    try std.testing.expectEqual(@as(u64, 1), timings.skipped_gpu);
}

test "full frame cadence is attributed to the originating frame and includes uninstrumented gaps" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var timings = try Timings.init(.{ .cpu = true });
    timings.csv_file = try temp.dir.createFile("cadence.csv", .{ .read = true });
    timings.csv = .{ .unbuffered_writer = timings.csv_file.?.writer() };
    defer timings.deinit();
    timings.begin(10);
    timings.end();
    std.Thread.sleep(std.time.ns_per_ms);
    timings.begin(11);
    timings.end();
    timings.closeInterval();
    timings.closeInterval(); // no duplicate final interval
    try timings.csv.?.flush();
    try timings.csv_file.?.seekTo(0);
    const contents = try timings.csv_file.?.readToEndAlloc(std.testing.allocator, 8192);
    defer std.testing.allocator.free(contents);
    var intervals: usize = 0;
    var rows = std.mem.splitScalar(u8, contents, '\n');
    while (rows.next()) |row| {
        if (std.mem.startsWith(u8, row, "10,cadence,frame_interval,")) {
            const ms = try std.fmt.parseFloat(f64, row["10,cadence,frame_interval,".len..]);
            try std.testing.expect(ms >= 1);
            intervals += 1;
        }
        if (std.mem.startsWith(u8, row, "11,cadence,frame_interval,")) intervals += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), intervals);
}
