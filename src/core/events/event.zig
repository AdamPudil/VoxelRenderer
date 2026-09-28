const std = @import("std");
const logging = @import("../logging/logging.zig");

const eventDescriptor = @import("eventDescriptor.zig").EventDescriptor;
const typeDescriptor = @import("eventDescriptor.zig").EventTypeDescriptor;
const onFull = @import("eventDescriptor.zig").EventQueueOnFull;

const engineEventTypes = @import("engineEvents.zig").typeTable;

pub const typeInfo = struct {
    id: u16,
    name: []const u8,
};

pub const eventInfo = struct {
    id: u32,
    name: []const u8,
};

pub fn eventToString(value: anytype, buffer: []u8) ![]const u8 {
    const Event = @TypeOf(value);
    const union_info = switch (@typeInfo(Event)) {
        .@"union" => |info| info,
        else => @compileError("eventToString expects a tagged union"),
    };
    if (union_info.tag_type == null) {
        @compileError("eventToString expects a tagged union");
    }

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    const active_tag = std.meta.activeTag(value);

    inline for (union_info.fields) |field| {
        if (active_tag == @field(union_info.tag_type.?, field.name)) {
            try writer.print("{s}(", .{field.name});

            const payload = @field(value, field.name);
            switch (@typeInfo(field.type)) {
                .void => {},
                .@"struct" => |struct_info| {
                    inline for (struct_info.fields, 0..) |payload_field, i| {
                        if (i != 0) try writer.writeAll(", ");
                        try writer.print(
                            "{s}={any}",
                            .{ payload_field.name, @field(payload, payload_field.name) },
                        );
                    }
                },
                else => try writer.print("data={any}", .{payload}),
            }

            try writer.writeByte(')');
            return stream.getWritten();
        }
    }

    unreachable;
}

pub fn validateEventTypeDescriptor(comptime typeDesc: typeDescriptor) void {
    if (typeDesc.events.len == 0) {
        @compileError(std.fmt.comptimePrint(
            "event type '{s}' must define at least one event",
            .{typeDesc.name},
        ));
    }

    for (typeDesc.events, 0..) |event_a, i| {
        for (typeDesc.events[i + 1 ..]) |event_b| {
            if (event_a.id == event_b.id) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate event id {d} in event type '{s}'",
                    .{ event_a.id, typeDesc.name },
                ));
            }

            if (std.mem.eql(u8, event_a.name, event_b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate event name '{s}' in event type '{s}'",
                    .{ event_a.name, typeDesc.name },
                ));
            }
        }
    }
}

