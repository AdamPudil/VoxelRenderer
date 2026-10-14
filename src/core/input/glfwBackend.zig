const std = @import("std");
const input = @import("inputSystem.zig");
const t = input.t;
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Single-window adapter. Callbacks only collect; the frame coordinator maps
/// after polling. Overflow is reported instead of losing release events.
pub const Backend = struct {
    window: *c.GLFWwindow,
    events: [256]input.Raw = undefined,
    count: usize = 0,
    overflow: bool = false,
    cursor_menu: bool = false,
    var current: ?*Backend = null;

    pub fn attach(self: *Backend) void {
        std.debug.assert(current == null);
        current = self;
        _ = c.glfwSetKeyCallback(self.window, keyCallback);
        _ = c.glfwSetMouseButtonCallback(self.window, mouseCallback);
        _ = c.glfwSetCursorPosCallback(self.window, cursorCallback);
        _ = c.glfwSetWindowFocusCallback(self.window, focusCallback);
        self.append(.{ .focus = c.glfwGetWindowAttrib(self.window, c.GLFW_FOCUSED) != 0 });
        self.position();
    }
    pub fn detach(self: *Backend) void {
        _ = c.glfwSetKeyCallback(self.window, null);
        _ = c.glfwSetMouseButtonCallback(self.window, null);
        _ = c.glfwSetCursorPosCallback(self.window, null);
        _ = c.glfwSetWindowFocusCallback(self.window, null);
        current = null;
    }
    fn append(self: *Backend, event: input.Raw) void {
        // Preserve button/focus ordering while bounding high-rate pointer input.
        // Consecutive absolute positions have the same net relative displacement.
        if (event == .motion and self.count > 0 and self.events[self.count - 1] == .motion) {
            self.events[self.count - 1] = event;
            return;
        }
        if (self.count == self.events.len) {
            self.overflow = true;
            return;
        }
        self.events[self.count] = event;
        self.count += 1;
    }
    fn position(self: *Backend) void {
        var x: f64 = 0;
        var y: f64 = 0;
        c.glfwGetCursorPos(self.window, &x, &y);
        self.append(.{ .motion = .{ @floatCast(x), @floatCast(y) } });
    }
    pub fn poll(self: *Backend, mapper: *input.InputSystem) !void {
        c.glfwPollEvents();
        if (self.overflow) return error.InputBufferFull;
        for (self.events[0..self.count]) |event| try mapper.feed(event);
        self.count = 0;
        if (self.cursor_menu != mapper.menu) {
            self.cursor_menu = mapper.menu;
            c.glfwSetInputMode(self.window, c.GLFW_CURSOR, if (mapper.menu) c.GLFW_CURSOR_NORMAL else c.GLFW_CURSOR_DISABLED);
            mapper.baseline = false;
            // Seed a fresh baseline after GLFW's cursor warp.
            self.position();
        }
    }
    fn keyCallback(_: ?*c.GLFWwindow, key: c_int, _: c_int, action: c_int, _: c_int) callconv(.C) void {
        if (action == c.GLFW_REPEAT) return;
        inline for (std.meta.fields(t.Key)) |field| {
            if (key == @field(c, "GLFW_KEY_" ++ field.name)) {
                current.?.append(.{ .button = .{ .source = .{ .key = @enumFromInt(field.value) }, .down = action == c.GLFW_PRESS } });
                return;
            }
        }
    }
    fn mouseCallback(_: ?*c.GLFWwindow, button: c_int, action: c_int, _: c_int) callconv(.C) void {
        const mouse: t.Mouse = switch (button) {
            c.GLFW_MOUSE_BUTTON_LEFT => .left,
            c.GLFW_MOUSE_BUTTON_RIGHT => .right,
            c.GLFW_MOUSE_BUTTON_MIDDLE => .middle,
            c.GLFW_MOUSE_BUTTON_4 => .button4,
            c.GLFW_MOUSE_BUTTON_5 => .button5,
            c.GLFW_MOUSE_BUTTON_6 => .button6,
            c.GLFW_MOUSE_BUTTON_7 => .button7,
            c.GLFW_MOUSE_BUTTON_8 => .button8,
            else => return,
        };
        current.?.position();
        current.?.append(.{ .button = .{ .source = .{ .mouse = mouse }, .down = action == c.GLFW_PRESS } });
    }
    fn cursorCallback(_: ?*c.GLFWwindow, x: f64, y: f64) callconv(.C) void {
        current.?.append(.{ .motion = .{ @floatCast(x), @floatCast(y) } });
    }
    fn focusCallback(_: ?*c.GLFWwindow, focused: c_int) callconv(.C) void {
        current.?.append(.{ .focus = focused != 0 });
    }
};

test "backend coalesces motion without moving it across button boundaries" {
    var backend = Backend{ .window = undefined };
    backend.append(.{ .motion = .{ 1, 2 } });
    backend.append(.{ .motion = .{ 3, 4 } });
    backend.append(.{ .button = .{ .source = .{ .mouse = .left }, .down = true } });
    backend.append(.{ .motion = .{ 5, 6 } });
    try std.testing.expectEqual(@as(usize, 3), backend.count);
    try std.testing.expectEqual([2]f32{ 3, 4 }, backend.events[0].motion);
    try std.testing.expect(backend.events[1] == .button);
    try std.testing.expectEqual([2]f32{ 5, 6 }, backend.events[2].motion);
}

test "backend keeps key press and release but ignores native repeat" {
    var backend = Backend{ .window = undefined };
    Backend.current = &backend;
    defer Backend.current = null;
    Backend.keyCallback(null, c.GLFW_KEY_W, 0, c.GLFW_PRESS, 0);
    Backend.keyCallback(null, c.GLFW_KEY_W, 0, c.GLFW_REPEAT, 0);
    Backend.keyCallback(null, c.GLFW_KEY_W, 0, c.GLFW_RELEASE, 0);
    try std.testing.expectEqual(@as(usize, 2), backend.count);
    try std.testing.expect(backend.events[0].button.down);
    try std.testing.expect(!backend.events[1].button.down);
    try std.testing.expectEqual(t.Key.W, backend.events[0].button.source.key);
    while (backend.count < backend.events.len) backend.append(.{ .focus = true });
    backend.append(.{ .focus = false });
    try std.testing.expect(backend.overflow);
}
