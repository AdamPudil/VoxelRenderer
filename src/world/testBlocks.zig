const std = @import("std");
const PointLight = @import("../lighting.zig").PointLight;

fn ledLight(color: [3]u8) PointLight {
    var light = PointLight{ .position = .{ 7.5, 5.5, 7.5 } };
    // Palette colors are display RGB; light descriptors use linear RGB.
    for (color, 0..) |channel, i| light.color[i] = std.math.pow(f32, @as(f32, @floatFromInt(channel)) / 255, 2.2);
    return light;
}

/// Create sample assets only when missing. User edits are never overwritten.
pub fn ensure(allocator: std.mem.Allocator, folder: []const u8) !void {
    try std.fs.cwd().makePath(folder);
    const samples = [_]struct { stem: []const u8, name: []const u8, variant: u8, color: [3]u8, reflectivity: f32 = 0, metallic: f32 = 0, opacity: ?f32 = null, ior: f32 = 1.5, light: ?PointLight = null }{
        .{ .stem = "01_red", .name = "Red", .variant = 0, .color = .{ 220, 55, 45 } },
        .{ .stem = "02_green", .name = "Green", .variant = 0, .color = .{ 65, 190, 90 } },
        .{ .stem = "03_blue", .name = "Blue", .variant = 0, .color = .{ 65, 115, 230 } },
        .{ .stem = "04_checker", .name = "Checker", .variant = 0, .color = .{ 225, 190, 65 } },
        .{ .stem = "05_fine_checker", .name = "Checker", .variant = 1, .color = .{ 210, 210, 230 } },
        .{ .stem = "06_frame", .name = "Frame", .variant = 0, .color = .{ 180, 80, 215 } },
        .{ .stem = "07_white", .name = "White", .variant = 0, .color = .{ 255, 255, 255 } },
        .{ .stem = "08_black", .name = "Black", .variant = 0, .color = .{ 0, 0, 0 } },
        .{ .stem = "09_yellow", .name = "Yellow", .variant = 0, .color = .{ 255, 220, 45 } },
        .{ .stem = "10_orange", .name = "Orange", .variant = 0, .color = .{ 255, 140, 45 } },
        .{ .stem = "11_purple", .name = "Purple", .variant = 0, .color = .{ 150, 75, 220 } },
        .{ .stem = "12_cyan", .name = "Cyan", .variant = 0, .color = .{ 40, 210, 225 } },
        .{ .stem = "13_pink", .name = "Pink", .variant = 0, .color = .{ 245, 125, 185 } },
        .{ .stem = "14_gray", .name = "Gray", .variant = 0, .color = .{ 130, 130, 145 } },
        .{ .stem = "15_brown", .name = "Brown", .variant = 0, .color = .{ 140, 90, 45 } },
        .{ .stem = "16_light_red", .name = "Red", .variant = 1, .color = .{ 255, 130, 125 } },
        .{ .stem = "17_light_green", .name = "Green", .variant = 1, .color = .{ 145, 225, 160 } },
        .{ .stem = "18_light_blue", .name = "Blue", .variant = 1, .color = .{ 135, 185, 255 } },
        .{ .stem = "19_gold", .name = "Gold", .variant = 0, .color = .{ 255, 209, 112 }, .reflectivity = 0.85, .metallic = 1 },
        .{ .stem = "20_copper", .name = "Copper", .variant = 0, .color = .{ 244, 166, 119 }, .reflectivity = 0.72, .metallic = 1 },
        .{ .stem = "21_iron", .name = "Iron", .variant = 0, .color = .{ 196, 204, 214 }, .reflectivity = 0.55, .metallic = 1 },
        .{ .stem = "22_mirror", .name = "Mirror", .variant = 0, .color = .{ 255, 255, 255 }, .reflectivity = 0.98, .metallic = 0 },
        .{ .stem = "23_glass_white", .name = "Glass White", .variant = 0, .color = .{ 255, 255, 255 }, .opacity = 0.04 },
        .{ .stem = "24_glass_red", .name = "Glass Red", .variant = 0, .color = .{ 255, 105, 105 }, .opacity = 0.04 },
        .{ .stem = "25_glass_green", .name = "Glass Green", .variant = 0, .color = .{ 105, 255, 105 }, .opacity = 0.04 },
        .{ .stem = "26_glass_blue", .name = "Glass Blue", .variant = 0, .color = .{ 105, 105, 255 }, .opacity = 0.04 },
        .{ .stem = "27_sanded_glass_white", .name = "Sanded Glass White", .variant = 0, .color = .{ 255, 255, 255 }, .opacity = 0.5 },
        .{ .stem = "28_sanded_glass_red", .name = "Sanded Glass Red", .variant = 0, .color = .{ 255, 105, 105 }, .opacity = 0.5 },
        .{ .stem = "29_sanded_glass_green", .name = "Sanded Glass Green", .variant = 0, .color = .{ 105, 255, 105 }, .opacity = 0.5 },
        .{ .stem = "30_sanded_glass_blue", .name = "Sanded Glass Blue", .variant = 0, .color = .{ 105, 105, 255 }, .opacity = 0.5 },
        .{ .stem = "31_scifi_lamp", .name = "Sci-Fi Lamp", .variant = 0, .color = .{ 90, 220, 255 }, .light = .{} },
        .{ .stem = "32_cold_white_led_stick", .name = "Cold White LED Stick", .variant = 0, .color = .{ 190, 220, 255 }, .light = ledLight(.{ 190, 220, 255 }) },
        .{ .stem = "33_warm_white_led_stick", .name = "Warm White LED Stick", .variant = 0, .color = .{ 255, 215, 160 }, .light = ledLight(.{ 255, 215, 160 }) },
        .{ .stem = "34_neutral_white_led_stick", .name = "Neutral White LED Stick", .variant = 0, .color = .{ 255, 255, 255 }, .light = ledLight(.{ 255, 255, 255 }) },
        .{ .stem = "35_red_led_stick", .name = "Red LED Stick", .variant = 0, .color = .{ 255, 0, 0 }, .light = ledLight(.{ 255, 0, 0 }) },
        .{ .stem = "36_green_led_stick", .name = "Green LED Stick", .variant = 0, .color = .{ 0, 255, 0 }, .light = ledLight(.{ 0, 255, 0 }) },
        .{ .stem = "37_blue_led_stick", .name = "Blue LED Stick", .variant = 0, .color = .{ 0, 0, 255 }, .light = ledLight(.{ 0, 0, 255 }) },
    };
    for (samples, 0..) |sample, i| {
        const model_path = try std.fmt.allocPrint(allocator, "{s}/{s}.vox", .{ folder, sample.stem });
        defer allocator.free(model_path);
        const model = try encodeSample(allocator, i, sample.color);
        defer allocator.free(model);
        try writeMissing(model_path, model);
        const descriptor_path = try std.fmt.allocPrint(allocator, "{s}/{s}.block", .{ folder, sample.stem });
        defer allocator.free(descriptor_path);
        const model_name = try std.fmt.allocPrint(allocator, "{s}.vox", .{sample.stem});
        defer allocator.free(model_name);
        const descriptor = try @import("blockLoader.zig").encodeMetadata(allocator, .{
            .name = sample.name,
            .variant = sample.variant,
            .model = model_name,
            .reflectivity = sample.reflectivity,
            .metallic = sample.metallic,
            .opacity = sample.opacity,
            .ior = sample.ior,
            .emission_color = if (sample.light != null) sample.color else null,
            .light = sample.light,
        });
        defer allocator.free(descriptor);
        try writeMissing(descriptor_path, descriptor);
    }
}

