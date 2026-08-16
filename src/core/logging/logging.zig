const std = @import("std");

const c = @cImport({
    @cInclude("time.h");
});

pub const table = @import("table.zig");
pub const format = @import("format.zig");

const error_label = "\x1b[31m[!ERROR!]\x1b[0m";
const success_label = "\x1b[32m[SUCCESS]\x1b[0m";
const warning_label = "\x1b[33m[WARNING]\x1b[0m";
const info_label = "\x1b[34m[-INFO--]\x1b[0m";

const startup_message =
    "                       +------------------+\n" ++
    "                       |   \x1b[32mGame started\x1b[0m   |\n" ++
    "                       +------------------+\n\n";

pub var logger: Logging = undefined;

pub fn getTimestamp(buf: []u8) ![]const u8 {
    const raw = c.time(null);
    const info = c.localtime(&raw); // changed from gmtime
    if (info == null) return error.BadTime;

    const len = c.strftime(buf.ptr, buf.len, "%Y-%m-%d %H:%M:%S", info);
    if (len == 0) return error.StrftimeFailed;

    return buf[0..len];
}

pub const Logging = struct {
    file: std.fs.File.Writer = undefined,
    stage: format.ProductionStage = undefined,
    table: table.TableState = .{},

    const TIME_COLUMN_WIDTH: usize = 20;
    const TAG_COLUMN_WIDTH: usize = 9;

    pub fn init(self: *Logging, stage: format.ProductionStage) void {
        self.stage = stage;

        const cwd = std.fs.cwd();
        const logs_dir = cwd.openDir("logs", .{ .iterate = false }) catch |er| {
            std.debug.print("{s} Can't open logs directory: {any}", .{ error_label, er });
            return;
        };

        var fil: std.fs.File = undefined;

        switch (stage) {
            .RELEASE => {
                fil = logs_dir.createFile("game.log", .{ .truncate = true }) catch |er| {
                    std.debug.print("{s} Can't open log file: {any}", .{ error_label, er });
                    return;
                };
            },
            .TESTING => {
                fil = logs_dir.createFile("test.log", .{ .truncate = true }) catch |er| {
                    std.debug.print("{s} Can't open log file: {any}", .{ error_label, er });
                    return;
                };
            },
        }

        self.file = fil.writer();

        std.time.sleep(1_000_000);

        self.file.print(startup_message, .{}) catch |er| {
            std.debug.print("{s} Can't write to log file: {any}", .{ error_label, er });
        };
    }

    pub fn print(
        self: *Logging,
        messType: format.OutputType,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const outDesc = format.output_descriptors.get(messType);
        const normalDesc = format.output_descriptors.get(.NORMAL);

        const fullFmt =
            "[{s}] {s}{s} {s}" ++ fmt ++ "\n";

        var buffer: [32]u8 = undefined;
        const timestamp = getTimestamp(&buffer) catch "[TIME ERROR]";

        const fullArgs =
            .{
                timestamp,
                format.color_codes.get(outDesc.color),
                outDesc.label,
                format.color_codes.get(normalDesc.color),
            } ++ args;

        std.debug.print(fullFmt, fullArgs);

        self.file.print(fullFmt, fullArgs) catch |erro| {
            const errorDesc = format.output_descriptors.get(.ERROR);

            std.debug.print(
                "{s}{s} Can't write to log file: {any}{s}\n",
                .{
                    format.color_codes.get(errorDesc.color),
                    errorDesc.label,
                    erro,
                    format.color_codes.get(normalDesc.color),
                },
            );
        };
    }

    fn printRepeated(
        self: *Logging,
        character: u8,
        count: usize,
    ) void {
        var i: usize = 0;

        while (i < count) : (i += 1) {
            std.debug.print("{c}", .{character});

            self.file.print("{c}", .{character}) catch {};
        }
    }

    fn printBoth(
        self: *Logging,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        std.debug.print(fmt, args);

        self.file.print(fmt, args) catch |erro| {
            std.debug.print(
                "Failed to write table to log file: {any}\n",
                .{erro},
            );
        };
    }

    fn getTableWidth(self: *const Logging) usize {
        var width: usize = 0;

        switch (self.table.decoration) {
            .NONE => {
                width += TIME_COLUMN_WIDTH;
                width += 1;
                width += TAG_COLUMN_WIDTH;

                for (self.table.columns[0..self.table.column_count]) |column| {
                    width += 1;
                    width += column.width;
                }
            },

            .SIMPLE, .BOX, .FANCY => {
                // Opening border.
                width += 1;

                // Time and tag columns, including padding and closing borders.
                width += TIME_COLUMN_WIDTH + 3;
                width += TAG_COLUMN_WIDTH + 3;

                for (self.table.columns[0..self.table.column_count]) |column| {
                    width += column.width + 3;
                }
            },
        }

        return width;
    }

    fn printPadded(
        self: *Logging,
        text: []const u8,
        width: usize,
    ) void {
        const printed_length = @min(text.len, width);

        self.printBoth("{s}", .{text[0..printed_length]});

        if (printed_length < width) {
            self.printRepeated(' ', width - printed_length);
        }
    }

    pub fn printTableSeparator(self: *Logging) void {
        if (!self.table.active) {
            return;
        }

        switch (self.table.decoration) {
            .NONE => {
                self.printBoth("\n", .{});
            },

            .SIMPLE => {
                self.printBoth("|", .{});

                self.printRepeated('-', TIME_COLUMN_WIDTH + 2);
                self.printBoth("|", .{});

                self.printRepeated('-', TAG_COLUMN_WIDTH + 2);
                self.printBoth("|", .{});

                for (self.table.columns[0..self.table.column_count]) |column| {
                    self.printRepeated('-', column.width + 2);
                    self.printBoth("|", .{});
                }

                self.printBoth("\n", .{});
            },

            .BOX => {
                self.printBoth("+", .{});

                self.printRepeated('-', TIME_COLUMN_WIDTH + 2);
                self.printBoth("+", .{});

                self.printRepeated('-', TAG_COLUMN_WIDTH + 2);
                self.printBoth("+", .{});

                for (self.table.columns[0..self.table.column_count]) |column| {
                    self.printRepeated('-', column.width + 2);
                    self.printBoth("+", .{});
                }

                self.printBoth("\n", .{});
            },

            .FANCY => {
                self.printBoth("#", .{});

                self.printRepeated('=', TIME_COLUMN_WIDTH + 2);
                self.printBoth("#", .{});

                self.printRepeated('=', TAG_COLUMN_WIDTH + 2);
                self.printBoth("#", .{});

                for (self.table.columns[0..self.table.column_count]) |column| {
                    self.printRepeated('=', column.width + 2);
                    self.printBoth("#", .{});
                }

                self.printBoth("\n", .{});
            },
        }
    }
    fn printTableName(self: *Logging) void {
        if (self.table.name.len == 0) {
            return;
        }

        const table_width = self.getTableWidth();

        switch (self.table.decoration) {
            .NONE => {
                self.printBoth("{s}\n", .{self.table.name});
            },

            .SIMPLE => {
                self.printBoth("| ", .{});
                self.printPadded(
                    self.table.name,
                    table_width - 4,
                );
                self.printBoth(" |\n", .{});
            },

            .BOX => {
                self.printBoth("+", .{});
                self.printRepeated('-', table_width - 2);
                self.printBoth("+\n", .{});

                self.printBoth("| ", .{});
                self.printPadded(
                    self.table.name,
                    table_width - 4,
                );
                self.printBoth(" |\n", .{});
            },

            .FANCY => {
                self.printBoth("#", .{});
                self.printRepeated('=', table_width - 2);
                self.printBoth("#\n", .{});

                self.printBoth("# ", .{});
                self.printPadded(
                    self.table.name,
                    table_width - 4,
                );
                self.printBoth(" #\n", .{});
            },
        }
    }
    pub fn printTableHeader(
        self: *Logging,
        name: []const u8,
        decoration: table.TableDecoration,
        columns: []const table.TableColumn,
    ) void {
        if (columns.len > table.MAX_TABLE_COLUMNS) {
            std.debug.print(
                "Table has too many columns. Maximum is {}.\n",
                .{table.MAX_TABLE_COLUMNS},
            );

            return;
        }

        self.table.active = true;
        self.table.name = name;
        self.table.decoration = decoration;
        self.table.column_count = columns.len;

        for (columns, 0..) |column, index| {
            self.table.columns[index] = column;
        }

        self.printTableName();

        if (decoration != .NONE and decoration != .BOX) {
            self.printTableSeparator();
        }

        switch (decoration) {
            .NONE => {
                self.printPadded("TIME", TIME_COLUMN_WIDTH);
                self.printBoth(" ", .{});

                self.printPadded("TAG", TAG_COLUMN_WIDTH);

                for (columns) |column| {
                    self.printBoth(" ", .{});
                    self.printPadded(column.name, column.width);
                }

                self.printBoth("\n", .{});
            },

            .SIMPLE, .BOX, .FANCY => {
                self.printBoth("| ", .{});
                self.printPadded("TIME", TIME_COLUMN_WIDTH);

                self.printBoth(" | ", .{});
                self.printPadded("TAG", TAG_COLUMN_WIDTH);

                for (columns) |column| {
                    self.printBoth(" | ", .{});
                    self.printPadded(column.name, column.width);
                }

                self.printBoth(" |\n", .{});
            },
        }

        self.printTableSeparator();
    }

    pub fn printTableRow(
        self: *Logging,
        messType: format.OutputType,
        values: anytype,
    ) void {
        if (!self.table.active) {
            std.debug.print(
                "Cannot print table row: no table is active.\n",
                .{},
            );

            return;
        }

        const values_info = @typeInfo(@TypeOf(values));

        if (values_info != .@"struct" or !values_info.@"struct".is_tuple) {
            @compileError("printTableRow values must be a tuple.");
        }

        const fields = values_info.@"struct".fields;

        if (fields.len != self.table.column_count) {
            std.debug.print(
                "Invalid table row: expected {} values, received {}.\n",
                .{
                    self.table.column_count,
                    fields.len,
                },
            );

            return;
        }

        var timestamp_buffer: [32]u8 = undefined;
        const timestamp =
            getTimestamp(&timestamp_buffer) catch "[TIME ERROR]";

        const output_descriptor =
            format.output_descriptors.get(messType);

        switch (self.table.decoration) {
            .NONE => {
                self.printPadded(timestamp, TIME_COLUMN_WIDTH);
                self.printBoth(" ", .{});

                self.printPadded(
                    output_descriptor.label,
                    TAG_COLUMN_WIDTH,
                );
            },

            .SIMPLE, .BOX, .FANCY => {
                self.printBoth("| ", .{});
                self.printPadded(timestamp, TIME_COLUMN_WIDTH);

                self.printBoth(" | ", .{});

                const color_code =
                    format.color_codes.get(output_descriptor.color);

                const normal_descriptor =
                    format.output_descriptors.get(.NORMAL);

                const normal_code =
                    format.color_codes.get(normal_descriptor.color);

                // Colored terminal tag.
                std.debug.print(
                    "{s}",
                    .{color_code},
                );

                self.printPadded(
                    output_descriptor.label,
                    TAG_COLUMN_WIDTH,
                );

                std.debug.print(
                    "{s}",
                    .{normal_code},
                );
            },
        }

        inline for (fields, 0..) |field, index| {
            const value = @field(values, field.name);
            const column = self.table.columns[index];

            var value_buffer: [512]u8 = undefined;

            const value_string = std.fmt.bufPrint(
                &value_buffer,
                "{any}",
                .{value},
            ) catch "[FORMAT ERROR]";

            switch (self.table.decoration) {
                .NONE => {
                    self.printBoth(" ", .{});
                    self.printPadded(
                        value_string,
                        column.width,
                    );
                },

                .SIMPLE, .BOX, .FANCY => {
                    self.printBoth(" | ", .{});
                    self.printPadded(
                        value_string,
                        column.width,
                    );
                },
            }
        }

        switch (self.table.decoration) {
            .NONE => self.printBoth("\n", .{}),
            .SIMPLE, .BOX, .FANCY => self.printBoth(" |\n", .{}),
        }
    }

    pub fn endTable(self: *Logging) void {
        if (!self.table.active) {
            return;
        }

        switch (self.table.decoration) {
            .NONE => {
                self.printBoth("\n", .{});
            },

            .SIMPLE => {
                self.printTableSeparator();
            },

            .BOX => {
                self.printTableSeparator();
            },

            .FANCY => {
                self.printTableSeparator();

                const table_width = self.getTableWidth();

                self.printBoth("#", .{});
                self.printRepeated('=', table_width - 2);
                self.printBoth("#\n", .{});
            },
        }

        self.table.active = false;
        self.table.name = "";
        self.table.column_count = 0;
        self.table.decoration = .NONE;
    }
};

