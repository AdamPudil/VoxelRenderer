const std = @import("std");
const t = @import("types.zig");

/// Modes select bindings; actions select their owning subsystem and event type.
pub const Route = struct { queue: []const u8, event: []const u8 };
pub fn route(comptime action: t.Action) Route {
    return switch (action) {
        .forward, .backward, .left, .right, .up, .down => .{ .queue = "entity", .event = "move" },
        .look => .{ .queue = "entity", .event = "look" },
        .remove => .{ .queue = "world", .event = "remove" },
        .place => .{ .queue = "world", .event = "place" },
        .toggle_removal => .{ .queue = "world", .event = "toggle_removal" },
        .toggle_menu => .{ .queue = "UI", .event = "menu_input" },
        .activate => .{ .queue = "UI", .event = "activate" },
        .deselect => .{ .queue = "UI", .event = "deselect" },
        .pointer => .{ .queue = "UI", .event = "pointer" },
        .screenshot => .{ .queue = "render", .event = "screenshot" },
        .toggle_fps => .{ .queue = "render", .event = "toggle_fps" },
        .back => .{ .queue = "core", .event = "EngineShutdown" },
    };
}

pub fn emit(bus: anytype, action: t.ActionEvent) !void {
    inline for (std.meta.fields(t.Action)) |field| {
        const id: t.Action = @enumFromInt(field.value);
        if (action.action == id) {
            const destination = comptime route(id);
            const Event = @TypeOf(@field(bus.queues, destination.queue)).Value;
            if (comptime std.mem.eql(u8, destination.event, "move")) {
                var direction = [3]f32{ 0, 0, 0 };
                const amount = action.value[0];
                switch (id) {
                    .forward => direction[2] = -amount,
                    .backward => direction[2] = amount,
                    .left => direction[0] = -amount,
                    .right => direction[0] = amount,
                    .up => direction[1] = amount,
                    .down => direction[1] = -amount,
                    else => unreachable,
                }
                try bus.submitCurrent(destination.queue, @unionInit(Event, destination.event, .{ .direction = direction, .input_action = action }));
            } else if (comptime std.mem.eql(u8, destination.queue, "entity") or std.mem.eql(u8, destination.queue, "world")) {
                try bus.submitCurrent(destination.queue, @unionInit(Event, destination.event, .{ .input_action = action }));
            } else if (comptime id == .back) {
                // Shutdown is a request, not a held action; reuse the existing event.
                if (action.phase == .started) try bus.submitCurrent("core", Event{ .EngineShutdown = .{ .exit_code = 0, .input_action = action } });
            } else {
                try bus.submitCurrent(destination.queue, @unionInit(Event, destination.event, action));
            }
            return;
        }
    }
    unreachable;
}

/// Normalized view for the temporary developer-tool adapter, not an event queue.
/// Real subsystem consumers can use their typed payloads directly.
pub const Output = union(enum) {
    action: t.ActionEvent,
    command_result: t.Result,
    bindings_snapshot: t.BindingState,
    rebind_candidate: t.Candidate,
};

pub fn output(event: anytype) ?Output {
    switch (event) {
        inline else => |payload, tag| {
            if (comptime @TypeOf(payload) == t.ActionEvent) return .{ .action = payload };
            if (comptime @TypeOf(payload) == t.Result) return .{ .command_result = payload };
            if (comptime @TypeOf(payload) == t.BindingState) return .{ .bindings_snapshot = payload };
            if (comptime @TypeOf(payload) == t.Candidate) return .{ .rebind_candidate = payload };
            if (comptime std.mem.eql(u8, @tagName(tag), "EngineShutdown")) {
                if (payload.input_action) |action| return .{ .action = action };
            } else if (comptime @typeInfo(@TypeOf(payload)) == .@"struct") {
                if (comptime @hasField(@TypeOf(payload), "input_action")) return .{ .action = payload.input_action };
            }
            return null;
        },
    }
}

pub const queues = .{ "entity", "world", "UI", "render", "core" };

/// Temporary main-thread subsystem adapters for the current developer renderer.
/// Merge queue heads by sequence so a menu change cannot overtake a preceding
/// click or cancellation. This does not enqueue/copy actions into a shared queue.
/// Replace these adapters with subsystem consumers when real entities are wired.
pub fn drainForDeveloperTools(bus: anytype, handler: anytype) !void {
    while (true) {
        var selected: ?usize = null;
        var sequence: u64 = std.math.maxInt(u64);
        inline for (queues, 0..) |name, i| {
            if (@field(bus.queues, name).peek()) |event| {
                const normalized = output(event);
                const order = if (normalized != null and normalized.? == .action) normalized.?.action.sequence else 0;
                if (selected == null or order < sequence) {
                    selected = i;
                    sequence = order;
                }
            } else |_| {}
        }
        if (selected == null) return;
        inline for (queues, 0..) |name, i| {
            if (selected.? == i) {
                const event = try @field(bus.queues, name).read();
                if (output(event)) |normalized| try handler.handle(name, normalized);
            }
        }
    }
}
