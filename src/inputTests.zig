const std = @import("std");
const input = @import("core/input/inputSystem.zig");
const t = input.t;

const Recorder = struct {
    events: [256]input.Output = undefined,
    count: usize = 0,
    pub fn handle(self: *Recorder, comptime name: []const u8, event: input.Output) !void {
        _ = name;
        self.events[self.count] = event;
        self.count += 1;
    }
    fn drain(self: *Recorder, bus: *input.Bus) !void {
        try input.routing.drainForDeveloperTools(bus, self);
        try std.testing.expect(outputCount(bus) == 0);
    }
    fn has(self: *const Recorder, action: t.Action, phase: t.Phase) bool {
        for (self.events[0..self.count]) |event| switch (event) {
            .action => |data| if (data.action == action and data.phase == phase) return true,
            else => {},
        };
        return false;
    }
};
fn outputCount(bus: *input.Bus) usize {
    var count: usize = 0;
    inline for (input.routing.queues) |name| count += @field(bus.queues, name).getCount();
    return count;
}
fn busCreate() !*input.Bus {
    const bus = try std.testing.allocator.create(input.Bus);
    bus.* = .{};
    return bus;
}
fn key(mapper: *input.InputSystem, code: t.Key, down: bool) !void {
    try mapper.feed(.{ .button = .{ .source = .{ .key = code }, .down = down } });
}
fn mouse(mapper: *input.InputSystem, code: t.Mouse, down: bool) !void {
    try mapper.feed(.{ .button = .{ .source = .{ .mouse = code }, .down = down } });
}

test "current-frame taps retain both edges and drain without replay" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    bus.beginFrame();
    try mapper.begin(1);
    try key(&mapper, .W, true);
    try key(&mapper, .W, false);
    try std.testing.expectEqual(@as(usize, 2), outputCount(bus));
    try std.testing.expectEqual(@as(usize, 0), bus.queues.UI.getNextCount());
    var recorder = Recorder{};
    try recorder.drain(bus);
    try std.testing.expectEqual(t.Phase.started, recorder.events[0].action.phase);
    try std.testing.expectEqual(t.Phase.ended, recorder.events[1].action.phase);
    try std.testing.expectEqual(@as(u64, 1), recorder.events[0].action.frame);
    bus.beginFrame();
    try mapper.begin(2);
    try std.testing.expect(outputCount(bus) == 0);
}

test "deferred commands apply at frame start and draining preserves next frame" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    _ = try bus.submit("input", input.Command{ .set_enabled = false });
    try std.testing.expect(mapper.enabled);
    bus.beginFrame();
    try mapper.begin(1);
    try std.testing.expect(!mapper.enabled);
    _ = try bus.submit("input", input.Command{ .set_enabled = true });
    var recorder = Recorder{};
    try recorder.drain(bus);
    try std.testing.expectEqual(@as(usize, 1), bus.queues.input.getNextCount());
    bus.beginFrame();
    try mapper.begin(2);
    try std.testing.expect(mapper.enabled);
    try std.testing.expect(bus.queues.input.isEmpty());
}

test "runtime rebind is atomic and multiple bindings combine until final release" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    var bindings = t.Bindings.one(.{ .key = .E });
    bindings.count = 2;
    bindings.sources[1] = .{ .key = .R };
    try bus.submitCurrent("input", .{ .replace_bindings = .{ .request_id = 42, .action = .forward, .bindings = bindings } });
    try mapper.begin(1);
    var recorder = Recorder{};
    try recorder.drain(bus);
    try std.testing.expectEqual(@as(u64, 1), mapper.revision);
    try key(&mapper, .W, true);
    try std.testing.expect(outputCount(bus) == 0);
    try key(&mapper, .E, true);
    try key(&mapper, .R, true);
    try key(&mapper, .E, false);
    try std.testing.expectEqual(@as(usize, 1), outputCount(bus));
    try key(&mapper, .R, false);
    recorder.count = 0;
    try recorder.drain(bus);
    try std.testing.expect(recorder.has(.forward, .ended));
    bindings.count = 5;
    try bus.submitCurrent("input", .{ .replace_bindings = .{ .request_id = 43, .action = .forward, .bindings = bindings } });
    try mapper.begin(2);
    try std.testing.expectEqual(@as(u64, 1), mapper.revision);
    try std.testing.expectEqual(t.Key.E, mapper.profile.bindings[@intFromEnum(t.Action.forward)].sources[0].key);
    const rejected = try bus.queues.UI.read();
    try std.testing.expectEqual(t.Status.invalid_binding, rejected.command_result.status);
}

