pub const EventQueueOnFull = struct {
    TO_NEXT_FRAME: bool = false,
    TO_DEBT_QUEUE: bool = false,
    OVERRIDE_LAST: bool = false,
    OVERRIDE_FIRST: bool = false,
    LOSE_MESSAGE: bool = false,

    ONLY_WARN: bool = false,
    SILENCED: bool = false,
};

pub const EventTypeDescriptor = struct {
    id: u16,
    prio: u8,

    name: []const u8,

    queueMsgSize: u64,
    onFull: EventQueueOnFull,

    events: []const EventDescriptor,
};

pub const EventDescriptor = struct {
    //event info
    id: u32,
    name: []const u8,
    //typeId: u16,
    //prio: u8,

    //queue descriptor
    dataType: type,
};
