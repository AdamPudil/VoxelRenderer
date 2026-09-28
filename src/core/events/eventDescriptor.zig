pub const QueueFullAction = enum {
    debt_queue,
    override_newest,
    override_oldest,
    discard,
};

pub const EventQueueOnFull = struct {
    action: QueueFullAction = .debt_queue,
    warn: bool = true,
};

/// The execution context that exclusively consumes an event-type queue.
/// Multiple event types may belong to the same consumer.
pub const EventConsumer = enum {
    event_loop,
    render,
    entity,
    world,
    physics,
    audio,
    UI,
    input,
    inventory,
};

pub const EventTypeDescriptor = struct {
    id: u16,
    prio: u8,

    name: []const u8,

    consumer: EventConsumer = .event_loop,

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
