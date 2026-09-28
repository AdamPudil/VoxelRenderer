const std = @import("std");

const descriptor = @import("eventDescriptor.zig");
const event_module = @import("event.zig");
const queue_module = @import("queue.zig");
const logging = @import("../logging/logging.zig");

pub const PRINT_EVENT_SYSTEM_TEST_OUTPUT = true;

/// Builds the routed event system. Each event-type queue has exactly one
/// consumer, declared by EventTypeDescriptor.consumer. Producers may submit
/// from any thread; only the owner should call processConsumer/processType.
pub fn EventSystem(comptime descriptors: []const descriptor.EventTypeDescriptor) type {
    const Queues = queue_module.getEventQueue(descriptors);

    return struct {
        const Self = @This();

        pub const QueueCollection = Queues;

        queues: Queues = .{},
        locks: [descriptors.len]std.Thread.Mutex = [_]std.Thread.Mutex{.{}} ** descriptors.len,

        /// Type-safe producer API. Events are staged for the owner's next
        /// processing pass and never modify the buffer currently being read.
        pub fn submit(
            self: *Self,
            comptime queue_name: []const u8,
            value: anytype,
        ) queue_module.RingBufferError!queue_module.QueueSubmitResult {
            const index = comptime descriptorIndex(queue_name);
            const Expected = @FieldType(Queues, queue_name).Value;
            if (@TypeOf(value) != Expected) {
                @compileError(std.fmt.comptimePrint(
                    "event for queue '{s}' must be {s}, got {s}",
                    .{ queue_name, @typeName(Expected), @typeName(@TypeOf(value)) },
                ));
            }
            self.locks[index].lock();
            defer self.locks[index].unlock();
            return @field(self.queues, queue_name).submitNext(value);
        }

        /// Processes every queue owned by consumer. Handler must provide:
        ///   handle(comptime queue_name: []const u8, event: QueueEvent) !void
        pub fn processConsumer(
            self: *Self,
            comptime consumer: descriptor.EventConsumer,
            handler: anytype,
        ) !usize {
            var processed: usize = 0;
            inline for (descriptors, 0..) |desc, index| {
                if (desc.consumer == consumer) {
                    processed += try self.processIndex(desc.name, index, handler);
                }
            }
            return processed;
        }

        /// Processes one owned queue. Useful when a system wants explicit
        /// ordering between several queues it owns.
        pub fn processType(
            self: *Self,
            comptime consumer: descriptor.EventConsumer,
            comptime queue_name: []const u8,
            handler: anytype,
        ) !usize {
            const index = comptime descriptorIndex(queue_name);
            if (descriptors[index].consumer != consumer) {
                @compileError(std.fmt.comptimePrint(
                    "consumer '{s}' does not own event queue '{s}'",
                    .{ @tagName(consumer), queue_name },
                ));
            }
            return self.processIndex(queue_name, index, handler);
        }

        /// Prints the state of every queue owned by one consumer.
        pub fn logConsumer(
            self: *Self,
            comptime consumer: descriptor.EventConsumer,
        ) void {
            logging.logger.print(
                .INFO,
                "EventSystem consumer: {s}",
                .{@tagName(consumer)},
            );
            inline for (descriptors, 0..) |desc, index| {
                if (desc.consumer == consumer) {
                    self.locks[index].lock();
                    defer self.locks[index].unlock();
                    const owned_queue = &@field(self.queues, desc.name);
                    const capacity: usize = @intCast(desc.queueMsgSize);
                    logging.logger.print(
                        .INFO,
                        "Queue [{s}] usage: active: {d}% ({d}/{d}), next: {d}% ({d}/{d}), debt: {d}% ({d}/{d})",
                        .{
                            desc.name,
                            usagePercent(owned_queue.getCount(), capacity),
                            owned_queue.getCount(),
                            capacity,
                            usagePercent(owned_queue.getNextCount(), capacity),
                            owned_queue.getNextCount(),
                            capacity,
                            usagePercent(owned_queue.getDebtCount(), capacity),
                            owned_queue.getDebtCount(),
                            if (desc.onFull.action == .debt_queue) capacity else 0,
                        },
                    );
                }
            }
        }

        fn processIndex(
            self: *Self,
            comptime queue_name: []const u8,
            comptime index: usize,
            handler: anytype,
        ) !usize {
            var owned_queue = &@field(self.queues, queue_name);

            // Producers only touch next/debt while holding this lock. The
            // consumer promotes them, then reads active without holding it.
            self.locks[index].lock();
            _ = owned_queue.advanceFrame();
            self.locks[index].unlock();

            var processed: usize = 0;
            while (owned_queue.read()) |value| {
                try handler.handle(queue_name, value);
                processed += 1;
            } else |err| switch (err) {
                error.Empty => {},
                else => return err,
            }
            return processed;
        }

        fn descriptorIndex(comptime queue_name: []const u8) usize {
            inline for (descriptors, 0..) |desc, index| {
                if (std.mem.eql(u8, desc.name, queue_name)) return index;
            }
            @compileError(std.fmt.comptimePrint(
                "unknown event queue '{s}'",
                .{queue_name},
            ));
        }

        fn usagePercent(count: usize, capacity: usize) usize {
            if (capacity == 0) return 0;
            return count * 100 / capacity;
        }
    };
}

