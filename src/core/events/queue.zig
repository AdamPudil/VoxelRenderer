const std = @import("std");

const event = @import("event.zig");
const event_desc = @import("eventDescriptor.zig");
const logging = @import("../logging/logging.zig");

pub const PRINT_EVENT_QUEUE_TEST_OUTPUT = true;

pub fn validateEventTypes(comptime descriptors: []const event_desc.EventTypeDescriptor) void {
    for (descriptors, 0..) |type_a, i| {
        event.validateEventTypeDescriptor(type_a);

        if (type_a.queueMsgSize == 0) {
            @compileError(std.fmt.comptimePrint(
                "event queue '{s}' must have a capacity greater than zero",
                .{type_a.name},
            ));
        }

        for (descriptors[i + 1 ..]) |type_b| {
            if (type_a.id == type_b.id) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate event type id {d}: '{s}' and '{s}'",
                    .{ type_a.id, type_a.name, type_b.name },
                ));
            }

            if (std.mem.eql(u8, type_a.name, type_b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate event type name '{s}'",
                    .{type_a.name},
                ));
            }
        }
    }
}

/// Generates a struct with one independently sized ring buffer per event type.
/// Each buffer stores the tagged union generated from that type's event
/// descriptors. Queue fields use the event type names.
pub fn getEventQueue(comptime descriptors: []const event_desc.EventTypeDescriptor) type {
    validateEventTypes(descriptors);

    var fields: [descriptors.len]std.builtin.Type.StructField = undefined;

    for (descriptors, 0..) |descriptor, i| {
        const GeneratedEventType = event.genEventType(descriptor, descriptor.events);
        const Queue = EventQueue(GeneratedEventType.Event, descriptor);

        fields[i] = .{
            .name = descriptor.name ++ "",
            .type = Queue,
            .default_value = &@as(Queue, .{}),
            .is_comptime = false,
            .alignment = @alignOf(Queue),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

pub const RingBufferError = error{ Full, Empty };
pub const QueueSubmitResult = enum {
    queued,
    debt,
    replaced_newest,
    replaced_oldest,
    discarded,
};

pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    return ringBufferType(T, capacity, "Queue");
}

pub fn NamedRingBuffer(
    comptime T: type,
    comptime capacity: usize,
    comptime queue_name: []const u8,
) type {
    return ringBufferType(T, capacity, queue_name);
}

/// A descriptor-aware, frame-buffered event queue. Every queue owns active and
/// next-frame buffers. Only the debt policy adds overflow storage.
pub fn EventQueue(
    comptime T: type,
    comptime descriptor: event_desc.EventTypeDescriptor,
) type {
    const capacity: usize = @intCast(descriptor.queueMsgSize);
    const Buffer = NamedRingBuffer(T, capacity, descriptor.name);
    const has_debt = descriptor.onFull.action == .debt_queue;
    const DebtBuffer = if (has_debt) Buffer else void;

    return struct {
        const Self = @This();

        pub const Value = T;
        pub const Capacity = capacity;
        pub const Descriptor = descriptor;

        active: Buffer = .{},
        next: Buffer = .{},
        debt: DebtBuffer = if (has_debt) .{} else {},

        overflow_count: usize = 0,
        discarded_count: usize = 0,

        pub fn submit(self: *Self, value: T) RingBufferError!QueueSubmitResult {
            self.active.write(value) catch |err| switch (err) {
                RingBufferError.Full => {
                    self.overflow_count += 1;
                    if (descriptor.onFull.warn) {
                        std.log.warn(
                            "event queue '{s}' is full; applying {s}",
                            .{ descriptor.name, @tagName(descriptor.onFull.action) },
                        );
                    }

                    return switch (descriptor.onFull.action) {
                        .debt_queue => blk: {
                            try self.debt.write(value);
                            break :blk .debt;
                        },
                        .override_newest => blk: {
                            try self.active.replaceNewest(value);
                            break :blk .replaced_newest;
                        },
                        .override_oldest => blk: {
                            try self.active.replaceOldest(value);
                            break :blk .replaced_oldest;
                        },
                        .discard => blk: {
                            self.discarded_count += 1;
                            break :blk .discarded;
                        },
                    };
                },
                else => return err,
            };

            return .queued;
        }

        pub fn write(self: *Self, value: T) RingBufferError!void {
            _ = try self.submit(value);
        }

        /// Stages an event for processing during a later frame.
        pub fn writeNext(self: *Self, value: T) RingBufferError!void {
            try self.next.write(value);
        }

        /// Stages an event for its owning consumer and applies the descriptor's
        /// full policy to the staging buffer. This is the producer-side API
        /// used by EventSystem.
        pub fn submitNext(self: *Self, value: T) RingBufferError!QueueSubmitResult {
            self.next.write(value) catch |err| switch (err) {
                RingBufferError.Full => {
                    self.overflow_count += 1;
                    if (descriptor.onFull.warn) {
                        std.log.warn(
                            "event queue '{s}' staging buffer is full; applying {s}",
                            .{ descriptor.name, @tagName(descriptor.onFull.action) },
                        );
                    }

                    return switch (descriptor.onFull.action) {
                        .debt_queue => blk: {
                            try self.debt.write(value);
                            break :blk .debt;
                        },
                        .override_newest => blk: {
                            try self.next.replaceNewest(value);
                            break :blk .replaced_newest;
                        },
                        .override_oldest => blk: {
                            try self.next.replaceOldest(value);
                            break :blk .replaced_oldest;
                        },
                        .discard => blk: {
                            self.discarded_count += 1;
                            break :blk .discarded;
                        },
                    };
                },
                else => return err,
            };

            return .queued;
        }

        pub fn read(self: *Self) RingBufferError!T {
            return self.active.read();
        }

        pub fn peek(self: *const Self) RingBufferError!T {
            return self.active.peek();
        }

        /// Promotes next-frame events first, followed by debt events. Anything
        /// that still does not fit remains queued for a later frame.
        pub fn advanceFrame(self: *Self) usize {
            var promoted = promoteInto(&self.active, &self.next);
            if (comptime has_debt) promoted += promoteInto(&self.active, &self.debt);
            return promoted;
        }

        pub fn clear(self: *Self) void {
            self.active.clear();
            self.next.clear();
            if (comptime has_debt) self.debt.clear();
            self.overflow_count = 0;
            self.discarded_count = 0;
        }

        pub fn getCount(self: *const Self) usize {
            return self.active.getCount();
        }

        pub fn getNextCount(self: *const Self) usize {
            return self.next.getCount();
        }

        pub fn getDebtCount(self: *const Self) usize {
            if (comptime has_debt) return self.debt.getCount();
            return 0;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.active.isEmpty();
        }

        pub fn isFull(self: *const Self) bool {
            return self.active.isFull();
        }

        pub fn logState(self: *const Self) void {
            printQueueName(descriptor.name);
            logging.logger.print(.INFO, "\t- type id: {d}", .{descriptor.id});
            logging.logger.print(.INFO, "\t- priority: {d}", .{descriptor.prio});
            logging.logger.print(
                .INFO,
                "\t- onFull: {s} (warn={})",
                .{ @tagName(descriptor.onFull.action), descriptor.onFull.warn },
            );

            const active_percent = usagePercent(self.active.count, capacity);
            const next_percent = usagePercent(self.next.count, capacity);
            if (comptime has_debt) {
                logging.logger.print(
                    .INFO,
                    "\t- usage: active: {d}% ({d}/{d}), next: {d}% ({d}/{d}), debt: {d}% ({d}/{d})",
                    .{
                        active_percent,
                        self.active.count,
                        capacity,
                        next_percent,
                        self.next.count,
                        capacity,
                        usagePercent(self.debt.count, capacity),
                        self.debt.count,
                        capacity,
                    },
                );
            } else {
                logging.logger.print(
                    .INFO,
                    "\t- usage: active: {d}% ({d}/{d}), next: {d}% ({d}/{d}), debt: 0% (0/0)",
                    .{
                        active_percent,
                        self.active.count,
                        capacity,
                        next_percent,
                        self.next.count,
                        capacity,
                    },
                );
            }
            logging.logger.print(
                .INFO,
                "\t- overflows: {d}, discarded: {d}",
                .{ self.overflow_count, self.discarded_count },
            );

            logItems(T, capacity, &self.active);
        }

        fn promoteInto(destination: *Buffer, source: *Buffer) usize {
            var promoted: usize = 0;
            while (!destination.isFull() and !source.isEmpty()) {
                destination.write(source.read() catch unreachable) catch unreachable;
                promoted += 1;
            }
            return promoted;
        }
    };
}

/// Compatibility name retained while callers migrate to EventQueue.
pub fn EventRingBuffer(
    comptime T: type,
    comptime descriptor: event_desc.EventTypeDescriptor,
) type {
    return EventQueue(T, descriptor);
}

fn ringBufferType(
    comptime T: type,
    comptime capacity: usize,
    comptime queue_name: []const u8,
) type {
    if (capacity == 0) {
        @compileError("ring buffer capacity must be greater than zero");
    }

    return struct {
        const Self = @This();

        pub const Value = T;
        pub const Capacity = capacity;

        read_index: usize = 0,
        write_index: usize = 0,
        count: usize = 0,
        buffer: [capacity]T = undefined,

        pub fn write(self: *Self, value: T) RingBufferError!void {
            if (self.isFull()) return RingBufferError.Full;

            self.buffer[self.write_index] = value;
            self.write_index = (self.write_index + 1) % capacity;
            self.count += 1;
        }

        pub fn read(self: *Self) RingBufferError!T {
            if (self.isEmpty()) return RingBufferError.Empty;

            const value = self.buffer[self.read_index];
            self.read_index = (self.read_index + 1) % capacity;
            self.count -= 1;
            return value;
        }

        pub fn peek(self: *const Self) RingBufferError!T {
            if (self.isEmpty()) return RingBufferError.Empty;
            return self.buffer[self.read_index];
        }

        pub fn clear(self: *Self) void {
            self.read_index = 0;
            self.write_index = 0;
            self.count = 0;
        }

        pub fn getCount(self: *const Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.count == capacity;
        }

        pub fn replaceNewest(self: *Self, value: T) RingBufferError!void {
            if (self.isEmpty()) return RingBufferError.Empty;
            const newest_index = if (self.write_index == 0) capacity - 1 else self.write_index - 1;
            self.buffer[newest_index] = value;
        }

        pub fn replaceOldest(self: *Self, value: T) RingBufferError!void {
            if (self.isEmpty()) return RingBufferError.Empty;
            self.buffer[self.read_index] = value;
            self.read_index = (self.read_index + 1) % capacity;
            self.write_index = self.read_index;
        }

        /// Prints this queue's utilization and its unread events in FIFO order.
        pub fn logState(self: *const Self) void {
            printQueueName(queue_name);

            const used_percent = self.count * 100 / capacity;
            logging.logger.print(
                .INFO,
                "\t- used: {d}% ({d}/{d})",
                .{ used_percent, self.count, capacity },
            );
            logging.logger.print(.INFO, "\t- available: {d}", .{capacity - self.count});
            logItems(T, capacity, self);
        }
    };
}

fn printQueueName(comptime queue_name: []const u8) void {
    if (queue_name.len == 0) {
        logging.logger.print(.INFO, "*-=#[Queue event queue]#=-*", .{});
    } else {
        logging.logger.print(
            .INFO,
            "*-=#[{c}{s} event queue]#=-*",
            .{ std.ascii.toUpper(queue_name[0]), queue_name[1..] },
        );
    }
}

fn usagePercent(count: usize, capacity: usize) usize {
    if (capacity == 0) return 0;
    return count * 100 / capacity;
}

fn logItems(comptime T: type, comptime capacity: usize, buffer: anytype) void {
    for (0..buffer.count) |offset| {
        const index = (buffer.read_index + offset) % capacity;
        const value = buffer.buffer[index];

        switch (@typeInfo(T)) {
            .@"union" => |union_info| {
                if (union_info.tag_type != null) {
                    var event_buffer: [512]u8 = undefined;
                    const event_text = event.eventToString(value, &event_buffer) catch
                        @tagName(std.meta.activeTag(value));
                    logging.logger.print(.INFO, "\t\t- {s}", .{event_text});
                } else {
                    logging.logger.print(.INFO, "\t\t- {any}", .{value});
                }
            },
            else => {
                logging.logger.print(.INFO, "\t\t- {any}", .{value});
            },
        }
    }
}

fn testPrint(comptime format: []const u8, args: anytype) void {
    if (PRINT_EVENT_QUEUE_TEST_OUTPUT) {
        logging.logger.print(.INFO, format, args);
    }
}

test "ring buffer preserves FIFO order through wraparound" {
    var buffer: RingBuffer(u32, 3) = .{};

    try buffer.write(1);
    try buffer.write(2);
    try buffer.write(3);
    try std.testing.expect(buffer.isFull());
    try std.testing.expectError(RingBufferError.Full, buffer.write(4));

    try std.testing.expectEqual(@as(u32, 1), try buffer.read());
    try buffer.write(4);

    try std.testing.expectEqual(@as(u32, 2), try buffer.read());
    try std.testing.expectEqual(@as(u32, 3), try buffer.read());
    try std.testing.expectEqual(@as(u32, 4), try buffer.read());
    try std.testing.expect(buffer.isEmpty());
    try std.testing.expectError(RingBufferError.Empty, buffer.read());
}

fn testOverflowAction(comptime action: event_desc.QueueFullAction) !void {
    const descriptor = event_desc.EventTypeDescriptor{
        .id = 10,
        .prio = 1,
        .name = "tiny",
        .queueMsgSize = 2,
        .onFull = .{ .action = action, .warn = false },
        .events = &.{
            .{ .id = 0, .name = "value", .dataType = u8 },
        },
    };
    const EventType = event.genEventType(descriptor, descriptor.events).Event;
    var queue: EventQueue(EventType, descriptor) = .{};

    try std.testing.expectEqual(
        QueueSubmitResult.queued,
        try queue.submit(EventType{ .value = 1 }),
    );
    try std.testing.expectEqual(
        QueueSubmitResult.queued,
        try queue.submit(EventType{ .value = 2 }),
    );

    const result = try queue.submit(EventType{ .value = 3 });
    try std.testing.expectEqual(@as(usize, 1), queue.overflow_count);

    testPrint("\nTesting onFull behaviour: {s}", .{@tagName(action)});
    if (PRINT_EVENT_QUEUE_TEST_OUTPUT) {
        queue.logState();
        logging.logger.print(.INFO, "\n", .{});
    }

    switch (action) {
        .debt_queue => {
            try std.testing.expectEqual(QueueSubmitResult.debt, result);
            try std.testing.expectEqual(@as(usize, 1), queue.getDebtCount());
            try std.testing.expectEqual(@as(u8, 1), (try queue.read()).value);
            try std.testing.expectEqual(@as(usize, 1), queue.advanceFrame());
        },
        .override_newest => {
            try std.testing.expectEqual(QueueSubmitResult.replaced_newest, result);
        },
        .override_oldest => {
            try std.testing.expectEqual(QueueSubmitResult.replaced_oldest, result);
        },
        .discard => {
            try std.testing.expectEqual(QueueSubmitResult.discarded, result);
            try std.testing.expectEqual(@as(usize, 1), queue.discarded_count);
        },
    }

    const expected_first: u8 = switch (action) {
        .debt_queue, .override_oldest => 2,
        .override_newest, .discard => 1,
    };
    const expected_second: u8 = switch (action) {
        .debt_queue, .override_newest, .override_oldest => 3,
        .discard => 2,
    };

    try std.testing.expectEqual(expected_first, (try queue.read()).value);
    try std.testing.expectEqual(expected_second, (try queue.read()).value);
    try std.testing.expect(queue.isEmpty());
}

test "small event queues apply every full policy" {
    logging.logger.init(.TESTING);
    try testOverflowAction(.debt_queue);
    try testOverflowAction(.override_newest);
    try testOverflowAction(.override_oldest);
    try testOverflowAction(.discard);
}

test "event queues are generated per event type" {
    const EntityId = struct {
        value: u32,
    };

    const descriptors = &[_]event_desc.EventTypeDescriptor{
        .{
            .id = 0,
            .prio = 0,
            .name = "core",
            .queueMsgSize = 2,
            .onFull = .{},
            .events = &.{
                .{ .id = 0, .name = "shutdown", .dataType = void },
            },
        },
        .{
            .id = 1,
            .prio = 1,
            .name = "entity",
            .queueMsgSize = 3,
            .onFull = .{},
            .events = &.{
                .{ .id = 0, .name = "spawn", .dataType = EntityId },
                .{ .id = 1, .name = "despawn", .dataType = EntityId },
            },
        },
    };

    const Queues = getEventQueue(descriptors);
    const CoreEvent = @FieldType(Queues, "core").Value;
    const EntityEvent = @FieldType(Queues, "entity").Value;

    var queues: Queues = .{};
    try queues.core.write(CoreEvent{ .shutdown = {} });
    const spawn_event = EntityEvent{ .spawn = .{ .value = 42 } };
    try queues.entity.write(spawn_event);
    try queues.entity.write(EntityEvent{ .despawn = .{ .value = 7 } });

    var event_buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "spawn(value=42)",
        try event.eventToString(spawn_event, &event_buffer),
    );

    try std.testing.expectEqual(@as(usize, 1), queues.core.getCount());
    try std.testing.expectEqual(@as(usize, 2), queues.entity.getCount());

    switch (try queues.core.read()) {
        .shutdown => {},
    }

    switch (try queues.entity.read()) {
        .spawn => |payload| try std.testing.expectEqual(@as(u32, 42), payload.value),
        else => return error.UnexpectedEvent,
    }

    switch (try queues.entity.read()) {
        .despawn => |payload| try std.testing.expectEqual(@as(u32, 7), payload.value),
        else => return error.UnexpectedEvent,
    }
}

test "built-in engine event queues simulate several frames" {
    const engine_events = @import("engineEvents.zig");
    const descriptors = engine_events.typeTable;
    const Queues = getEventQueue(descriptors);
    const CoreEvent = @FieldType(Queues, "core").Value;
    const RenderEvent = @FieldType(Queues, "render").Value;
    const EntityEvent = @FieldType(Queues, "entity").Value;
    const WorldEvent = @FieldType(Queues, "world").Value;
    const PhysicsEvent = @FieldType(Queues, "physics").Value;
    const AudioEvent = @FieldType(Queues, "audio").Value;
    const UiEvent = @FieldType(Queues, "UI").Value;
    const InputEvent = @FieldType(Queues, "input").Value;

    var queues: Queues = .{};

    testPrint("\n=== Event queue game simulation ===", .{});
    testPrint("\nFrame 1: engine startup and scene creation", .{});

    try queues.core.write(CoreEvent{ .EngineInit = {} });
    try queues.render.write(RenderEvent{ .start_render = .{
        .frame = 1,
        .delta_time = 0.016,
    } });
    try queues.entity.write(EntityEvent{ .spawn = .{
        .entity_id = 1001,
        .archetype_id = 2,
    } });
    try queues.entity.write(EntityEvent{ .spawn = .{
        .entity_id = 1002,
        .archetype_id = 5,
    } });
    try queues.world.write(WorldEvent{ .create = .{
        .world_id = 1,
        .seed = 123456,
    } });
    try queues.physics.write(@unionInit(PhysicsEvent, "?huh?", .{
        .delta_time = 0.016,
    }));
    try queues.audio.write(AudioEvent{ .play = .{
        .sound_id = 12,
        .volume = 0.8,
    } });
    try queues.UI.write(UiEvent{ .create_menu = .{ .menu_id = 3 } });
    try queues.input.write(InputEvent{ .change_mode = .{ .mode = .gameplay } });

    if (PRINT_EVENT_QUEUE_TEST_OUTPUT) {
        queues.core.logState();
        queues.render.logState();
        queues.entity.logState();
        queues.world.logState();
        queues.physics.logState();
        queues.audio.logState();
        queues.UI.logState();
        queues.input.logState();
    }

    try std.testing.expectEqual(@as(usize, 1), queues.core.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.render.getCount());
    try std.testing.expectEqual(@as(usize, 2), queues.entity.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.world.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.physics.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.audio.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.UI.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.input.getCount());

    switch (try queues.core.read()) {
        .EngineInit => {},
        else => return error.UnexpectedEvent,
    }
    _ = try queues.render.read();
    _ = try queues.world.read();
    _ = try queues.physics.read();
    _ = try queues.input.read();

    testPrint("\nFrame 2: gameplay activity", .{});

    try queues.core.write(CoreEvent{ .Pause = {} });
    try queues.entity.write(EntityEvent{ .teleport = .{
        .entity_id = 1001,
        .x = 32,
        .y = 18,
        .z = -7,
    } });
    try queues.entity.write(EntityEvent{ .push = .{
        .entity_id = 1002,
        .impulse_x = 1.5,
        .impulse_y = 4,
        .impulse_z = 0,
    } });
    try queues.world.write(WorldEvent{ .load_area = .{
        .center_x = 2,
        .center_y = 0,
        .center_z = -1,
        .radius = 8,
    } });
    try queues.audio.write(AudioEvent{ .stop = .{ .sound_id = 12 } });
    try queues.UI.write(UiEvent{ .show_menu = .{ .menu_id = 3 } });
    try queues.UI.write(UiEvent{ .hide_menu = .{ .menu_id = 3 } });

    if (PRINT_EVENT_QUEUE_TEST_OUTPUT) {
        queues.core.logState();
        queues.entity.logState();
        queues.world.logState();
        queues.audio.logState();
        queues.UI.logState();
    }

    try std.testing.expectEqual(@as(usize, 1), queues.core.getCount());
    try std.testing.expectEqual(@as(usize, 4), queues.entity.getCount());
    try std.testing.expectEqual(@as(usize, 1), queues.world.getCount());
    try std.testing.expectEqual(@as(usize, 2), queues.audio.getCount());
    try std.testing.expectEqual(@as(usize, 3), queues.UI.getCount());

    switch (try queues.entity.read()) {
        .spawn => {},
        else => return error.UnexpectedEvent,
    }
    switch (try queues.entity.read()) {
        .spawn => {},
        else => return error.UnexpectedEvent,
    }
    switch (try queues.entity.read()) {
        .teleport => {},
        else => return error.UnexpectedEvent,
    }
    switch (try queues.entity.read()) {
        .push => {},
        else => return error.UnexpectedEvent,
    }

    testPrint("\nFrame 3: shutdown requested", .{});

    _ = try queues.core.read();
    try queues.core.write(CoreEvent{ .Resume = {} });
    try queues.core.write(CoreEvent{ .EngineShutdown = .{ .exit_code = 0 } });

    if (PRINT_EVENT_QUEUE_TEST_OUTPUT) {
        queues.core.logState();
    }

    try std.testing.expectEqual(@as(usize, 2), queues.core.getCount());
    try std.testing.expect(queues.entity.isEmpty());

    testPrint("\n=== Simulation finished ===\n\n", .{});
}
