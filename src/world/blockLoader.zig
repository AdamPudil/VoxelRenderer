const std = @import("std");
const Block = @import("block.zig").Block;
const Voxel = @import("voxel.zig").Voxel;
const side = @import("worldConstants.zig").BLOCK_VOXEL_CNT;

pub const Metadata = struct {
    name: []const u8,
    variant: u8 = 0,
    model: []const u8,
    icon: ?[]const u8 = null,
    format: u8 = 1,
    color: ?[3]u8 = null,
    reflectivity: f32 = 0,
    metallic: f32 = 0,
    opacity: ?f32 = null,
    ior: f32 = 1.5,
};

/// Returned slices borrow the descriptor text. Paths are relative to its folder.
pub fn parseMetadata(text: []const u8) !Metadata {
    var name: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var variant: u8 = 0;
    var version: u8 = 1;
    var color: ?[3]u8 = null;
    var reflectivity: f32 = 0;
    var metallic: f32 = 0;
    var opacity: ?f32 = null;
    var ior: f32 = 1.5;
    var seen: u16 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidBlockMetadata;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
        const field: u16 = if (std.ascii.eqlIgnoreCase(key, "name") or std.ascii.eqlIgnoreCase(key, "block name")) 1 else if (std.ascii.eqlIgnoreCase(key, "variant")) 2 else if (std.ascii.eqlIgnoreCase(key, "model") or std.ascii.eqlIgnoreCase(key, "model path")) 4 else if (std.ascii.eqlIgnoreCase(key, "icon") or std.ascii.eqlIgnoreCase(key, "icon path")) 8 else if (std.ascii.eqlIgnoreCase(key, "format")) 16 else if (std.ascii.eqlIgnoreCase(key, "color")) 32 else if (std.ascii.eqlIgnoreCase(key, "reflectivity") or std.ascii.eqlIgnoreCase(key, "reflectiveness")) 64 else if (std.ascii.eqlIgnoreCase(key, "metallic")) 128 else if (std.ascii.eqlIgnoreCase(key, "opacity") or std.ascii.eqlIgnoreCase(key, "transparency")) 256 else if (std.ascii.eqlIgnoreCase(key, "ior")) 512 else return error.UnknownBlockAttribute;
        if (seen & field != 0) return error.DuplicateBlockAttribute;
        seen |= field;
        switch (field) {
            1 => name = value,
            2 => variant = std.fmt.parseInt(u8, value, 10) catch return error.InvalidBlockVariant,
            4 => model = value,
            8 => icon = if (value.len == 0) null else value,
            16 => {
                version = std.fmt.parseInt(u8, value, 10) catch return error.UnsupportedBlockFormat;
                if (version != 1 and version != 2) return error.UnsupportedBlockFormat;
            },
            32 => {
                var components = std.mem.tokenizeAny(u8, value, " ,\t");
                var rgb: [3]u8 = undefined;
                for (&rgb) |*channel| channel.* = std.fmt.parseInt(u8, components.next() orelse return error.InvalidBlockColor, 10) catch return error.InvalidBlockColor;
                if (components.next() != null) return error.InvalidBlockColor;
                color = rgb;
            },
            64 => reflectivity = try materialFactor(value),
            128 => metallic = try materialFactor(value),
            256 => {
                const factor = try materialFactor(value);
                opacity = if (std.ascii.eqlIgnoreCase(key, "transparency")) 1 - factor else factor;
            },
            512 => {
                ior = std.fmt.parseFloat(f32, value) catch return error.InvalidRefractiveIndex;
                if (!std.math.isFinite(ior) or ior < 1 or ior > 2.5) return error.InvalidRefractiveIndex;
            },
            else => unreachable,
        }
    }
    if (name == null or name.?.len == 0 or model == null or model.?.len == 0) return error.MissingBlockAttribute;
    return .{ .name = name.?, .model = model.?, .variant = variant, .icon = icon, .format = version, .color = color, .reflectivity = reflectivity, .metallic = metallic, .opacity = opacity, .ior = ior };
}

fn materialFactor(value: []const u8) !f32 {
    const n = std.fmt.parseFloat(f32, value) catch return error.InvalidMaterialFactor;
    if (!std.math.isFinite(n) or n < 0 or n > 1) return error.InvalidMaterialFactor;
    return n;
}