test "EventSystem routes queue types to their exclusive consumers" {
    const descriptors = &[_]descriptor.EventTypeDescriptor{
        .{
            .id = 0,
            .prio = 0,
            .name = "core",
            .consumer = .event_loop,
            .queueMsgSize = 4,
            .onFull = .{ .warn = false },
            .events = &.{.{ .id = 0, .name = "tick", .dataType = u8 }},
        },
        .{
            .id = 1,
            .prio = 1,
            .name = "entity",
            .consumer = .entity,
            .queueMsgSize = 4,
            .onFull = .{ .warn = false },
            .events = &.{.{ .id = 0, .name = "spawn", .dataType = u32 }},
        },
    };
    const System = EventSystem(descriptors);
    const CoreEvent = @FieldType(System.QueueCollection, "core").Value;
    const EntityEvent = @FieldType(System.QueueCollection, "entity").Value;

    const Handler = struct {
        core_sum: u32 = 0,
        entity_sum: u32 = 0,

        fn handle(self: *@This(), comptime name: []const u8, value: anytype) !void {
            if (PRINT_EVENT_SYSTEM_TEST_OUTPUT) {
                var buffer: [128]u8 = undefined;
                const text = try event_module.eventToString(value, &buffer);
                logging.logger.print(.INFO, "[{s}] handled {s}", .{ name, text });
            }
            if (comptime std.mem.eql(u8, name, "core")) self.core_sum += value.tick;
            if (comptime std.mem.eql(u8, name, "entity")) self.entity_sum += value.spawn;
        }
    };

    var system: System = .{};
    var handler: Handler = .{};
    logging.logger.init(.TESTING);
    _ = try system.submit("core", CoreEvent{ .tick = 2 });
    _ = try system.submit("entity", EntityEvent{ .spawn = 40 });
    _ = try system.submit("entity", EntityEvent{ .spawn = 2 });

    if (PRINT_EVENT_SYSTEM_TEST_OUTPUT) {
        logging.logger.print(.INFO, "=== EventSystem routing simulation ===", .{});
        logging.logger.print(.INFO, "After producer submissions:", .{});
        system.logConsumer(.event_loop);
        system.logConsumer(.entity);
        logging.logger.print(.INFO, "Event-loop processing pass:", .{});
    }

    try std.testing.expectEqual(@as(usize, 1), try system.processConsumer(.event_loop, &handler));
    try std.testing.expectEqual(@as(u32, 2), handler.core_sum);
    try std.testing.expectEqual(@as(u32, 0), handler.entity_sum);

    if (PRINT_EVENT_SYSTEM_TEST_OUTPUT) {
        logging.logger.print(.INFO, "Entity-system processing pass:", .{});
    }
    try std.testing.expectEqual(@as(usize, 2), try system.processType(.entity, "entity", &handler));
    try std.testing.expectEqual(@as(u32, 42), handler.entity_sum);

    if (PRINT_EVENT_SYSTEM_TEST_OUTPUT) {
        logging.logger.print(.INFO, "After both consumers processed their queues:", .{});
        system.logConsumer(.event_loop);
        system.logConsumer(.entity);
        logging.logger.print(.SUCCESS, "=== EventSystem simulation finished ===", .{});
    }
}

test "EventSystem defers events submitted during processing" {
    const descriptors = &[_]descriptor.EventTypeDescriptor{.{
        .id = 0,
        .prio = 0,
        .name = "core",
        .queueMsgSize = 4,
        .onFull = .{ .warn = false },
        .events = &.{.{ .id = 0, .name = "tick", .dataType = u8 }},
    }};
    const System = EventSystem(descriptors);
    const CoreEvent = @FieldType(System.QueueCollection, "core").Value;

    const Handler = struct {
        system: *System,
        seen: [4]u8 = undefined,
        count: usize = 0,

        fn handle(self: *@This(), comptime name: []const u8, value: anytype) !void {
            _ = name;
            self.seen[self.count] = value.tick;
            self.count += 1;
            if (value.tick == 1) _ = try self.system.submit("core", CoreEvent{ .tick = 2 });
        }
    };

    var system: System = .{};
    var handler = Handler{ .system = &system };
    _ = try system.submit("core", CoreEvent{ .tick = 1 });

    try std.testing.expectEqual(@as(usize, 1), try system.processConsumer(.event_loop, &handler));
    try std.testing.expectEqualSlices(u8, &.{1}, handler.seen[0..handler.count]);
    try std.testing.expectEqual(@as(usize, 1), try system.processConsumer(.event_loop, &handler));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, handler.seen[0..handler.count]);
}

test "EventSystem accepts multiple producer threads" {
    const descriptors = &[_]descriptor.EventTypeDescriptor{.{
        .id = 0,
        .prio = 0,
        .name = "entity",
        .consumer = .entity,
        .queueMsgSize = 64,
        .onFull = .{ .warn = false },
        .events = &.{.{ .id = 0, .name = "command", .dataType = u16 }},
    }};
    const System = EventSystem(descriptors);
    const EntityEvent = @FieldType(System.QueueCollection, "entity").Value;

    const Producer = struct {
        fn run(system: *System, first: u16) void {
            for (first..first + 20) |number| {
                _ = system.submit("entity", EntityEvent{
                    .command = @intCast(number),
                }) catch unreachable;
            }
        }
    };
    const Handler = struct {
        count: usize = 0,
        sum: usize = 0,

        fn handle(self: *@This(), comptime name: []const u8, value: anytype) !void {
            _ = name;
            self.count += 1;
            self.sum += value.command;
        }
    };

    var system: System = .{};
    const producer_a = try std.Thread.spawn(.{}, Producer.run, .{ &system, @as(u16, 1) });
    const producer_b = try std.Thread.spawn(.{}, Producer.run, .{ &system, @as(u16, 21) });
    producer_a.join();
    producer_b.join();

    var handler: Handler = .{};
    try std.testing.expectEqual(@as(usize, 40), try system.processConsumer(.entity, &handler));
    try std.testing.expectEqual(@as(usize, 40), handler.count);
    try std.testing.expectEqual(@as(usize, 820), handler.sum);
}