fn writeMissing(path: []const u8, bytes: []const u8) !void {
    const file = std.fs.cwd().createFile(path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    defer file.close();
    errdefer std.fs.cwd().deleteFile(path) catch {};
    try file.writeAll(bytes);
}

pub fn encodeSample(allocator: std.mem.Allocator, kind: usize, color: [3]u8) ![]u8 {
    var records = std.ArrayList(u8).init(allocator);
    defer records.deinit();
    for (0..16) |z| for (0..16) |y| for (0..16) |x| {
        // One-voxel-wide, six-voxel-tall colored stick. Its light sits in
        // the top emissive voxel, which the shadow endpoint policy permits.
        if (kind >= 31 and kind <= 36) {
            if (x != 7 or y != 8 or z >= 6) continue;
        }
        if (kind == 5) {
            const edges = @as(u8, @intFromBool(x < 2 or x >= 14)) + @as(u8, @intFromBool(y < 2 or y >= 14)) + @as(u8, @intFromBool(z < 2 or z >= 14));
            if (edges < 2) continue;
        }
        // Sparse cage: one-voxel edges and two one-voxel bars on each face.
        // VOX (x,y,z) maps to world (x,z,15-y); the single cyan emitter is
        // centered on world voxel (7,7,7), around the attached point light.
        if (kind == 30) {
            const edge_x = x == 0 or x == 15;
            const edge_y = y == 0 or y == 15;
            const edge_z = z == 0 or z == 15;
            const frame = @as(u8, @intFromBool(edge_x)) + @as(u8, @intFromBool(edge_y)) + @as(u8, @intFromBool(edge_z)) >= 2;
            const bars = ((edge_y or edge_z) and (x == 5 or x == 10)) or
                (edge_x and (y == 5 or y == 10));
            const core = x == 7 and y == 8 and z == 7;
            if (!frame and !bars and !core) continue;
            const index: u8 = if (core) 1 else 2;
            try records.appendSlice(&.{ @intCast(x), @intCast(y), @intCast(z), index });
            continue;
        }
        const step: usize = if (kind == 4) 1 else 4;
        const index: u8 = if ((kind == 3 or kind == 4) and (x / step + y / step + z / step) % 2 == 1) 2 else 1;
        try records.appendSlice(&.{ @intCast(x), @intCast(y), @intCast(z), index });
    };
    var bytes = std.ArrayList(u8).init(allocator);
    errdefer bytes.deinit();
    const w = bytes.writer();
    try w.writeAll("VOX ");
    try w.writeInt(u32, 150, .little);
    try w.writeAll("MAIN");
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, @intCast(24 + 16 + records.items.len + 1036), .little);
    try w.writeAll("SIZE");
    try w.writeInt(u32, 12, .little);
    try w.writeInt(u32, 0, .little);
    for (0..3) |_| try w.writeInt(u32, 16, .little);
    try w.writeAll("XYZI");
    try w.writeInt(u32, @intCast(4 + records.items.len), .little);
    try w.writeInt(u32, 0, .little);
    try w.writeInt(u32, @intCast(records.items.len / 4), .little);
    try w.writeAll(records.items);
    try w.writeAll("RGBA");
    try w.writeInt(u32, 1024, .little);
    try w.writeInt(u32, 0, .little);
    try w.writeAll(&.{ color[0], color[1], color[2], 255 });
    try w.writeAll(&.{ 35, 40, 50, 255 });
    for (2..256) |_| try w.writeAll(&.{ 0, 0, 0, 255 });
    return bytes.toOwnedSlice();
}

