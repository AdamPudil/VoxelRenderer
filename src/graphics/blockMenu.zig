const std = @import("std");
const gl = @import("gl.zig");
const gl_utils = @import("gl_utils.zig");
const Registry = @import("../world/blockRegistry.zig").BlockRegistry;
const Icons = @import("blockIcons.zig").Icons;
const c = @cImport({
    @cInclude("GL/glew.h");
});

const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    fn contains(self: Rect, x: f32, y: f32) bool {
        return x >= self.x and y >= self.y and x < self.x + self.w and y < self.y + self.h;
    }
};
const Layout = struct {
    cols: usize,
    rows: usize,
    x: f32,
    y: f32 = 110,
    fn init(width: f32, height: f32) Layout {
        const cols: usize = @intFromFloat(@max(1, @min(8, @floor((width - 48) / 112))));
        const rows: usize = @intFromFloat(@max(1, @floor((height - 210) / 112)));
        return .{ .cols = cols, .rows = rows, .x = (width - @as(f32, @floatFromInt(cols)) * 112) * 0.5 };
    }
    fn cell(self: Layout, index: usize) Rect {
        return .{ .x = self.x + @as(f32, @floatFromInt(index % self.cols)) * 112, .y = self.y + @as(f32, @floatFromInt(index / self.cols)) * 112, .w = 104, .h = 104 };
    }
};