fn genEventUnion(comptime eventDesc: []const eventDescriptor) type {
    var tag_fields: [eventDesc.len]std.builtin.Type.EnumField = undefined;
    var union_fields: [eventDesc.len]std.builtin.Type.UnionField = undefined;

    for (eventDesc, 0..) |descriptor, i| {
        tag_fields[i] = .{
            .name = descriptor.name ++ "",
            .value = descriptor.id,
        };
        union_fields[i] = .{
            .name = descriptor.name ++ "",
            .type = descriptor.dataType,
            .alignment = @alignOf(descriptor.dataType),
        };
    }

    const Tag = @Type(.{ .@"enum" = .{
        .tag_type = u32,
        .fields = &tag_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = Tag,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

pub fn genEventType(comptime typeDesc: typeDescriptor, comptime eventDesc: []const eventDescriptor) type {
    validateEventTypeDescriptor(typeDesc);

    const type_id = typeDesc.id;

    return struct {
        pub const id: u16 = type_id;
        pub const prio: u8 = typeDesc.prio;
        pub const name: []const u8 = typeDesc.name;
        pub const Event = genEventUnion(eventDesc);

        pub fn toString(value: Event, buffer: []u8) ![]const u8 {
            return eventToString(value, buffer);
        }

        pub const events: [eventDesc.len]type = blk: {
            var result: [eventDesc.len]type = undefined;

            for (eventDesc, 0..) |event, i| {
                result[i] = getEventStruct(event);
            }

            break :blk result;
        };

        fn getTypeInfo() typeInfo {
            return .{
                .id = id,
                .name = name,
            };
        }

        fn getEventStruct(comptime eventDescI: eventDescriptor) type {
            return struct {
                pub const id: u32 = @as(u32, type_id) << 16 | eventDescI.id;
                pub const name: []const u8 = eventDescI.name;
                data: eventDescI.dataType,
            };
        }
    };
}

test "genEventType generates correct type and events" {
    const SpawnData = struct {
        entity_id: u32,
    };

    const MoveData = struct {
        entity_id: u32,
        x: f32,
        y: f32,
    };

    const GeneratedType = genEventType(
        typeDescriptor{
            .id = 5,
            .prio = 10,
            .name = "entity",

            .queueMsgSize = 128,
            .onFull = .{
                .action = .debt_queue,
                .warn = false,
            },
            .events = &[_]eventDescriptor{
                .{
                    .id = 1,
                    .name = "spawn",
                    .dataType = SpawnData,
                },
                .{
                    .id = 2,
                    .name = "move",
                    .dataType = MoveData,
                },
            },
        },
        &[_]eventDescriptor{
            .{
                .id = 1,
                .name = "spawn",
                .dataType = SpawnData,
            },
            .{
                .id = 2,
                .name = "move",
                .dataType = MoveData,
            },
        },
    );

    // Event type metadata
    try std.testing.expectEqual(@as(u16, 5), GeneratedType.id);
    try std.testing.expectEqual(@as(u8, 10), GeneratedType.prio);
    try std.testing.expectEqualStrings("entity", GeneratedType.name);

    // Generated event count
    try std.testing.expectEqual(
        @as(usize, 2),
        GeneratedType.events.len,
    );

    const SpawnEvent = GeneratedType.events[0];
    const MoveEvent = GeneratedType.events[1];

    // Generated event IDs
    try std.testing.expectEqual(
        (@as(u32, 5) << 16) | @as(u32, 1),
        SpawnEvent.id,
    );

    try std.testing.expectEqual(
        (@as(u32, 5) << 16) | @as(u32, 2),
        MoveEvent.id,
    );

    // Generated event names
    try std.testing.expectEqualStrings("spawn", SpawnEvent.name);
    try std.testing.expectEqualStrings("move", MoveEvent.name);

    // Generated data fields
    const spawn = SpawnEvent{
        .data = .{
            .entity_id = 42,
        },
    };

    try std.testing.expectEqual(
        @as(u32, 42),
        spawn.data.entity_id,
    );

    const move = MoveEvent{
        .data = .{
            .entity_id = 7,
            .x = 10.5,
            .y = -4.0,
        },
    };

    try std.testing.expectEqual(@as(u32, 7), move.data.entity_id);
    try std.testing.expectEqual(@as(f32, 10.5), move.data.x);
    try std.testing.expectEqual(@as(f32, -4.0), move.data.y);

    // getTypeInfo
    const info = GeneratedType.getTypeInfo();

    try std.testing.expectEqual(@as(u16, 5), info.id);
    try std.testing.expectEqualStrings("entity", info.name);

    std.debug.print("=== Testing genEventType ===\n", .{});

    std.debug.print(
        "Generated type: id={}, prio={}, name=\"{s}\"\n",
        .{
            GeneratedType.id,
            GeneratedType.prio,
            GeneratedType.name,
        },
    );

    std.debug.print(
        "Generated {} events\n",
        .{GeneratedType.events.len},
    );

    std.debug.print(
        "SpawnEvent: id=0x{x}, name=\"{s}\"\n",
        .{
            SpawnEvent.id,
            SpawnEvent.name,
        },
    );

    std.debug.print(
        "MoveEvent : id=0x{x}, name=\"{s}\"\n",
        .{
            MoveEvent.id,
            MoveEvent.name,
        },
    );

    std.debug.print(
        "Spawn data: entity_id={}\n",
        .{
            spawn.data.entity_id,
        },
    );

    std.debug.print(
        "Move data: entity_id={}, x={}, y={}\n",
        .{
            move.data.entity_id,
            move.data.x,
            move.data.y,
        },
    );

    std.debug.print(
        "TypeInfo: id={}, name=\"{s}\"\n",
        .{
            info.id,
            info.name,
        },
    );

    std.debug.print("=== Test finished successfully ===\n", .{});
}

test "Load engine buildin events" {
    logging.logger.init(logging.format.ProductionStage.TESTING);
    logging.logger.print(logging.format.OutputType.INFO, "=== Testing Engine Events ===", .{});

    inline for (engineEventTypes) |eventType| {
        const eventGeneratedType = genEventType(eventType, eventType.events);

        logging.logger.print(logging.format.OutputType.INFO, "EventType:\t[{s}] [0x{x}] loaded.", .{ eventGeneratedType.name, eventGeneratedType.id });

        inline for (eventGeneratedType.events) |eventT| {
            logging.logger.print(logging.format.OutputType.INFO, "Event:\t\t[{s}] [{s}] [0x{x}] loaded.", .{ eventGeneratedType.name, eventT.name, eventT.id });
        }
    }

    logging.logger.print(logging.format.OutputType.SUCCESS, "=== Test finished ===", .{});
}
