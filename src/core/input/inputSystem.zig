const std = @import("std");
pub const t = @import("types.zig");
pub const Bus = @import("../events/eventSystem.zig").EventSystem(@import("../events/engineEvents.zig").typeTable);
pub const Command = @FieldType(Bus.QueueCollection, "input").Value;
pub const routing = @import("routing.zig");
pub const Output = routing.Output;
const key_count = std.meta.fields(t.Key).len;
const source_count = key_count + std.meta.fields(t.Mouse).len;
pub const Raw = union(enum) {
    button: struct { source: t.Source, down: bool },
    motion: [2]f32,
    focus: bool,
};

pub const InputSystem = struct {
    bus: *Bus,
    profile: t.Profile = .{},
    frame: u64 = 0,
    sequence: u64 = 0,
    generation: u64 = 0,
    revision: u64 = 0,
    enabled: bool = true,
    focused: bool = true,
    menu: bool = false,
    held: [source_count]bool = .{false} ** source_count,
    blocked: [source_count]bool = .{false} ** source_count,
    active: [t.action_count]bool = .{false} ** t.action_count,
    pointer: [2]f32 = .{ 0, 0 },
    baseline: bool = false,
    capture: ?t.Rebind = null,
    capture_ready: bool = false,

    pub fn begin(self: *InputSystem, frame: u64) !void {
        self.frame = frame;
        _ = try self.bus.drainCurrent(.input, "input", self);
    }

    pub fn handle(self: *InputSystem, comptime name: []const u8, command: Command) !void {
        _ = name;
        switch (command) {
            .change_mode => |data| {
                if (data.mode == .developer) try self.cancel();
                try self.result(0, if (data.mode == .developer) .applied else .unsupported_mode);
            },
            .set_enabled => |enabled| {
                try self.cancel();
                self.enabled = enabled;
            },
            .set_menu => |menu| try self.setMenu(menu),
            .replace_bindings => |data| {
                var profile = self.profile;
                profile.mode = data.mode;
                profile.bindings[@intFromEnum(data.action)] = data.bindings;
                try self.apply(data.request_id, profile);
            },
            .reset_bindings => |data| try self.apply(data.request_id, .{ .mode = data.mode }),
            .apply_profile => |data| try self.apply(data.request_id, data.profile),
            .query_bindings => |data| {
                if (data.mode != .developer) return self.result(data.request_id, .unsupported_mode);
                for (self.profile.bindings, 0..) |bindings, i| {
                    try self.bus.submitCurrent("UI", .{ .bindings_snapshot = .{
                        .request_id = data.request_id,
                        .revision = self.revision,
                        .action = @enumFromInt(i),
                        .bindings = bindings,
                    } });
                }
            },
            .begin_rebind => |data| {
                if (data.mode != .developer) return self.result(data.request_id, .unsupported_mode);
                if (!t.bindable(data.action)) return self.result(data.request_id, .invalid_binding);
                if (self.capture) |old| try self.result(old.request_id, .cancelled);
                try self.cancel();
                self.capture = data;
                self.capture_ready = true;
                try self.result(data.request_id, .capturing);
            },
            .cancel_rebind => |id| {
                self.capture = null;
                try self.cancel();
                try self.result(id, .cancelled);
            },
        }
    }

    fn apply(self: *InputSystem, request: u64, profile: t.Profile) !void {
        const status = t.validate(profile);
        if (status == .applied) {
            try self.cancel();
            self.capture = null;
            self.profile = profile;
            self.revision += 1;
        }
        try self.result(request, status);
    }

    fn result(self: *InputSystem, request: u64, status: t.Status) !void {
        try self.bus.submitCurrent("UI", .{ .command_result = .{
            .request_id = request,
            .status = status,
            .revision = self.revision,
        } });
    }

    fn emit(self: *InputSystem, action: t.Action, phase: t.Phase, value: [2]f32) !void {
        self.sequence += 1;
        try routing.emit(self.bus, .{
            .sequence = self.sequence,
            .frame = self.frame,
            .generation = self.generation,
            .action = action,
            .phase = phase,
            .value = value,
        });
    }

    fn cancel(self: *InputSystem) !void {
        for (&self.active, 0..) |*active, i| {
            if (active.*) try self.emit(@enumFromInt(i), .cancelled, .{ 0, 0 });
            active.* = false;
        }
        self.blocked = self.held;
        self.baseline = false;
        self.generation += 1;
        try self.emit(.look, .cancelled, .{ 0, 0 });
    }

    fn setMenu(self: *InputSystem, menu: bool) !void {
        if (self.menu == menu) return;
        try self.cancel();
        self.menu = menu;
        try self.emit(.toggle_menu, .changed, .{ if (menu) 1 else 0, 0 });
    }

    fn index(source: t.Source) usize {
        return switch (source) {
            .key => |key| @intFromEnum(key),
            .mouse => |button| key_count + @intFromEnum(button),
        };
    }

    fn allowed(self: *const InputSystem, action: t.Action) bool {
        if (!self.enabled or !self.focused or self.capture != null) return false;
        if (t.worldAction(action)) return !self.menu;
        if (t.menuAction(action)) return self.menu;
        return true;
    }

    pub fn feed(self: *InputSystem, raw: Raw) !void {
        switch (raw) {
            .focus => |focused| {
                try self.cancel();
                self.focused = focused;
            },
            .motion => |position| {
                const previous = self.pointer;
                self.pointer = position;
                if (self.allowed(.pointer)) try self.emit(.pointer, .changed, position);
                if (self.baseline and self.allowed(.look)) {
                    const delta = [2]f32{ position[0] - previous[0], position[1] - previous[1] };
                    if (delta[0] != 0 or delta[1] != 0) try self.emit(.look, .changed, delta);
                }
                self.baseline = true;
            },
            .button => |button| {
                const idx = index(button.source);
                if (self.held[idx] == button.down) return; // Ignore native repeat.
                self.held[idx] = button.down;
                if (!button.down) self.blocked[idx] = false;
                if (self.capture) |capture| {
                    if (!self.enabled or !self.focused) return;
                    if (button.down and !self.blocked[idx] and self.capture_ready) {
                        // Wait until all controls held on entry have been released.
                        for (self.blocked) |blocked| if (blocked) return;
                        var conflict: ?t.Action = null;
                        for (self.profile.bindings, 0..) |bindings, i| {
                            const action: t.Action = @enumFromInt(i);
                            if (action == capture.action or (t.worldAction(action) and t.menuAction(capture.action)) or (t.menuAction(action) and t.worldAction(capture.action))) continue;
                            for (bindings.sources[0..bindings.count]) |source| {
                                if (index(source) == idx) {
                                    conflict = action;
                                    break;
                                }
                            }
                        }
                        try self.bus.submitCurrent("UI", .{ .rebind_candidate = .{
                            .request_id = capture.request_id,
                            .action = capture.action,
                            .source = button.source,
                            .conflict = conflict,
                        } });
                        // Remain exclusive until settings applies or cancels.
                        self.blocked[idx] = true;
                        self.capture_ready = false;
                    }
                    return;
                }
                // Process menu/back before world bindings, independent of enum order.
                for ([_]t.Action{ .toggle_menu, .back }) |action| {
                    const down = self.isDown(action);
                    const was_down = self.active[@intFromEnum(action)];
                    self.active[@intFromEnum(action)] = down;
                    if (down and !was_down) {
                        if (action == .toggle_menu) {
                            try self.setMenu(!self.menu);
                        } else if (self.menu) {
                            try self.setMenu(false);
                        } else {
                            try self.emit(.back, .started, .{ 1, 0 });
                        }
                    } else if (!down and was_down) try self.emit(action, .ended, .{ 0, 0 });
                }
                for (0..t.action_count) |i| {
                    const action: t.Action = @enumFromInt(i);
                    if (action == .toggle_menu or action == .back or !t.bindable(action)) continue;
                    const down = self.isDown(action);
                    if (down == self.active[i]) continue;
                    self.active[i] = down;
                    // Pointer coordinates accompany menu clicks, preserving ordering.
                    const value: [2]f32 = if (action == .activate) self.pointer else .{ if (down) 1 else 0, 0 };
                    try self.emit(action, if (down) .started else .ended, value);
                    if (action == .toggle_removal and down) {
                        // World edit buttons must return to neutral after switching.
                        for ([_]t.Action{ .remove, .place }) |edit| {
                            const j = @intFromEnum(edit);
                            if (self.active[j]) try self.emit(edit, .cancelled, .{ 0, 0 });
                            self.active[j] = false;
                            const bindings = self.profile.bindings[j];
                            for (bindings.sources[0..bindings.count]) |source| self.blocked[index(source)] = self.held[index(source)];
                        }
                    }
                }
            },
        }
    }

    fn isDown(self: *const InputSystem, action: t.Action) bool {
        if (!self.allowed(action)) return false;
        const bindings = self.profile.bindings[@intFromEnum(action)];
        for (bindings.sources[0..bindings.count]) |source| {
            const idx = index(source);
            if (self.held[idx] and !self.blocked[idx]) return true;
        }
        return false;
    }
};
