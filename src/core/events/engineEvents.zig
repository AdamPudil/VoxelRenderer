const eventDescriptor = @import("eventDescriptor.zig").EventDescriptor;
const typeDescriptor = @import("eventDescriptor.zig").EventTypeDescriptor;
const onFull = @import("eventDescriptor.zig").EventQueueOnFull;

pub const EngineShutdownData = struct {
    exit_code: u8,
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

pub const InputMode = enum {
    gameplay,
    UI,
    console,
};

pub const InputModeData = struct {
    mode: InputMode,
};

pub const typeTable: []const typeDescriptor = &[8]typeDescriptor{
    typeDescriptor{
        .id = 0,
        .prio = 0,
        .name = "core",
        .queueMsgSize = 256,
        .onFull = onFull{
            .action = .debt_queue,
        },
        .events = &[4]eventDescriptor{
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
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "start_render",
                .dataType = RenderFrameData,
            },
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
        .events = &[4]eventDescriptor{
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
        .events = &[4]eventDescriptor{
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
        .events = &[3]eventDescriptor{
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
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "change_mode",
                .dataType = InputModeData,
            },
        },
    },
};
