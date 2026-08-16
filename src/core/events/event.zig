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

fn genEventType(comptime typeDesc: typeDescriptor, comptime eventDesc: []const eventDescriptor) type {
    const type_id = typeDesc.id;

    return struct {
        pub const id: u16 = type_id;
        pub const prio: u8 = typeDesc.prio;
        pub const name: []const u8 = typeDesc.name;

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
                .TO_NEXT_FRAME = true,
                .TO_DEBT_QUEUE = false,
                .OVERRIDE_LAST = false,
                .OVERRIDE_FIRST = false,
                .LOSE_MESSAGE = false,

                .ONLY_WARN = false,
                .SILENCED = false,
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