test "menu cancels movement and held clicks cannot edit after closing" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try key(&mapper, .W, true);
    try key(&mapper, .TAB, true);
    try std.testing.expect(mapper.menu);
    try mouse(&mapper, .left, true);
    var recorder = Recorder{};
    try recorder.drain(bus);
    try std.testing.expect(recorder.has(.forward, .cancelled));
    try std.testing.expect(recorder.has(.activate, .started));
    try std.testing.expect(!recorder.has(.remove, .started));
    try key(&mapper, .TAB, false);
    try key(&mapper, .ESCAPE, true);
    try std.testing.expect(!mapper.menu);
    recorder.count = 0;
    try recorder.drain(bus);
    try std.testing.expect(!recorder.has(.back, .started));
    try std.testing.expect(!recorder.has(.remove, .started));
    try std.testing.expect(!recorder.has(.forward, .started));
    try mouse(&mapper, .left, false);
    try mouse(&mapper, .left, true);
    recorder.count = 0;
    try recorder.drain(bus);
    try std.testing.expect(recorder.has(.remove, .started));
}

test "focus and rebind cancel held actions without phantom presses" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try key(&mapper, .W, true);
    try mapper.feed(.{ .focus = false });
    try mapper.feed(.{ .focus = true });
    try key(&mapper, .E, true);
    var recorder = Recorder{};
    try recorder.drain(bus);
    try std.testing.expect(recorder.has(.forward, .cancelled));
    try std.testing.expect(!mapper.active[@intFromEnum(t.Action.forward)]);
    try key(&mapper, .W, false);
    try key(&mapper, .W, true);
    try bus.submitCurrent("input", .{ .replace_bindings = .{ .request_id = 1, .action = .forward, .bindings = t.Bindings.one(.{ .key = .E }) } });
    try mapper.begin(2);
    try std.testing.expect(!mapper.active[@intFromEnum(t.Action.forward)]);
    try key(&mapper, .E, false);
    try key(&mapper, .E, true);
    try std.testing.expect(mapper.active[@intFromEnum(t.Action.forward)]);
}

test "capture is exclusive and returns one candidate until applied or cancelled" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try bus.submitCurrent("input", .{ .begin_rebind = .{ .request_id = 7, .action = .forward } });
    try mapper.begin(1);
    var recorder = Recorder{};
    try recorder.drain(bus);
    try key(&mapper, .S, true);
    const candidate = try bus.queues.UI.read();
    try std.testing.expectEqual(t.Action.backward, candidate.rebind_candidate.conflict.?);
    try key(&mapper, .S, false);
    try key(&mapper, .W, true);
    try std.testing.expect(outputCount(bus) == 0);
    try bus.submitCurrent("input", .{ .cancel_rebind = 7 });
    try mapper.begin(2);
    try std.testing.expect(mapper.capture == null);
}

test "look delta resets on cursor context change and repeat is ignored" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try mapper.feed(.{ .motion = .{ 100, 100 } });
    try mapper.feed(.{ .motion = .{ 105, 98 } });
    const look = try bus.queues.entity.read();
    try std.testing.expectEqual([2]f32{ 5, -2 }, look.look.input_action.value);
    try key(&mapper, .F3, true);
    try key(&mapper, .F3, true);
    try std.testing.expectEqual(@as(usize, 1), outputCount(bus));
    var recorder = Recorder{};
    try recorder.drain(bus);
    try bus.submitCurrent("input", .{ .set_menu = true });
    try mapper.begin(2);
    try mapper.feed(.{ .motion = .{ 1000, 1000 } });
    recorder.count = 0;
    try recorder.drain(bus);
    try std.testing.expect(!recorder.has(.look, .changed));
    try std.testing.expect(recorder.has(.pointer, .changed));
}

test "profiles use named actions, preserve unbinding, and save atomically" {
    const allocator = std.testing.allocator;
    const profile = try t.parseProfile(allocator,
        \\{"version":1,"mode":"developer","bindings":[{"action":"forward","sources":[{"key":"E"}]},{"action":"screenshot","sources":[]}]}
    );
    try std.testing.expectEqual(t.Key.E, profile.bindings[@intFromEnum(t.Action.forward)].sources[0].key);
    try std.testing.expectEqual(@as(u8, 0), profile.bindings[@intFromEnum(t.Action.screenshot)].count);
    try std.testing.expectEqual(t.Key.S, profile.bindings[@intFromEnum(t.Action.backward)].sources[0].key);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try t.saveProfile(allocator, tmp.dir, "input.json", profile);
    const loaded = try t.loadProfile(allocator, tmp.dir, "input.json");
    try std.testing.expectEqualDeep(profile, loaded);
    try std.testing.expectError(error.InvalidProfile, t.parseProfile(allocator,
        \\{"version":2,"bindings":[]}
    ));
}

