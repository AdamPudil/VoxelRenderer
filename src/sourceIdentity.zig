//! Content identity includes modified and untracked source/assets, independent of mtimes.
const std = @import("std");
pub fn fingerprint(a: std.mem.Allocator) ![64]u8 {
    return fingerprintPaths(a, &.{ "src", "assets/blocks", "libs" }, &.{ "build.zig", "build.zig.zon" });
}
pub fn assets(a: std.mem.Allocator, root: []const u8) ![64]u8 {
    return fingerprintPaths(a, &.{root}, &.{});
}
fn fingerprintPaths(a: std.mem.Allocator, roots: []const []const u8, files: []const []const u8) ![64]u8 {
    var paths = std.ArrayList([]const u8).init(a);
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit();
    }
    for (roots) |root| {
        var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .file or std.mem.startsWith(u8, entry.path, "icons/")) continue;
            try paths.append(try std.fs.path.join(a, &.{ root, entry.path }));
        }
    }
    for (files) |p| try paths.append(try a.dupe(u8, p));
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (paths.items) |path| {
        hash.update(path);
        hash.update(&.{0});
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        var content_hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [65536]u8 = undefined;
        while (true) {
            const len = try file.read(&buffer);
            if (len == 0) break;
            content_hash.update(buffer[0..len]);
        }
        hash.update(&content_hash.finalResult());
    }
    return std.fmt.bytesToHex(hash.finalResult(), .lower);
}