test "VOX roundtrip, color, handedness, corruption and empty model" {
    const loader = @import("blockLoader.zig").BlockLoader;
    const a = std.testing.allocator;
    const bytes = try encodeSample(a, 3, .{ 225, 190, 65 });
    defer a.free(bytes);
    var block = try loader.decodeVox(a, bytes, 7);
    defer block.deinit(a);
    try std.testing.expectEqual(@as(u32, 4096), block.blockData.voxel.solid_count);
    try std.testing.expectEqual(@as(u8, 225), block.blockData.voxel.getVoxel(0, 0, 15).?.r);
    try std.testing.expectEqual(@as(u8, 35), block.blockData.voxel.getVoxel(4, 0, 15).?.r);
    for ([_]usize{ 0, 4, 19, 20, 43, bytes.len - 1 }) |len| {
        try std.testing.expectError(if (len < 20) error.TruncatedVox else error.InvalidVoxChunkSize, loader.decodeVox(a, bytes[0..len], 0));
    }
    const saved = bytes[32];
    bytes[32] = 17;
    try std.testing.expectError(error.VoxModelTooLarge, loader.decodeVox(a, bytes, 0));
    bytes[32] = saved;
    // First record starts after VOX/MAIN/SIZE and the XYZI header/count.
    bytes[60] = 16;
    try std.testing.expectError(error.InvalidVoxCoordinate, loader.decodeVox(a, bytes, 0));
}

test "VOX default palette, empty model and duplicate voxel rejection" {
    const loader = @import("blockLoader.zig").BlockLoader;
    const a = std.testing.allocator;
    const bytes = try encodeSample(a, 3, .{ 1, 2, 3 });
    defer a.free(bytes);
    const no_palette = bytes[0 .. bytes.len - 1036];
    std.mem.writeInt(u32, bytes[16..20], @intCast(no_palette.len - 20), .little);
    var default = try loader.decodeVox(a, no_palette, 0);
    defer default.deinit(a);
    try std.testing.expectEqual(@as(u8, 255), default.blockData.voxel.getVoxel(0, 0, 15).?.r);
    try std.testing.expectEqual(@as(u8, 204), default.blockData.voxel.getVoxel(4, 0, 15).?.b);
    bytes[64] = bytes[60];
    bytes[65] = bytes[61];
    bytes[66] = bytes[62];
    try std.testing.expectError(error.DuplicateVoxCoordinate, loader.decodeVox(a, no_palette, 0));
    std.mem.writeInt(u32, bytes[16..20], 40, .little);
    std.mem.writeInt(u32, bytes[48..52], 4, .little);
    std.mem.writeInt(u32, bytes[56..60], 0, .little);
    var empty = try loader.decodeVox(a, bytes[0..60], 0);
    defer empty.deinit(a);
    try std.testing.expect(empty.isFree());
}