test "current-frame overflow reports failure instead of deferring or discarding" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    for (0..@TypeOf(bus.queues.UI).Capacity) |_| try bus.submitCurrent("UI", .{ .command_result = .{ .request_id = 0, .revision = 0, .status = .applied } });
    try std.testing.expectError(error.Full, bus.submitCurrent("UI", .{ .command_result = .{ .request_id = 1, .revision = 0, .status = .applied } }));
    try std.testing.expectEqual(@as(usize, 0), bus.queues.UI.getNextCount());
    try std.testing.expectEqual(@as(usize, 0), bus.queues.UI.getDebtCount());
}

test "frame cleanup retires current events but preserves deferred work" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    const Core = @FieldType(input.Bus.QueueCollection, "core").Value;
    try bus.submitCurrent("core", .{ .Pause = {} });
    _ = try bus.submit("core", Core{ .Resume = {} });
    bus.clearCurrent();
    try std.testing.expect(bus.queues.core.isEmpty());
    try std.testing.expectEqual(@as(usize, 1), bus.queues.core.getNextCount());
    bus.beginFrame();
    try std.testing.expectEqual(std.meta.Tag(Core).Resume, std.meta.activeTag(try bus.queues.core.read()));
}

test "GLFW event collector" {
    _ = @import("core/input/glfwBackend.zig");
}

test "disabled capture cannot bind a new control" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try bus.submitCurrent("input", .{ .begin_rebind = .{ .request_id = 1, .action = .forward } });
    try bus.submitCurrent("input", .{ .set_enabled = false });
    try mapper.begin(1);
    var recorder = Recorder{};
    try recorder.drain(bus);
    try key(&mapper, .E, true);
    try std.testing.expect(outputCount(bus) == 0);
}

test "actions go straight to their owning queues with nonexistent test targets" {
    const events = @import("core/events/engineEvents.zig");
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    try std.testing.expect(!@hasField(input.Bus.QueueCollection, "developer"));
    var mapper = input.InputSystem{ .bus = bus };
    try mapper.begin(10);
    try key(&mapper, .W, true);
    const move = try bus.queues.entity.read();
    try std.testing.expect(move == .move);
    try std.testing.expectEqual(events.TEST_ENTITY_ID, move.move.entity_id);
    try std.testing.expectEqual([3]f32{ 0, 0, -1 }, move.move.direction);
    try std.testing.expectEqual(@as(u64, 10), move.move.input_action.frame);
    try key(&mapper, .W, false);
    const stopped = try bus.queues.entity.read();
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, stopped.move.direction);
    try std.testing.expectEqual(t.Phase.ended, stopped.move.input_action.phase);
    try mouse(&mapper, .left, true);
    const edit = try bus.queues.world.read();
    try std.testing.expect(edit == .remove);
    try std.testing.expectEqual(events.TEST_WORLD_ID, edit.remove.world_id);
    try std.testing.expectEqual(events.TEST_ENTITY_ID, edit.remove.entity_id);
    try key(&mapper, .F2, true);
    try std.testing.expect((try bus.queues.render.read()) == .screenshot);
    try key(&mapper, .F3, true);
    try std.testing.expect((try bus.queues.render.read()) == .toggle_fps);
    try key(&mapper, .ESCAPE, true);
    const quit = try bus.queues.core.read();
    try std.testing.expect(quit == .EngineShutdown);
    try std.testing.expectEqual(@as(u8, 0), quit.EngineShutdown.exit_code);
    try std.testing.expect(bus.queues.UI.isEmpty());
    inline for (input.routing.queues) |name| try std.testing.expectEqual(@as(usize, 0), @field(bus.queues, name).getNextCount());
}

test "test adapters preserve action order across subsystem queues" {
    const bus = try busCreate();
    defer std.testing.allocator.destroy(bus);
    var mapper = input.InputSystem{ .bus = bus };
    try mouse(&mapper, .left, true);
    try key(&mapper, .TAB, true);
    try mapper.feed(.{ .motion = .{ 5, 6 } });
    try mouse(&mapper, .left, false);
    try mouse(&mapper, .left, true);
    var recorder = Recorder{};
    try recorder.drain(bus);
    var previous: u64 = 0;
    for (recorder.events[0..recorder.count]) |event| {
        if (event == .action) {
            try std.testing.expect(event.action.sequence > previous);
            previous = event.action.sequence;
        }
    }
    try std.testing.expect(recorder.has(.remove, .started));
    try std.testing.expect(recorder.has(.remove, .cancelled));
    try std.testing.expect(recorder.has(.toggle_menu, .changed));
    try std.testing.expect(recorder.has(.activate, .started));
}
