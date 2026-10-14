const std = @import("std");
const loader = @import("blockLoader.zig");
const Block = @import("block.zig").Block;

pub const Definition = struct {
    id: u32,
    name: []const u8,
    variant: u8,
    model_path: []const u8,
    icon_path: []const u8,
    generated_icon: bool,
    model: Block,
};

pub const BlockRegistry = struct {
    allocator: std.mem.Allocator,
    /// ID is the array index; IDs are assigned by sorted descriptor filename.
    blocks: std.ArrayList(Definition),
    /// A name may have several variants; each occupied slot holds its block ID.
    by_name: std.StringHashMap([256]?u32),

    pub fn init(allocator: std.mem.Allocator) BlockRegistry {
        return .{ .allocator = allocator, .blocks = std.ArrayList(Definition).init(allocator), .by_name = std.StringHashMap([256]?u32).init(allocator) };
    }

    pub fn deinit(self: *BlockRegistry) void {
        self.by_name.deinit();
        for (self.blocks.items) |*entry| {
            entry.model.deinit(self.allocator);
            self.allocator.free(entry.name);
            self.allocator.free(entry.model_path);
            self.allocator.free(entry.icon_path);
        }
        self.blocks.deinit();
    }

    pub fn find(self: *const BlockRegistry, name: []const u8, variant: u8) ?u32 {
        const variants = self.by_name.getPtr(name) orelse return null;
        return variants[variant];
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.lessThan(u8, a, b);
    }

    pub fn loadDirectory(allocator: std.mem.Allocator, folder: []const u8) !BlockRegistry {
        var self = init(allocator);
        errdefer self.deinit();
        var dir = try std.fs.cwd().openDir(folder, .{ .iterate = true });
        defer dir.close();
        var paths = std.ArrayList([]const u8).init(allocator);
        defer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit();
        }
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".block")) continue;
            const owned = try allocator.dupe(u8, entry.name);
            errdefer allocator.free(owned);
            try paths.append(owned);
        }
        std.mem.sort([]const u8, paths.items, {}, lessThan);
        for (paths.items) |path| {
            self.loadDefinition(folder, path) catch |err| {
                std.debug.print("Block definition {s}/{s}: {s}\n", .{ folder, path, @errorName(err) });
                return err;
            };
        }
        return self;
    }

    fn loadDefinition(self: *BlockRegistry, folder: []const u8, filename: []const u8) !void {
        const a = self.allocator;
        const path = try std.fs.path.join(a, &.{ folder, filename });
        defer a.free(path);
        const text = try std.fs.cwd().readFileAlloc(a, path, 64 * 1024);
        defer a.free(text);
        const meta = try loader.parseMetadata(text);
        if (self.find(meta.name, meta.variant) != null) return error.DuplicateBlockNameAndVariant;
        const name = try a.dupe(u8, meta.name);
        errdefer a.free(name);
        const model_path = try std.fs.path.resolve(a, &.{ folder, meta.model });
        errdefer a.free(model_path);
        if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(model_path), ".vox")) return error.UnsupportedModelFormat;
        const icon_path = if (meta.icon) |icon|
            try std.fs.path.resolve(a, &.{ folder, icon })
        else
            try std.fmt.allocPrint(a, "{s}/icons/{s}.png", .{ folder, filename[0 .. filename.len - 6] });
        errdefer a.free(icon_path);
        const id: u32 = @intCast(self.blocks.items.len);
        var model = try loader.BlockLoader.loadVOXfile(a, model_path, id);
        errdefer model.deinit(a);
        loader.applyMaterial(&model, meta);
        try self.blocks.ensureUnusedCapacity(1);
        const gop = try self.by_name.getOrPut(name);
        if (!gop.found_existing) gop.value_ptr.* = [_]?u32{null} ** 256;
        gop.value_ptr[meta.variant] = id;
        self.blocks.appendAssumeCapacity(.{ .id = id, .name = name, .variant = meta.variant, .model_path = model_path, .icon_path = icon_path, .generated_icon = meta.icon == null, .model = model });
    }
};

test "sample registry has stable IDs, variants, independent models and preserves files" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(path);
    const samples = @import("testBlocks.zig");
    try samples.ensure(a, path);
    var registry = try BlockRegistry.loadDirectory(a, path);
    defer registry.deinit();
    try std.testing.expectEqual(@as(usize, 30), registry.blocks.items.len);
    try std.testing.expectEqual(@as(?u32, 3), registry.find("Checker", 0));
    try std.testing.expectEqual(@as(?u32, 4), registry.find("Checker", 1));
    try std.testing.expect(registry.find("Checker", 2) == null);
    try std.testing.expectEqual(@as(?u32, 15), registry.find("Red", 1));
    try std.testing.expectEqual(@as(?u32, 16), registry.find("Green", 1));
    try std.testing.expectEqual(@as(?u32, 17), registry.find("Blue", 1));
    for ([_][]const u8{ "Gold", "Copper", "Iron", "Mirror" }, [_]u8{ 217, 184, 140, 250 }) |material_name, expected| {
        const material = registry.blocks.items[registry.find(material_name, 0).?].model.blockData.voxel;
        try std.testing.expectEqual(expected, material.getVoxel(0, 0, 0).?.reflectiveness);
    }
    const white = registry.blocks.items[registry.find("White", 0).?].model.blockData.voxel;
    const black = registry.blocks.items[registry.find("Black", 0).?].model.blockData.voxel;
    try std.testing.expectEqual(@as(u8, 255), white.getVoxel(0, 0, 0).?.r);
    try std.testing.expectEqual(@as(u8, 0), black.getVoxel(0, 0, 0).?.r);
    try std.testing.expectEqual(@as(u8, 255), black.getVoxel(0, 0, 0).?.opacity);
    try std.testing.expectEqual(@as(u32, 4096), black.solid_count);
    var clone = try registry.blocks.items[0].model.clone(a);
    defer clone.deinit(a);
    clone.blockData.voxel.clearVoxel(0, 0, 0);
    try std.testing.expect(registry.blocks.items[0].model.blockData.voxel.isOccupied(0, 0, 0));
    try tmp.dir.writeFile(.{ .sub_path = "01_red.block", .data = "name: My Red\nvariant: 2\nmodel: 01_red.vox\nicon: custom.png\n" });
    try samples.ensure(a, path);
    var updated = try BlockRegistry.loadDirectory(a, path);
    defer updated.deinit();
    try std.testing.expectEqual(@as(?u32, 0), updated.find("My Red", 2));
    try std.testing.expect(!updated.blocks.items[0].generated_icon);
    try tmp.dir.writeFile(.{ .sub_path = "duplicate.block", .data = "name: My Red\nvariant: 2\nmodel: 01_red.vox\n" });
    try std.testing.expectError(error.DuplicateBlockNameAndVariant, BlockRegistry.loadDirectory(a, path));
}