pub const Menu = struct {
    open: bool = false,
    removal: @import("../world/blockEditing.zig").RemovalMode = .{},
    selected: ?u32 = null,
    page: usize = 0,
    program: c_uint,
    screen_loc: c_int,
    rect_loc: c_int,
    color_loc: c_int,
    textured_loc: c_int,

    pub fn init() !Menu {
        const p = try gl_utils.createProgram("src/graphics/shaders/ui");
        return .{ .program = p, .screen_loc = gl.getUniformLocation(p, "uScreen"), .rect_loc = gl.getUniformLocation(p, "uRect"), .color_loc = gl.getUniformLocation(p, "uColor"), .textured_loc = gl.getUniformLocation(p, "uTextured") };
    }
    pub fn deinit(self: *Menu) void {
        gl.deleteProgram(self.program);
    }

    pub fn click(self: *Menu, width: f32, height: f32, x: f32, y: f32, count: usize) void {
        const layout = Layout.init(width, height);
        const per_page = layout.cols * layout.rows;
        const pages = @max(1, (count + per_page - 1) / per_page);
        self.page = @min(self.page, pages - 1);
        if ((Rect{ .x = 24, .y = 62, .w = 180, .h = 32 }).contains(x, y)) {
            self.selected = null;
            return;
        }
        if ((Rect{ .x = 24, .y = height - 80, .w = 110, .h = 30 }).contains(x, y)) {
            self.page -|= 1;
            return;
        }
        if ((Rect{ .x = width - 134, .y = height - 80, .w = 110, .h = 30 }).contains(x, y)) {
            self.page = @min(self.page + 1, pages - 1);
            return;
        }
        for (0..per_page) |i| {
            const id = self.page * per_page + i;
            if (id >= count) break;
            if (layout.cell(i).contains(x, y)) {
                self.selected = if (self.selected != null and self.selected.? == id) null else @intCast(id);
                return;
            }
        }
    }

    pub fn draw(self: *Menu, width: f32, height: f32, mouse_x: f32, mouse_y: f32, registry: *const Registry, icons: *const Icons) !void {
        gl.useProgram(self.program);
        try gl.uniform2f(self.screen_loc, width, height);
        gl.activeTexture(c.GL_TEXTURE0);
        gl.uniform1i(gl.getUniformLocation(self.program, "uImage"), 0);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);
        defer c.glDisable(c.GL_BLEND);
        if (!self.open) {
            self.rect(.{ .x = width / 2 - 4, .y = height / 2, .w = 9, .h = 1 }, .{ 1, 1, 1, 0.85 }, 0);
            self.rect(.{ .x = width / 2, .y = height / 2 - 4, .w = 1, .h = 9 }, .{ 1, 1, 1, 0.85 }, 0);
            self.text(20, 20, "TAB: BLOCKS", .{ 1, 1, 1, 1 });
            self.text(20, 42, if (self.removal.voxel) "V: REMOVE VOXEL" else "V: REMOVE BLOCK", .{ 1, 1, 1, 1 });
            if (self.selected) |id| {
                self.rect(.{ .x = 20, .y = height - 84, .w = 64, .h = 64 }, .{ 1, 1, 1, 1 }, icons.textures[id]);
                self.text(96, height - 65, registry.blocks.items[id].name, .{ 1, 1, 1, 1 });
                self.text(96, height - 43, if (self.removal.voxel) "LEFT: VOXEL  RIGHT: PLACE BLOCK" else "LEFT: BLOCK  RIGHT: PLACE BLOCK", .{ 1, 1, 1, 1 });
            } else {
                self.text(20, height - 62, "EMPTY HAND", .{ 1, 1, 1, 1 });
                self.text(20, height - 40, if (self.removal.voxel) "LEFT: REMOVE VOXEL" else "LEFT: REMOVE BLOCK", .{ 1, 1, 1, 1 });
            }
            return;
        }
        self.rect(.{ .x = 0, .y = 0, .w = width, .h = height }, .{ 0.035, 0.045, 0.065, 0.94 }, 0);
        self.text(24, 24, "BLOCKS", .{ 1, 1, 1, 1 });
        self.text(24, 44, "CLICK TO SELECT - CLICK AGAIN OR RIGHT-CLICK TO CLEAR", .{ 0.65, 0.72, 0.82, 1 });
        self.rect(.{ .x = 24, .y = 62, .w = 180, .h = 32 }, if (self.selected == null) .{ 0.20, 0.38, 0.48, 1 } else .{ 0.12, 0.15, 0.2, 1 }, 0);
        self.text(34, 71, "EMPTY HAND", .{ 1, 1, 1, 1 });
        const layout = Layout.init(width, height);
        const per_page = layout.cols * layout.rows;
        const pages = @max(1, (registry.blocks.items.len + per_page - 1) / per_page);
        self.page = @min(self.page, pages - 1);
        for (0..per_page) |i| {
            const id = self.page * per_page + i;
            if (id >= registry.blocks.items.len) break;
            const entry = registry.blocks.items[id];
            const cell = layout.cell(i);
            const selected = self.selected != null and self.selected.? == id;
            const hover = cell.contains(mouse_x, mouse_y);
            self.rect(cell, if (selected) .{ 0.22, 0.55, 0.68, 1 } else if (hover) .{ 0.22, 0.27, 0.34, 1 } else .{ 0.11, 0.14, 0.19, 1 }, 0);
            self.rect(.{ .x = cell.x + 20, .y = cell.y + 3, .w = 64, .h = 64 }, .{ 1, 1, 1, 1 }, icons.textures[id]);
            self.text(cell.x + 4, cell.y + 70, entry.name[0..@min(entry.name.len, 8)], .{ 1, 1, 1, 1 });
            var buf: [48]u8 = undefined;
            const variant = try std.fmt.bufPrint(&buf, "V{d} #{d}", .{ entry.variant, entry.id });
            self.text(cell.x + 4, cell.y + 88, variant, .{ 0.7, 0.8, 0.9, 1 });
            if (hover) {
                const label = try std.fmt.bufPrint(&buf, "{s} V{d}", .{ entry.name[0..@min(entry.name.len, 32)], entry.variant });
                self.text(160, height - 71, label, .{ 1, 1, 1, 1 });
            }
        }
        self.rect(.{ .x = 24, .y = height - 80, .w = 110, .h = 30 }, .{ 0.12, 0.15, 0.2, 1 }, 0);
        self.text(34, height - 71, "PREV", .{ 1, 1, 1, 1 });
        self.rect(.{ .x = width - 134, .y = height - 80, .w = 110, .h = 30 }, .{ 0.12, 0.15, 0.2, 1 }, 0);
        self.text(width - 124, height - 71, "NEXT", .{ 1, 1, 1, 1 });
        self.text(24, height - 34, "TAB / ESC: RETURN TO GAME", .{ 0.65, 0.72, 0.82, 1 });
    }

    fn rect(self: *Menu, r: Rect, color: [4]f32, texture: c_uint) void {
        c.__glewUniform4f.?(self.rect_loc, r.x, r.y, r.w, r.h);
        c.__glewUniform4f.?(self.color_loc, color[0], color[1], color[2], color[3]);
        gl.uniform1i(self.textured_loc, @intFromBool(texture != 0));
        if (texture != 0) c.glBindTexture(c.GL_TEXTURE_2D, texture);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 6);
    }

    fn text(self: *Menu, x: f32, y: f32, value: []const u8, color: [4]f32) void {
        for (value, 0..) |ch, index| {
            const columns = glyph(std.ascii.toUpper(ch));
            for (columns, 0..) |bits, col| for (0..7) |row| {
                if ((bits >> @as(u3, @intCast(row))) & 1 == 0) continue;
                self.rect(.{ .x = x + @as(f32, @floatFromInt(index * 12 + col * 2)), .y = y + @as(f32, @floatFromInt(row * 2)), .w = 2, .h = 2 }, color, 0);
            };
        }
    }
};