fn readTestLog(
    file: *std.fs.File,
    allocator: std.mem.Allocator,
) ![]u8 {
    try file.seekTo(0);
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

test "simple logging output" {
    const cwd = std.fs.cwd();

    try cwd.makePath("logs/tests");

    var log_file = try cwd.createFile(
        "logs/tests/simple_logging.log",
        .{
            .read = true,
            .truncate = true,
        },
    );
    defer log_file.close();

    var test_logger = Logging{
        .file = log_file.writer(),
        .stage = .TESTING,
    };

    test_logger.print(
        .INFO,
        "Simple logging test started.",
        .{},
    );

    test_logger.print(
        .SUCCESS,
        "Loaded {} default engine events.",
        .{@as(usize, 12)},
    );

    test_logger.print(
        .WARNING,
        "Event buffer is {} percent full.",
        .{@as(u8, 75)},
    );

    test_logger.print(
        .ERROR,
        "Example error with code {}.",
        .{@as(i32, -15)},
    );

    test_logger.print(
        .INFO,
        "String argument: {s}",
        .{"Hello from logging test"},
    );

    const file_size = try log_file.getEndPos();

    try std.testing.expect(file_size > 0);
}

test "none table with eigthteen rows" {
    const cwd = std.fs.cwd();

    try cwd.makePath("logs/tests");

    var log_file = try cwd.createFile(
        "logs/tests/fancy_table.log",
        .{
            .read = true,
            .truncate = true,
        },
    );
    defer log_file.close();

    var test_logger = Logging{
        .file = log_file.writer(),
        .stage = .TESTING,
    };

    const columns = [_]table.TableColumn{
        .{
            .name = "ID",
            .width = 2,
        },
        .{
            .name = "EVENT",
            .width = 62,
        },
        .{
            .name = "SYSTEM",
            .width = 38,
        },
        .{
            .name = "STATUS",
            .width = 30,
        },
        .{
            .name = "VALUE",
            .width = 3,
        },
    };

    test_logger.printTableHeader(
        "Fancy logging table test - 50 rows",
        .NONE,
        &columns,
    );

    var row_index: usize = 0;

    while (row_index < 19) : (row_index += 1) {
        var event_name_buffer: [64]u8 = undefined;

        const event_name = try std.fmt.bufPrint(
            &event_name_buffer,
            "ENGINE_EVENT_{d}",
            .{row_index},
        );

        const message_type: format.OutputType = switch (row_index % 4) {
            0 => .INFO,
            1 => .SUCCESS,
            2 => .WARNING,
            3 => .ERROR,
            else => unreachable,
        };

        const system_name: []const u8 = switch (row_index % 5) {
            0 => "CORE",
            1 => "RENDERING",
            2 => "WORLD",
            3 => "EVENTS",
            4 => "INPUT",
            else => unreachable,
        };

        const status: []const u8 = switch (message_type) {
            .INFO => "RUNNING",
            .SUCCESS => "READY",
            .WARNING => "DELAYED",
            .ERROR => "FAILED",
            .NORMAL => "NORMAL",
        };

        test_logger.printTableRow(
            message_type,
            .{
                row_index,
                event_name,
                system_name,
                status,
                row_index * 10,
            },
        );

        // Add a separator after every ten rows.
        if ((row_index + 1) % 10 == 0 and row_index != 49) {
            test_logger.printTableSeparator();
        }
    }

    test_logger.endTable();

    const file_size = try log_file.getEndPos();

    try std.testing.expect(file_size > 0);
    try std.testing.expect(!test_logger.table.active);
    try std.testing.expectEqual(
        @as(usize, 0),
        test_logger.table.column_count,
    );
}

test "box table with eigthteen rows" {
    const cwd = std.fs.cwd();

    try cwd.makePath("logs/tests");

    var log_file = try cwd.createFile(
        "logs/tests/fancy_table.log",
        .{
            .read = true,
            .truncate = true,
        },
    );
    defer log_file.close();

    var test_logger = Logging{
        .file = log_file.writer(),
        .stage = .TESTING,
    };

    const columns = [_]table.TableColumn{
        .{
            .name = "ID",
            .width = 2,
        },
        .{
            .name = "EVENT",
            .width = 62,
        },
        .{
            .name = "SYSTEM",
            .width = 38,
        },
        .{
            .name = "STATUS",
            .width = 30,
        },
        .{
            .name = "VALUE",
            .width = 3,
        },
    };

    test_logger.printTableHeader(
        "Fancy logging table test - 50 rows",
        .BOX,
        &columns,
    );

    var row_index: usize = 0;

    while (row_index < 19) : (row_index += 1) {
        var event_name_buffer: [64]u8 = undefined;

        const event_name = try std.fmt.bufPrint(
            &event_name_buffer,
            "ENGINE_EVENT_{d}",
            .{row_index},
        );

        const message_type: format.OutputType = switch (row_index % 4) {
            0 => .INFO,
            1 => .SUCCESS,
            2 => .WARNING,
            3 => .ERROR,
            else => unreachable,
        };

        const system_name: []const u8 = switch (row_index % 5) {
            0 => "CORE",
            1 => "RENDERING",
            2 => "WORLD",
            3 => "EVENTS",
            4 => "INPUT",
            else => unreachable,
        };

        const status: []const u8 = switch (message_type) {
            .INFO => "RUNNING",
            .SUCCESS => "READY",
            .WARNING => "DELAYED",
            .ERROR => "FAILED",
            .NORMAL => "NORMAL",
        };

        test_logger.printTableRow(
            message_type,
            .{
                row_index,
                event_name,
                system_name,
                status,
                row_index * 10,
            },
        );

        // Add a separator after every ten rows.
        if ((row_index + 1) % 10 == 0 and row_index != 49) {
            test_logger.printTableSeparator();
        }
    }

    test_logger.endTable();

    const file_size = try log_file.getEndPos();

    try std.testing.expect(file_size > 0);
    try std.testing.expect(!test_logger.table.active);
    try std.testing.expectEqual(
        @as(usize, 0),
        test_logger.table.column_count,
    );
}

test "simple table with eigthteen rows" {
    const cwd = std.fs.cwd();

    try cwd.makePath("logs/tests");

    var log_file = try cwd.createFile(
        "logs/tests/fancy_table.log",
        .{
            .read = true,
            .truncate = true,
        },
    );
    defer log_file.close();

    var test_logger = Logging{
        .file = log_file.writer(),
        .stage = .TESTING,
    };

    const columns = [_]table.TableColumn{
        .{
            .name = "ID",
            .width = 2,
        },
        .{
            .name = "EVENT",
            .width = 62,
        },
        .{
            .name = "SYSTEM",
            .width = 38,
        },
        .{
            .name = "STATUS",
            .width = 30,
        },
        .{
            .name = "VALUE",
            .width = 3,
        },
    };

    test_logger.printTableHeader(
        "Fancy logging table test - 50 rows",
        .SIMPLE,
        &columns,
    );

    var row_index: usize = 0;

    while (row_index < 19) : (row_index += 1) {
        var event_name_buffer: [64]u8 = undefined;

        const event_name = try std.fmt.bufPrint(
            &event_name_buffer,
            "ENGINE_EVENT_{d}",
            .{row_index},
        );

        const message_type: format.OutputType = switch (row_index % 4) {
            0 => .INFO,
            1 => .SUCCESS,
            2 => .WARNING,
            3 => .ERROR,
            else => unreachable,
        };

        const system_name: []const u8 = switch (row_index % 5) {
            0 => "CORE",
            1 => "RENDERING",
            2 => "WORLD",
            3 => "EVENTS",
            4 => "INPUT",
            else => unreachable,
        };

        const status: []const u8 = switch (message_type) {
            .INFO => "RUNNING",
            .SUCCESS => "READY",
            .WARNING => "DELAYED",
            .ERROR => "FAILED",
            .NORMAL => "NORMAL",
        };

        test_logger.printTableRow(
            message_type,
            .{
                row_index,
                event_name,
                system_name,
                status,
                row_index * 10,
            },
        );

        // Add a separator after every ten rows.
        if ((row_index + 1) % 10 == 0 and row_index != 49) {
            test_logger.printTableSeparator();
        }
    }

    test_logger.endTable();

    const file_size = try log_file.getEndPos();

    try std.testing.expect(file_size > 0);
    try std.testing.expect(!test_logger.table.active);
    try std.testing.expectEqual(
        @as(usize, 0),
        test_logger.table.column_count,
    );
}

test "fancy table with eigthteen rows" {
    const cwd = std.fs.cwd();

    try cwd.makePath("logs/tests");

    var log_file = try cwd.createFile(
        "logs/tests/fancy_table.log",
        .{
            .read = true,
            .truncate = true,
        },
    );
    defer log_file.close();

    var test_logger = Logging{
        .file = log_file.writer(),
        .stage = .TESTING,
    };

    const columns = [_]table.TableColumn{
        .{
            .name = "ID",
            .width = 2,
        },
        .{
            .name = "EVENT",
            .width = 62,
        },
        .{
            .name = "SYSTEM",
            .width = 38,
        },
        .{
            .name = "STATUS",
            .width = 30,
        },
        .{
            .name = "VALUE",
            .width = 3,
        },
    };

    test_logger.printTableHeader(
        "Fancy logging table test - 50 rows",
        .FANCY,
        &columns,
    );

    var row_index: usize = 0;

    while (row_index < 19) : (row_index += 1) {
        var event_name_buffer: [64]u8 = undefined;

        const event_name = try std.fmt.bufPrint(
            &event_name_buffer,
            "ENGINE_EVENT_{d}",
            .{row_index},
        );

        const message_type: format.OutputType = switch (row_index % 4) {
            0 => .INFO,
            1 => .SUCCESS,
            2 => .WARNING,
            3 => .ERROR,
            else => unreachable,
        };

        const system_name: []const u8 = switch (row_index % 5) {
            0 => "CORE",
            1 => "RENDERING",
            2 => "WORLD",
            3 => "EVENTS",
            4 => "INPUT",
            else => unreachable,
        };

        const status: []const u8 = switch (message_type) {
            .INFO => "RUNNING",
            .SUCCESS => "READY",
            .WARNING => "DELAYED",
            .ERROR => "FAILED",
            .NORMAL => "NORMAL",
        };

        test_logger.printTableRow(
            message_type,
            .{
                row_index,
                event_name,
                system_name,
                status,
                row_index * 10,
            },
        );

        // Add a separator after every ten rows.
        if ((row_index + 1) % 10 == 0 and row_index != 49) {
            test_logger.printTableSeparator();
        }
    }

    test_logger.endTable();

    const file_size = try log_file.getEndPos();

    try std.testing.expect(file_size > 0);
    try std.testing.expect(!test_logger.table.active);
    try std.testing.expectEqual(
        @as(usize, 0),
        test_logger.table.column_count,
    );
}