/// Canonical engine descriptor. Geometry remains in the referenced VOX file.
pub fn encodeMetadata(allocator: std.mem.Allocator, meta: Metadata) ![]u8 {
    if (meta.format != 1 and meta.format != 2) return error.UnsupportedBlockFormat;
    for ([_][]const u8{ meta.name, meta.model, meta.icon orelse "" }) |value| {
        if (std.mem.indexOfAny(u8, value, "\r\n\"") != null) return error.InvalidBlockMetadata;
    }
    if (meta.name.len == 0 or meta.model.len == 0) return error.MissingBlockAttribute;
    if (!std.math.isFinite(meta.reflectivity) or meta.reflectivity < 0 or meta.reflectivity > 1 or
        !std.math.isFinite(meta.metallic) or meta.metallic < 0 or meta.metallic > 1) return error.InvalidMaterialFactor;
    if (meta.opacity) |opacity| {
        if (!std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidMaterialFactor;
    }
    if (!std.math.isFinite(meta.ior) or meta.ior < 1 or meta.ior > 2.5) return error.InvalidRefractiveIndex;
    var text = std.ArrayList(u8).init(allocator);
    errdefer text.deinit();
    const w = text.writer();
    try w.print("format: 2\nname: \"{s}\"\nvariant: {d}\nmodel: \"{s}\"\n", .{ meta.name, meta.variant, meta.model });
    if (meta.icon) |icon| try w.print("icon: \"{s}\"\n", .{icon});
    if (meta.color) |rgb| try w.print("color: {d}, {d}, {d}\n", .{ rgb[0], rgb[1], rgb[2] });
    try w.print("reflectivity: {d}\nmetallic: {d}\n", .{ meta.reflectivity, meta.metallic });
    if (meta.opacity) |opacity| try w.print("opacity: {d}\n", .{opacity});
    try w.print("ior: {d}\n", .{meta.ior});
    return text.toOwnedSlice();
}

/// Save the descriptor atomically; the referenced model is saved separately.
pub fn saveMetadata(allocator: std.mem.Allocator, dir: std.fs.Dir, path: []const u8, meta: Metadata) !void {
    const text = try encodeMetadata(allocator, meta);
    defer allocator.free(text);
    var file = try dir.atomicFile(path, .{});
    defer file.deinit();
    try file.file.writeAll(text);
    try file.finish();
}

/// Override palette material without changing occupancy or emission.
/// Packed material bytes survive cloning, editing and GPU streaming unchanged.
pub fn applyMaterial(block: *Block, meta: Metadata) void {
    switch (block.blockData) {
        .free => {},
        .mono => |*voxel| applyVoxelMaterial(voxel, meta),
        .voxel => |data| {
            for (&data.pallete) |*voxel| if (!voxel.isEmpty()) {
                applyVoxelMaterial(voxel, meta);
            };
            data.dirty = true;
        },
    }
}
fn applyVoxelMaterial(voxel: *Voxel, meta: Metadata) void {
    if (meta.color) |rgb| {
        voxel.r = rgb[0];
        voxel.g = rgb[1];
        voxel.b = rgb[2];
    }
    voxel.reflectiveness = @intFromFloat(@round(meta.reflectivity * 255));
    voxel.metallic = @intFromFloat(@round(meta.metallic * 255));
    if (meta.opacity) |opacity| voxel.opacity = @intFromFloat(@round(opacity * 255));
    voxel.refractive_index = if (voxel.opacity < 255) Voxel.encodeIor(meta.ior) else 0;
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
                    palette[i] = Voxel.getVoxel(rgba[0], rgba[1], rgba[2], if (rgba[3] > 0 and rgba[3] < 255) Voxel.encodeIor(1.5) else 0, rgba[3], 0, 0);
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

test "versioned material descriptors roundtrip and reject invalid values" {
    const a = std.testing.allocator;
    const material = try parseMetadata("format: 2\nname: Gold\nmodel: gold.vox\ncolor: 255, 209, 112\nreflectivity: 0.85\nmetallic: 1\n");
    const encoded = try encodeMetadata(a, material);
    defer a.free(encoded);
    const decoded = try parseMetadata(encoded);
    try std.testing.expectEqual(@as(u8, 2), decoded.format);
    try std.testing.expectEqual(material.color, decoded.color);
    try std.testing.expectEqual(material.reflectivity, decoded.reflectivity);
    try std.testing.expectEqual(material.metallic, decoded.metallic);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try saveMetadata(a, tmp.dir, "gold.block", material);
    const saved = try tmp.dir.readFileAlloc(a, "gold.block", 4096);
    defer a.free(saved);
    try std.testing.expectEqualStrings(encoded, saved);
    const legacy = try parseMetadata("name: Old\nmodel: old.vox\n");
    try std.testing.expectEqual(@as(f32, 0), legacy.reflectivity);
    try std.testing.expect(legacy.color == null);
    for ([_][]const u8{ "nan", "inf", "-0.1", "1.01", "abc" }) |value| {
        const text = try std.fmt.allocPrint(a, "name: Invalid\nmodel: a.vox\nreflectivity: {s}\n", .{value});
        defer a.free(text);
        try std.testing.expectError(error.InvalidMaterialFactor, parseMetadata(text));
    }
    try std.testing.expectError(error.DuplicateBlockAttribute, parseMetadata("name: x\nmodel: a.vox\nreflectivity: 0.5\nreflectiveness: 0.8"));
    try std.testing.expectError(error.UnsupportedBlockFormat, parseMetadata("name: x\nmodel: a.vox\nformat: 3"));
    try std.testing.expectError(error.InvalidBlockColor, parseMetadata("name: x\nmodel: a.vox\ncolor: 256, 0, 0"));
    try std.testing.expectError(error.InvalidBlockColor, parseMetadata("name: x\nmodel: a.vox\ncolor: 1, 2"));
    try std.testing.expectError(error.InvalidMaterialFactor, parseMetadata("name: x\nmodel: a.vox\nmetallic: 2"));
}

test "material palette overrides preserve geometry and survive copies" {
    const a = std.testing.allocator;
    const bytes = try @import("testBlocks.zig").encodeSample(a, 5, .{ 1, 2, 3 });
    defer a.free(bytes);
    var block = try BlockLoader.decodeVox(a, bytes, 1);
    defer block.deinit(a);
    const before = block.blockData.voxel.solid_count;
    const material = Metadata{ .name = "Metal", .model = "a.vox", .color = .{ 255, 209, 112 }, .reflectivity = 0.85, .metallic = 1 };
    applyMaterial(&block, material);
    var clone = try block.clone(a);
    defer clone.deinit(a);
    const v = clone.blockData.voxel.getVoxel(0, 0, 0).?;
    try std.testing.expectEqual(@as(u8, 217), v.reflectiveness);
    try std.testing.expectEqual(@as(u8, 255), v.metallic);
    try std.testing.expectEqual(@as(u8, 209), v.g);
    try std.testing.expectEqual(@as(u8, 255), v.opacity);
    try std.testing.expectEqual(before, clone.blockData.voxel.solid_count);
    try std.testing.expect(!clone.blockData.voxel.isOccupied(8, 8, 8));
    var mono = Block.initMono(2, Voxel.rgb(1, 2, 3));
    applyMaterial(&mono, material);
    try std.testing.expectEqual(v, mono.blockData.mono);
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Voxel));
}

