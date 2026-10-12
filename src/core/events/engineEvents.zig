const input = @import("../input/types.zig");
const eventDescriptor = @import("eventDescriptor.zig").EventDescriptor;
const typeDescriptor = @import("eventDescriptor.zig").EventTypeDescriptor;
const onFull = @import("eventDescriptor.zig").EventQueueOnFull;

pub const EngineShutdownData = struct {
    exit_code: u8,
    input_action: ?input.ActionEvent = null,
};

pub const RenderFrameData = struct {
    frame: u64,
    delta_time: f32,
};

pub const EntitySpawnData = struct {
    entity_id: u64,
    archetype_id: u32,
};

pub const EntityIdData = struct {
    entity_id: u64,
};

pub const EntityTeleportData = struct {
    entity_id: u64,
    x: f32,
    y: f32,
    z: f32,
};

pub const EntityPushData = struct {
    entity_id: u64,
    impulse_x: f32,
    impulse_y: f32,
    impulse_z: f32,
};

pub const WorldCreateData = struct {
    world_id: u32,
    seed: u64,
};

pub const WorldIdData = struct {
    world_id: u32,
};

pub const WorldAreaData = struct {
    center_x: i32,
    center_y: i32,
    center_z: i32,
    radius: u16,
};

pub const PhysicsStepData = struct {
    delta_time: f32,
};

pub const AudioPlayData = struct {
    sound_id: u32,
    volume: f32,
};

pub const AudioStopData = struct {
    sound_id: u32,
};

pub const MenuData = struct {
    menu_id: u32,
};

// Deliberately nonexistent targets for routing tests. No entity/world is spawned.
pub const TEST_ENTITY_ID: u64 = 0xffff_ffff_ffff_ffff;
pub const TEST_WORLD_ID: u32 = 0xffff_ffff;
pub const EntityMoveData = struct {
    entity_id: u64 = TEST_ENTITY_ID,
    direction: [3]f32,
    input_action: input.ActionEvent,
};
pub const EntityLookData = struct {
    entity_id: u64 = TEST_ENTITY_ID,
    input_action: input.ActionEvent,
};
pub const WorldEditInputData = struct {
    world_id: u32 = TEST_WORLD_ID,
    entity_id: u64 = TEST_ENTITY_ID,
    input_action: input.ActionEvent,
};

pub const InputMode = input.Mode;

pub const InputModeData = struct {
    mode: InputMode,
};

pub const typeTable: []const typeDescriptor = &.{
    typeDescriptor{
        .id = 0,
        .prio = 0,
        .name = "core",
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            eventDescriptor{
                .id = 0,
                .name = "EngineInit",
                .dataType = void,
            },
            eventDescriptor{
                .id = 1,
                .name = "EngineShutdown",
                .dataType = EngineShutdownData,
            },
            eventDescriptor{
                .id = 2,
                .name = "Pause",
                .dataType = void,
            },
            eventDescriptor{
                .id = 3,
                .name = "Resume",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 1,
        .prio = 1,
        .name = "render",
        .consumer = .render,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            eventDescriptor{
                .id = 0,
                .name = "start_render",
                .dataType = RenderFrameData,
            },
            .{ .id = 1, .name = "screenshot", .dataType = input.ActionEvent },
            .{ .id = 2, .name = "toggle_fps", .dataType = input.ActionEvent },
        },
    },
    typeDescriptor{
        .id = 2,
        .prio = 1,
        .name = "entity",
        .consumer = .entity,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            eventDescriptor{
                .id = 0,
                .name = "spawn",
                .dataType = EntitySpawnData,
            },
            eventDescriptor{
                .id = 1,
                .name = "despawn",
                .dataType = EntityIdData,
            },
            eventDescriptor{
                .id = 2,
                .name = "teleport",
                .dataType = EntityTeleportData,
            },
            eventDescriptor{
                .id = 3,
                .name = "push", // gives entity momentum
                .dataType = EntityPushData,
            },
            .{ .id = 4, .name = "move", .dataType = EntityMoveData },
            .{ .id = 5, .name = "look", .dataType = EntityLookData },
        },
    },
    typeDescriptor{
        .id = 3,
        .prio = 1,
        .name = "world",
        .consumer = .world,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            eventDescriptor{
                .id = 0,
                .name = "create",
                .dataType = WorldCreateData,
            },
            eventDescriptor{
                .id = 1,
                .name = "delete",
                .dataType = WorldIdData,
            },
            eventDescriptor{
                .id = 2,
                .name = "load_area",
                .dataType = WorldAreaData,
            },
            eventDescriptor{
                .id = 3,
                .name = "save",
                .dataType = WorldIdData,
            },
            .{ .id = 4, .name = "remove", .dataType = WorldEditInputData },
            .{ .id = 5, .name = "place", .dataType = WorldEditInputData },
            .{ .id = 6, .name = "toggle_removal", .dataType = WorldEditInputData },
        },
    },
    typeDescriptor{
        .id = 4,
        .prio = 1,
        .name = "physics",
        .consumer = .physics,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "?huh?",
                .dataType = PhysicsStepData,
            },
        },
    },
    typeDescriptor{
        .id = 5,
        .prio = 1,
        .name = "audio",
        .consumer = .audio,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &[2]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "play",
                .dataType = AudioPlayData,
            },
            eventDescriptor{
                .id = 1,
                .name = "stop",
                .dataType = AudioStopData,
            },
        },
    },
    typeDescriptor{
        .id = 6,
        .prio = 1,
        .name = "UI",
        .consumer = .UI,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            eventDescriptor{
                .id = 0,
                .name = "create_menu",
                .dataType = MenuData,
            },
            eventDescriptor{
                .id = 1,
                .name = "show_menu",
                .dataType = MenuData,
            },
            eventDescriptor{
                .id = 2,
                .name = "hide_menu",
                .dataType = MenuData,
            },
            .{ .id = 3, .name = "menu_input", .dataType = input.ActionEvent },
            .{ .id = 4, .name = "activate", .dataType = input.ActionEvent },
            .{ .id = 5, .name = "deselect", .dataType = input.ActionEvent },
            .{ .id = 6, .name = "pointer", .dataType = input.ActionEvent },
            .{ .id = 7, .name = "command_result", .dataType = input.Result },
            .{ .id = 8, .name = "bindings_snapshot", .dataType = input.BindingState },
            .{ .id = 9, .name = "rebind_candidate", .dataType = input.Candidate },
        },
    },
    typeDescriptor{
        .id = 7,
        .prio = 1,
        .name = "input",
        .consumer = .input,
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &.{
            .{ .id = 0, .name = "change_mode", .dataType = InputModeData },
            .{ .id = 1, .name = "set_enabled", .dataType = bool },
            .{ .id = 2, .name = "set_menu", .dataType = bool },
            .{ .id = 3, .name = "replace_bindings", .dataType = input.Replace },
            .{ .id = 4, .name = "reset_bindings", .dataType = input.Request },
            .{ .id = 5, .name = "apply_profile", .dataType = input.ApplyProfile },
            .{ .id = 6, .name = "query_bindings", .dataType = input.Request },
            .{ .id = 7, .name = "begin_rebind", .dataType = input.Rebind },
            .{ .id = 8, .name = "cancel_rebind", .dataType = u64 },
        },
    },
};