fn glyph(ch: u8) [5]u8 {
    return switch (ch) {
        'A' => .{ 126, 17, 17, 17, 126 },
        'B' => .{ 127, 73, 73, 73, 54 },
        'C' => .{ 62, 65, 65, 65, 34 },
        'D' => .{ 127, 65, 65, 34, 28 },
        'E' => .{ 127, 73, 73, 73, 65 },
        'F' => .{ 127, 9, 9, 9, 1 },
        'G' => .{ 62, 65, 73, 73, 122 },
        'H' => .{ 127, 8, 8, 8, 127 },
        'I' => .{ 0, 65, 127, 65, 0 },
        'J' => .{ 32, 64, 65, 63, 1 },
        'K' => .{ 127, 8, 20, 34, 65 },
        'L' => .{ 127, 64, 64, 64, 64 },
        'M' => .{ 127, 2, 12, 2, 127 },
        'N' => .{ 127, 4, 8, 16, 127 },
        'O' => .{ 62, 65, 65, 65, 62 },
        'P' => .{ 127, 9, 9, 9, 6 },
        'Q' => .{ 62, 65, 81, 33, 94 },
        'R' => .{ 127, 9, 25, 41, 70 },
        'S' => .{ 70, 73, 73, 73, 49 },
        'T' => .{ 1, 1, 127, 1, 1 },
        'U' => .{ 63, 64, 64, 64, 63 },
        'V' => .{ 31, 32, 64, 32, 31 },
        'W' => .{ 63, 64, 56, 64, 63 },
        'X' => .{ 99, 20, 8, 20, 99 },
        'Y' => .{ 7, 8, 112, 8, 7 },
        'Z' => .{ 97, 81, 73, 69, 67 },
        '0' => .{ 62, 81, 73, 69, 62 },
        '1' => .{ 0, 66, 127, 64, 0 },
        '2' => .{ 66, 97, 81, 73, 70 },
        '3' => .{ 33, 65, 69, 75, 49 },
        '4' => .{ 24, 20, 18, 127, 16 },
        '5' => .{ 39, 69, 69, 69, 57 },
        '6' => .{ 60, 74, 73, 73, 48 },
        '7' => .{ 1, 113, 9, 5, 3 },
        '8' => .{ 54, 73, 73, 73, 54 },
        '9' => .{ 6, 73, 73, 41, 30 },
        ':' => .{ 0, 54, 54, 0, 0 },
        '-' => .{ 8, 8, 8, 8, 8 },
        '/' => .{ 32, 16, 8, 4, 2 },
        '#' => .{ 20, 127, 20, 127, 20 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 2, 1, 81, 9, 6 },
    };
}

test "menu selection, toggle, empty hand and pagination" {
    var m = Menu{ .program = 0, .screen_loc = 0, .rect_loc = 0, .color_loc = 0, .textured_loc = 0 };
    const layout = Layout.init(800, 450);
    m.click(800, 450, layout.x + 10, 120, 40);
    try std.testing.expectEqual(@as(?u32, 0), m.selected);
    m.click(800, 450, layout.x + 10, 120, 40);
    try std.testing.expect(m.selected == null);
    m.click(800, 450, 700, 380, 40);
    try std.testing.expectEqual(@as(usize, 1), m.page);
    m.click(800, 450, layout.x + 10, 120, 40);
    try std.testing.expectEqual(@as(?u32, @intCast(layout.cols * layout.rows)), m.selected);
    m.click(800, 450, 40, 75, 40);
    try std.testing.expect(m.selected == null);
}
