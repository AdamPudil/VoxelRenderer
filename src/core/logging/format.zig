const std = @import("std");

pub const OutputType = enum {
    ERROR,
    SUCCESS,
    WARNING,
    INFO,
    NORMAL,
};

pub const ProductionStage = enum {
    RELEASE,
    TESTING,
};

pub const Color = enum {
    NORMAL,

    BLACK,
    RED,
    GREEN,
    YELLOW,
    BLUE,
    MAGENTA,
    CYAN,
    WHITE,

    BRIGHT_BLACK,
    BRIGHT_RED,
    BRIGHT_GREEN,
    BRIGHT_YELLOW,
    BRIGHT_BLUE,
    BRIGHT_MAGENTA,
    BRIGHT_CYAN,
    BRIGHT_WHITE,
};

pub const Format = enum {
    NORMAL,
    BOLD,
    DIM,
    ITALIC,
    UNDERLINE,
    BLINK,
    REVERSE,
    HIDDEN,
    STRIKETHROUGH,
};

pub const color_codes = std.EnumArray(Color, []const u8).init(.{
    .NORMAL = "\x1b[39m",

    .BLACK = "\x1b[30m",
    .RED = "\x1b[31m",
    .GREEN = "\x1b[32m",
    .YELLOW = "\x1b[33m",
    .BLUE = "\x1b[34m",
    .MAGENTA = "\x1b[35m",
    .CYAN = "\x1b[36m",
    .WHITE = "\x1b[37m",

    .BRIGHT_BLACK = "\x1b[90m",
    .BRIGHT_RED = "\x1b[91m",
    .BRIGHT_GREEN = "\x1b[92m",
    .BRIGHT_YELLOW = "\x1b[93m",
    .BRIGHT_BLUE = "\x1b[94m",
    .BRIGHT_MAGENTA = "\x1b[95m",
    .BRIGHT_CYAN = "\x1b[96m",
    .BRIGHT_WHITE = "\x1b[97m",
});

pub const format_codes = std.EnumArray(Format, []const u8).init(.{
    .NORMAL = "\x1b[0m",
    .BOLD = "\x1b[1m",
    .DIM = "\x1b[2m",
    .ITALIC = "\x1b[3m",
    .UNDERLINE = "\x1b[4m",
    .BLINK = "\x1b[5m",
    .REVERSE = "\x1b[7m",
    .HIDDEN = "\x1b[8m",
    .STRIKETHROUGH = "\x1b[9m",
});

pub const OutputDescriptor = struct {
    label: []const u8,
    color: Color = .NORMAL,
    format: Format = .NORMAL,
};

pub const output_descriptors =
    std.EnumArray(OutputType, OutputDescriptor).init(.{
        .ERROR = .{
            .label = "[!ERROR!]",
            .color = .RED,
            .format = .BOLD,
        },
        .SUCCESS = .{
            .label = "[SUCCESS]",
            .color = .GREEN,
            .format = .BOLD,
        },
        .WARNING = .{
            .label = "[WARNING]",
            .color = .YELLOW,
        },
        .INFO = .{
            .label = "[-INFO--]",
            .color = .BLUE,
        },
        .NORMAL = .{
            .label = "",
            .color = .NORMAL,
        },
    });
