const std = @import("std");
const format = @import("format.zig");

pub const MAX_TABLE_COLUMNS: usize = 16;

pub const TableDecoration = enum {
    NONE,

    // | value | value |
    SIMPLE,

    // +-------+-------+
    // | value | value |
    // +-------+-------+
    BOX,

    // #=======#
    // | title |
    // #=======#
    FANCY,
};

pub const TableColumn = struct {
    name: []const u8,
    width: usize,
};

pub const TableState = struct {
    active: bool = false,

    name: []const u8 = "",
    decoration: TableDecoration = .NONE,

    columns: [MAX_TABLE_COLUMNS]TableColumn = undefined,
    column_count: usize = 0,
};

pub const TableWriter = struct {};
