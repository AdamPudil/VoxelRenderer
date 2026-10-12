const std = @import("std");

/// Require both a short frame gap and 0.20 seconds, independent of frame rate.
pub const EditCooldown = struct {
    next_time: f64 = 0,
    frames_left: u8 = 0,
    armed: bool = false,

    pub fn update(self: *EditCooldown, now: f64, in_menu: bool, left: bool, right: bool) bool {
        self.frames_left -|= 1;
        if (in_menu) {
            self.armed = false;
            return false;
        }
        if (!left and !right) {
            self.armed = true;
            return false;
        }
        if (!self.armed or now < self.next_time or self.frames_left > 0) return false;
        self.next_time = now + 0.20;
        self.frames_left = 6;
        return true;
    }
};

test "cooldown limits held clicks and blocks menu click-through" {
    var c = EditCooldown{};
    try std.testing.expect(!c.update(0, false, false, false));
    try std.testing.expect(c.update(0, false, true, false));
    for (0..10) |_| try std.testing.expect(!c.update(0.05, false, true, false));
    try std.testing.expect(c.update(0.21, false, true, false));
    try std.testing.expect(!c.update(1, true, false, true));
    try std.testing.expect(!c.update(2, false, false, true));
    try std.testing.expect(!c.update(2, false, false, false));
    for (0..6) |_| _ = c.update(2.05, false, false, false);
    try std.testing.expect(c.update(2.1, false, false, true));
}

/// Edge-triggered V toggle. Holding V or pressing it in the menu cannot repeat.
pub const RemovalMode = struct {
    voxel: bool = false,
    key_down: bool = false,

    pub fn update(self: *RemovalMode, down: bool, in_menu: bool) bool {
        const toggle = down and !self.key_down and !in_menu;
        self.key_down = down;
        if (toggle) self.voxel = !self.voxel;
        return toggle;
    }
};

test "V toggles once per press and ignores menu input" {
    var mode = RemovalMode{};
    try std.testing.expect(mode.update(true, false));
    try std.testing.expect(mode.voxel);
    for (0..10) |_| try std.testing.expect(!mode.update(true, false));
    _ = mode.update(false, false);
    try std.testing.expect(mode.update(true, false));
    try std.testing.expect(!mode.voxel);
    _ = mode.update(false, true);
    try std.testing.expect(!mode.update(true, true));
    try std.testing.expect(!mode.update(true, false));
    try std.testing.expect(!mode.voxel);
}
