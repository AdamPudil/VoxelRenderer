const std = @import("std");

const Block = @import("block.zig").Block;

pub const BlockLoader = struct {
    pub fn load(folderPath: []const u8) void {
        _ = folderPath;
    }

    fn loadVOXfile(filePath: []const u8) Block {
        _ = filePath;
    }

    fn loadMyCustomFormat(filePath: []const u8) Block {
        _ = filePath;
    }
};
