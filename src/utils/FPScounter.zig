const std = @import("std");

pub const FpsCounter = struct {
    last_time: f64 = 0,
    accumulator: f64 = 0,
    frames: u32 = 0,
    fps: f64 = 0,

    enabled: bool = true,

    file: ?std.fs.File = null,
    writer: ?std.fs.File.Writer = null,

    pub fn init() !FpsCounter {
        var file = try std.fs.cwd().createFile("fps_log.txt", .{
            .truncate = false,
            .read = false,
        });

        return .{
            .last_time = now(),
            .file = file,
            .writer = file.writer(),
        };
    }

    pub fn toggle(self: *FpsCounter) void {
        self.enabled = !self.enabled;
    }

    pub fn update(self: *FpsCounter) void {
        const t = now();
        const dt = t - self.last_time;
        self.last_time = t;

        self.accumulator += dt;
        self.frames += 1;

        if (self.frames >= 50) {
            self.fps = @as(f64, @floatFromInt(self.frames)) / self.accumulator;

            if (self.enabled) {
                // terminal
                std.debug.print("FPS: {d:.2}\n", .{self.fps});

                // file
                if (self.writer) |w| {
                    _ = w.print("FPS: {d:.2}\n", .{self.fps}) catch {};
                }
            }

            // reset
            self.frames = 0;
            self.accumulator = 0;
        }
    }

    fn now() f64 {
        return @as(f64, @floatFromInt(std.time.nanoTimestamp())) / std.time.ns_per_s;
    }

    pub fn deinit(self: *FpsCounter) void {
        if (self.file) |f| {
            f.close();
        }
    }
};
