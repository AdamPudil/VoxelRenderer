//! Run with the current EGL context; synchronization is confined to this test.
const std = @import("std");
const profiling = @import("graphics/frameTimings.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});

pub fn run() !void {
    try @import("directDiagnosticChecks.zig").run();
    var path_buffer: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/tmp/voxel-profile-smoke-{d}.csv", .{std.time.nanoTimestamp()});
    defer std.fs.cwd().deleteFile(path) catch {};
    var timings = try profiling.Timings.init(.{ .cpu = true, .gpu = true, .csv_path = path });
    defer timings.deinit();
    if (!timings.options.gpu) return error.TimestampQueriesUnavailable;

    // More than two trips around the query ring. Check frame IDs survive reuse.
    for (1..25) |frame| {
        timings.begin(frame);
        if (!timings.recording) return error.UnexpectedQueryRingExhaustion;
        timings.cpuEnd(.input);
        for (std.enums.values(profiling.GpuStage)) |stage| {
            timings.gpuBegin(stage);
            c.glClearColor(0.1, 0.2, 0.3, 1);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            timings.gpuEnd(stage);
        }
        timings.gpuSubmit();
        timings.end();
        if (frame % 4 == 0) {
            // Only the test waits: production collect() must never synchronize.
            c.glFinish();
            timings.collect();
            if (timings.gpu_batch.count != frame) return error.MissingGpuSamples;
            for (timings.pending) |pending| if (pending) return error.QuerySlotNotReleased;
        }
    }
    if (timings.cpu_batch.count != 24) return error.MissingCpuSamples;
    if (timings.skipped_gpu != 0) return error.UnexpectedSkippedGpuSamples;
    for (timings.gpu_batch.samples[0..timings.gpu_batch.count]) |sample| {
        var sum: f64 = 0;
        for (sample[0 .. sample.len - 1]) |value| {
            if (!std.math.isFinite(value) or value < 0) return error.InvalidGpuDuration;
            sum += value;
        }
        if (sum != sample[sample.len - 1]) return error.InvalidGpuTotal;
    }
    try timings.csv.?.flush();
    const contents = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 65536);
    defer std.heap.page_allocator.free(contents);
    if (!std.mem.startsWith(u8, contents, "frame,domain,stage,ms\n")) return error.MissingCsvHeader;
    for (1..25) |frame| {
        var prefix_buffer: [80]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&prefix_buffer, "{d},gpu,total,", .{frame});
        var rows = std.mem.splitScalar(u8, contents, '\n');
        var matches: usize = 0;
        while (rows.next()) |row| {
            if (std.mem.startsWith(u8, row, prefix)) matches += 1;
        }
        if (matches != 1) return error.IncorrectGpuFrameIdentity;
    }
    if (c.glGetError() != c.GL_NO_ERROR) return error.ProfilingOpenGLError;
    std.debug.print("Profiling GPU checks passed: 24 CPU/GPU frames, ring reuse, CSV frame IDs.\n", .{});
}
