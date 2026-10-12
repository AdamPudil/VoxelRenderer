const std = @import("std");
const Block = @import("block.zig").Block;
const Voxel = @import("voxel.zig").Voxel;
const side = @import("worldConstants.zig").BLOCK_VOXEL_CNT;

pub const Metadata = struct {
    name: []const u8,
    variant: u8 = 0,
    model: []const u8,
    icon: ?[]const u8 = null,
};

/// Returned slices borrow the descriptor text. Paths are relative to its folder.
pub fn parseMetadata(text: []const u8) !Metadata {
    var name: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var variant: u8 = 0;
    var seen: u8 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidBlockMetadata;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        const field: u8 = if (std.ascii.eqlIgnoreCase(key, "name") or std.ascii.eqlIgnoreCase(key, "block name")) 1 else if (std.ascii.eqlIgnoreCase(key, "variant")) 2 else if (std.ascii.eqlIgnoreCase(key, "model") or std.ascii.eqlIgnoreCase(key, "model path")) 4 else if (std.ascii.eqlIgnoreCase(key, "icon") or std.ascii.eqlIgnoreCase(key, "icon path")) 8 else return error.UnknownBlockAttribute;
        if (seen & field != 0) return error.DuplicateBlockAttribute;
        seen |= field;
        switch (field) {
            1 => name = value,
            2 => variant = std.fmt.parseInt(u8, value, 10) catch return error.InvalidBlockVariant,
            4 => model = value,
            8 => icon = if (value.len == 0) null else value,
            else => unreachable,
        }
    }
    if (name == null or name.?.len == 0 or model == null or model.?.len == 0) return error.MissingBlockAttribute;
    return .{ .name = name.?, .model = model.?, .variant = variant, .icon = icon };
}

fn u32le(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.TruncatedVox;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn defaultPalette() [256]Voxel {
    var palette = [_]Voxel{Voxel.empty()} ** 256;
    var index: usize = 1;
    for (0..6) |r| for (0..6) |g| for (0..6) |b| {
        if (r == 5 and g == 5 and b == 5) continue;
        palette[index] = Voxel.rgb(@intCast(255 - r * 51), @intCast(255 - g * 51), @intCast(255 - b * 51));
        index += 1;
    };
    const ramp = [_]u8{ 238, 221, 187, 170, 136, 119, 85, 68, 34, 17 };
    for (0..4) |channel| for (ramp) |v| {
        palette[index] = Voxel.rgb(if (channel == 0 or channel == 3) v else 0, if (channel == 1 or channel == 3) v else 0, if (channel == 2 or channel == 3) v else 0);
        index += 1;
    };
    return palette;
}

pub const BlockLoader = struct {
    pub fn loadVOXfile(allocator: std.mem.Allocator, path: []const u8, id: u32) !Block {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
        defer allocator.free(bytes);
        return decodeVox(allocator, bytes, id);
    }

    /// Single raw MagicaVoxel model, at most 16 on each axis. Z-up -> Y-up.
    /// Scene transforms and material extensions are not applied.
    pub fn decodeVox(allocator: std.mem.Allocator, bytes: []const u8, id: u32) !Block {
        if (bytes.len < 20) return error.TruncatedVox;
        if (!std.mem.eql(u8, bytes[0..4], "VOX ")) return error.InvalidVoxMagic;
        const version = try u32le(bytes, 4);
        if (version != 150 and version != 200) return error.UnsupportedVoxVersion;
        if (!std.mem.eql(u8, bytes[8..12], "MAIN") or try u32le(bytes, 12) != 0) return error.InvalidVoxMain;
        if (try u32le(bytes, 16) != bytes.len - 20) return error.InvalidVoxChunkSize;
        var dimensions: ?[3]u32 = null;
        var records: ?[]const u8 = null;
        var palette = defaultPalette();
        var has_palette = false;
        var offset: usize = 20;
        while (offset < bytes.len) {
            if (bytes.len - offset < 12) return error.TruncatedVox;
            const tag = bytes[offset .. offset + 4];
            const size: usize = try u32le(bytes, offset + 4);
            const children: usize = try u32le(bytes, offset + 8);
            offset += 12;
            if (size > bytes.len - offset or children > bytes.len - offset - size) return error.InvalidVoxChunkSize;
            const data = bytes[offset .. offset + size];
            if (std.mem.eql(u8, tag, "SIZE")) {
                if (dimensions != null) return error.MultipleVoxModels;
                if (size != 12 or children != 0) return error.InvalidVoxSize;
                const dims = [3]u32{ try u32le(data, 0), try u32le(data, 4), try u32le(data, 8) };
                for (dims) |n| if (n == 0 or n > side) return error.VoxModelTooLarge;
                dimensions = dims;
            } else if (std.mem.eql(u8, tag, "XYZI")) {
                if (records != null) return error.MultipleVoxModels;
                if (dimensions == null or children != 0) return error.InvalidVoxModel;
                const count = try u32le(data, 0);
                if (count > side * side * side or size != 4 + @as(usize, count) * 4) return error.InvalidVoxVoxelCount;
                records = data[4..];
            } else if (std.mem.eql(u8, tag, "RGBA")) {
                if (size != 1024 or has_palette or children != 0) return error.InvalidVoxPalette;
                has_palette = true;
                for (1..256) |i| {
                    const rgba = data[(i - 1) * 4 ..][0..4];
                    palette[i] = Voxel.getVoxel(rgba[0], rgba[1], rgba[2], 255 - rgba[3], rgba[3], 0, 0);
                }
            } else if (std.mem.eql(u8, tag, "PACK")) {
                if (size != 4 or try u32le(data, 0) != 1) return error.MultipleVoxModels;
            }
            offset += size + children;
        }
        const dims = dimensions orelse return error.MissingVoxModel;
        const voxels = records orelse return error.MissingVoxModel;
        var block = try Block.initVoxel(allocator, id);
        errdefer block.deinit(allocator);
        const vb = block.blockData.voxel;
        vb.pallete = palette;
        var i: usize = 0;
        while (i < voxels.len) : (i += 4) {
            const v = voxels[i..][0..4];
            if (v[0] >= dims[0] or v[1] >= dims[1] or v[2] >= dims[2] or v[3] == 0) return error.InvalidVoxCoordinate;
            // Preserve handedness while converting the vertical axis.
            const x = v[0];
            const y = v[2];
            const z = dims[1] - 1 - v[1];
            if (vb.isOccupied(x, y, z)) return error.DuplicateVoxCoordinate;
            vb.setVoxel(x, y, z, v[3]);
        }
        if (vb.solid_count == 0) block.setFree(allocator, id);
        return block;
    }
};

test "metadata fields, aliases, optional icon, and invalid definitions" {
    const m = try parseMetadata("# example\nBlock name: Checker\nVariant: 255\nmodel path: models/a.vox\nicon path:\n");
    try std.testing.expectEqualStrings("Checker", m.name);
    try std.testing.expectEqual(@as(u8, 255), m.variant);
    try std.testing.expect(m.icon == null);
    try std.testing.expectError(error.InvalidBlockVariant, parseMetadata("name: x\nmodel: a.vox\nvariant: 256"));
    try std.testing.expectError(error.DuplicateBlockAttribute, parseMetadata("name: x\nName: y\nmodel: a.vox"));
    try std.testing.expectError(error.MissingBlockAttribute, parseMetadata("name: x"));
}
