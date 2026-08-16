const eventDescriptor = @import("eventDescriptor.zig").EventDescriptor;
const typeDescriptor = @import("eventDescriptor.zig").EventTypeDescriptor;
const onFull = @import("eventDescriptor.zig").EventQueueOnFull;

pub const typeTable: []const typeDescriptor = &[8]typeDescriptor{
    typeDescriptor{
        .id = 0,
        .prio = 0,
        .name = "core",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
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
                .dataType = void,
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
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "start_render",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 2,
        .prio = 1,
        .name = "entity",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[4]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "spawn",
                .dataType = void,
            },
            eventDescriptor{
                .id = 1,
                .name = "despawn",
                .dataType = void,
            },
            eventDescriptor{
                .id = 2,
                .name = "teleport",
                .dataType = void,
            },
            eventDescriptor{
                .id = 3,
                .name = "push", // gives entity momentum
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 3,
        .prio = 1,
        .name = "world",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[4]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "create",
                .dataType = void,
            },
            eventDescriptor{
                .id = 1,
                .name = "delete",
                .dataType = void,
            },
            eventDescriptor{
                .id = 2,
                .name = "load_area",
                .dataType = void,
            },
            eventDescriptor{
                .id = 3,
                .name = "save",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 4,
        .prio = 1,
        .name = "physics",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "?huh?",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 5,
        .prio = 1,
        .name = "audio",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[2]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "play",
                .dataType = void,
            },
            eventDescriptor{
                .id = 1,
                .name = "stop",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 6,
        .prio = 1,
        .name = "UI",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[3]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "create_menu",
                .dataType = void,
            },
            eventDescriptor{
                .id = 0,
                .name = "show_menu",
                .dataType = void,
            },
            eventDescriptor{
                .id = 2,
                .name = "hide_menu",
                .dataType = void,
            },
        },
    },
    typeDescriptor{
        .id = 7,
        .prio = 1,
        .name = "input",
        .queueMsgSize = 256,
        .onFull = onFull{
            .TO_NEXT_FRAME = true,
            .TO_DEBT_QUEUE = true,
        },
        .events = &[1]eventDescriptor{
            eventDescriptor{
                .id = 0,
                .name = "change_mode",
                .dataType = void,
            },
        },
    },
};