test "opacity and IOR roundtrip, aliases, and fully clear occupied glass" {
    const a = std.testing.allocator;
    const meta = try parseMetadata("name: Glass\nmodel: glass.vox\nopacity: 0\nior: 1.5\ncolor: 255, 100, 100\n");
    const text = try encodeMetadata(a, meta);
    defer a.free(text);
    const saved = try parseMetadata(text);
    try std.testing.expectEqual(@as(?f32, 0), saved.opacity);
    try std.testing.expectEqual(@as(f32, 1.5), saved.ior);
    var block = Block.initMono(0, Voxel.rgb(255, 255, 255));
    applyMaterial(&block, saved);
    try std.testing.expect(!block.blockData.mono.isEmpty());
    try std.testing.expectEqual(@as(u8, 0), block.blockData.mono.opacity);
    try std.testing.expect(block.blockData.mono.refractive_index > 0);
    const alias = try parseMetadata("name: Glass\nmodel: g.vox\ntransparency: 0.75\n");
    try std.testing.expectEqual(@as(?f32, 0.25), alias.opacity);
    try std.testing.expectError(error.DuplicateBlockAttribute, parseMetadata("name: x\nmodel: a.vox\nopacity: 0.2\ntransparency: 0.8"));
    for ([_][]const u8{ "nan", "inf", "0.9", "2.51" }) |value| {
        const invalid = try std.fmt.allocPrint(a, "name: x\nmodel: a.vox\nior: {s}", .{value});
        defer a.free(invalid);
        try std.testing.expectError(error.InvalidRefractiveIndex, parseMetadata(invalid));
    }
    try std.testing.expectError(error.InvalidMaterialFactor, parseMetadata("name: x\nmodel: a.vox\nopacity: -0.1"));
    try std.testing.expectEqual(@as(u8, 1), Voxel.encodeIor(1));
    try std.testing.expectEqual(@as(u8, 255), Voxel.encodeIor(2.5));
}
