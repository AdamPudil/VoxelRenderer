const std = @import("std");
const camera = @import("core/camera/cameraSystem.zig");
const CameraSystem = camera.CameraSystem;
const Vec3 = camera.Vec3;
const Quaternion = camera.Quaternion;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const Bus = @import("core/events/eventSystem.zig").EventSystem(@import("core/events/engineEvents.zig").typeTable);
const Command = @FieldType(Bus.QueueCollection, "camera").Value;

fn newBus() !*Bus {
    const bus = try std.testing.allocator.create(Bus);
    bus.* = .{};
    return bus;
}

fn expectVector(expected: Vec3, actual: Vec3) !void {
    try expect(expected.approxEql(actual, 0.00001));
}

test "registry owns independent cameras and rejects stale or fabricated handles" {
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const first = try system.create(.{ .world_id = 7 });
    const second = try system.create(.{ .world_id = 8 });
    try expectEqual(@as(usize, 2), system.count());
    try expectError(error.InvalidHandle, system.get(.{ .index = 999, .generation = 1 }));
    try expectError(error.InvalidHandle, system.get(.{ .index = first.index, .generation = 0 }));
    try system.destroy(first);
    try expectError(error.InvalidHandle, system.destroy(first));
    const replacement = try system.create(.{ .world_id = 9 });
    try expectEqual(first.index, replacement.index);
    try expect(first.generation != replacement.generation);
    try expectError(error.InvalidHandle, system.get(first));
    try expectError(error.InvalidHandle, system.resolve(first));
    try expectError(error.InvalidHandle, system.setTransform(first, .{}));
    try expectError(error.InvalidHandle, system.setFov(first, 1));
    try expectEqual(@as(u32, 8), (try system.get(second)).world_id);
    try expectEqual(@as(u32, 9), (try system.get(replacement)).world_id);
    try system.destroy(second);
    try system.destroy(replacement);
    try expectEqual(@as(usize, 0), system.count());
}

test "invalid transforms and FOV reject atomically on create and update" {
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const id = try system.create(.{ .world_id = 1 });
    const before = try system.get(id);
    const bad_transforms = [_]camera.Transform{
        .{ .position = Vec3.init(std.math.nan(f32), 0, 0) },
        .{ .position = Vec3.init(0, std.math.inf(f32), 0) },
        .{ .position = Vec3.init(0, 0, -std.math.inf(f32)) },
        .{ .rotation = .{ .x = 0, .y = 0, .z = 0, .w = 0 } },
        .{ .position = Vec3.init(1, 2, 3), .rotation = .{ .x = std.math.nan(f32) } },
        .{ .rotation = .{ .y = std.math.inf(f32) } },
        .{ .rotation = .{ .z = -std.math.inf(f32) } },
        .{ .rotation = .{ .w = std.math.nan(f32) } },
    };
    for (bad_transforms) |transform| {
        try expectError(error.InvalidValue, system.create(.{ .world_id = 1, .transform = transform }));
        try expectError(error.InvalidValue, system.setTransform(id, transform));
        try std.testing.expectEqualDeep(before, try system.get(id));
    }
    for ([_]f32{ 0, -1, std.math.pi, 4, std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |fov| {
        try expectError(error.InvalidValue, system.create(.{ .world_id = 1, .vertical_fov = fov }));
        try expectError(error.InvalidValue, system.setFov(id, fov));
        try std.testing.expectEqualDeep(before, try system.get(id));
    }
    try expectEqual(@as(usize, 1), system.count());
    // Rejection must not consume a slot or disturb a reusable slot.
    try system.destroy(id);
    try expectError(error.InvalidValue, system.create(.{ .world_id = 1, .vertical_fov = 0 }));
    const next = try system.create(.{ .world_id = 1, .vertical_fov = 0.001 });
    try expectEqual(id.index, next.index);
    try system.setFov(next, 3.14);
    try expectEqual(@as(f32, 3.14), (try system.get(next)).vertical_fov);
}

test "snapshot uses -Z forward and remains independent of registry mutations" {
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const id = try system.create(.{ .world_id = 42, .transform = .{ .position = Vec3.init(1, 2, 3) } });
    const snapshot = try system.resolve(id);
    try expectVector(Vec3.init(0, 0, -1), snapshot.forward);
    try expectVector(Vec3.init(1, 0, 0), snapshot.right);
    try expectVector(Vec3.init(0, 1, 0), snapshot.up);
    try expectEqual(@as(f32, std.math.pi / 2.0), snapshot.vertical_fov);
    try system.setTransform(id, .{ .position = Vec3.init(4, 5, 6), .rotation = .{ .w = 2 } });
    try system.setFov(id, 1);
    const changed = try system.resolve(id);
    try expectVector(Vec3.init(4, 5, 6), changed.position);
    try expectEqual(@as(f32, 1), changed.rotation.w);
    try expectEqual(@as(f32, 1), changed.vertical_fov);
    try system.destroy(id);
    try expectEqual(id, snapshot.id);
    try expectEqual(@as(u32, 42), snapshot.world_id);
    try expectVector(Vec3.init(1, 2, 3), snapshot.position);
    try expectEqual(@as(f32, std.math.pi / 2.0), snapshot.vertical_fov);
}

test "full quaternion rotation preserves roll and a right-handed orthonormal basis" {
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    // A scaled quaternion for +90 degrees about Z: right becomes up.
    const id = try system.create(.{ .world_id = 1, .transform = .{ .rotation = .{ .z = 2, .w = 2 } } });
    const rolled = try system.resolve(id);
    try expectVector(Vec3.init(0, 0, -1), rolled.forward);
    try expectVector(Vec3.init(0, 1, 0), rolled.right);
    try expectVector(Vec3.init(-1, 0, 0), rolled.up);
    // +90 degrees about Y sends -Z to -X.
    try system.setTransform(id, .{ .rotation = .{ .y = 1, .w = 1 } });
    try expectVector(Vec3.init(-1, 0, 0), (try system.resolve(id)).forward);
    // +90 degrees about X sends -Z to +Y.
    try system.setTransform(id, .{ .rotation = .{ .x = 1, .w = 1 } });
    try expectVector(Vec3.init(0, 1, 0), (try system.resolve(id)).forward);
    try system.setTransform(id, .{ .rotation = .{ .x = 1, .y = 2, .z = 3, .w = 4 } });
    const mixed = try system.resolve(id);
    for ([_]Vec3{ mixed.forward, mixed.right, mixed.up }) |axis| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), axis.length(), 0.00001);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0), mixed.right.dot(mixed.up), 0.00001);
    try expectVector(mixed.forward.negate(), mixed.right.cross(mixed.up));
    try system.setTransform(id, .{ .rotation = .{ .x = -1, .y = -2, .z = -3, .w = -4 } });
    const equivalent = try system.resolve(id);
    try expectVector(mixed.forward, equivalent.forward);
    try expectVector(mixed.right, equivalent.right);
    try expectVector(mixed.up, equivalent.up);
}

test "quaternion normalization handles finite values across the f32 range" {
    for ([_]f32{ std.math.floatMax(f32), std.math.floatMin(f32), @bitCast(@as(u32, 1)) }) |scale| {
        const normalized = try (Quaternion{ .x = scale, .y = scale, .z = scale, .w = scale }).normalized();
        try std.testing.expectEqualDeep(Quaternion{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 0.5 }, normalized);
    }
}

test "allocation failure leaves existing cameras intact and registry reusable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var system = CameraSystem.init(failing.allocator());
    defer system.deinit();
    try expectError(error.OutOfMemory, system.create(.{ .world_id = 1 }));
    try expectEqual(@as(usize, 0), system.count());
    failing.fail_index = std.math.maxInt(usize);
    const first = try system.create(.{ .world_id = 1 });
    const original = try system.get(first);
    while (system.count() < system.slots.capacity) _ = try system.create(.{ .world_id = 2 });
    const count = system.count();
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try expectError(error.OutOfMemory, system.create(.{ .world_id = 3 }));
    try expectEqual(count, system.count());
    try std.testing.expectEqualDeep(original, try system.get(first));
    try system.destroy(first);
    const reused = try system.create(.{ .world_id = 4 });
    try expectEqual(first.index, reused.index);
    try expectEqual(count, system.count());
}

test "camera commands apply in the current frame and reply only on the owner's next pass" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    bus.beginFrame();
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 10, .reply_to = .UI, .info = .{ .world_id = 7 } } });
    try expectEqual(@as(usize, 0), system.count());
    try expectEqual(@as(usize, 1), try system.processCurrent(bus));
    try expectEqual(@as(usize, 1), system.count());
    try expect(bus.queues.UI.isEmpty());
    try expectEqual(@as(usize, 1), bus.queues.UI.getNextCount());
    bus.clearCurrent();
    bus.beginFrame();
    const created = (try bus.queues.UI.read()).camera_result;
    try expectEqual(camera.t.Operation.create, created.operation);
    try expectEqual(camera.t.Status.applied, created.status);
    try expectEqual(@as(u64, 10), created.request_id);
    const id = created.camera_id.?;
    try expectEqual(@as(u32, 7), (try system.get(id)).world_id);
    try bus.submitCurrent("camera", .{ .set_transform = .{
        .request_id = 11,
        .reply_to = .UI,
        .id = id,
        .transform = .{ .position = Vec3.init(4, 5, 6), .rotation = .{ .z = 1, .w = 1 } },
        .acknowledge = true,
    } });
    try bus.submitCurrent("camera", .{ .set_fov = .{ .request_id = 12, .reply_to = .UI, .id = id, .vertical_fov = 1, .acknowledge = true } });
    try expectEqual(@as(usize, 2), try system.processCurrent(bus));
    try expectVector(Vec3.init(4, 5, 6), (try system.resolve(id)).position);
    try expectVector(Vec3.init(0, 1, 0), (try system.resolve(id)).right);
    try expectEqual(@as(f32, 1), (try system.get(id)).vertical_fov);
    bus.beginFrame();
    const transformed = (try bus.queues.UI.read()).camera_result;
    const projection = (try bus.queues.UI.read()).camera_result;
    try expectEqual(@as(u64, 11), transformed.request_id);
    try expectEqual(camera.t.Operation.set_transform, transformed.operation);
    try expectEqual(camera.t.Status.applied, transformed.status);
    try expectEqual(@as(u64, 12), projection.request_id);
    try expectEqual(camera.t.Operation.set_fov, projection.operation);
    try expectEqual(camera.t.Status.applied, projection.status);
    try expectEqual(id, projection.camera_id.?);
}

test "deferred commands wait for frame promotion and results route to every supported owner" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    inline for (std.meta.fields(camera.t.ReplyTo), 0..) |owner, index| {
        _ = try bus.submit("camera", Command{ .create = .{
            .request_id = index,
            .reply_to = @enumFromInt(owner.value),
            .info = .{ .world_id = 1 },
        } });
    }
    try expectEqual(@as(usize, 0), try system.processCurrent(bus));
    bus.beginFrame();
    try expectEqual(@as(usize, 5), try system.processCurrent(bus));
    inline for (std.meta.fields(camera.t.ReplyTo)) |owner| {
        try expect(@field(bus.queues, owner.name).isEmpty());
        try expectEqual(@as(usize, 1), @field(bus.queues, owner.name).getNextCount());
    }
    bus.clearCurrent();
    bus.beginFrame();
    inline for (std.meta.fields(camera.t.ReplyTo), 0..) |owner, index| {
        const result = (try @field(bus.queues, owner.name).read()).camera_result;
        try expectEqual(@as(u64, index), result.request_id);
        try expectEqual(camera.t.Status.applied, result.status);
        try expectEqual(result.camera_id.?, (try system.get(result.camera_id.?)).id);
    }
    try expect(bus.queues.input.isEmpty());
    try expect(bus.queues.camera.isEmpty());
}

test "rejected lifecycle commands leave cameras intact and always report failures" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const id = try system.create(.{ .world_id = 1 });
    const before = try system.get(id);
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 1, .reply_to = .core, .info = .{ .world_id = 1, .vertical_fov = 0 } } });
    try bus.submitCurrent("camera", .{ .set_transform = .{ .request_id = 2, .reply_to = .core, .id = id, .transform = .{ .position = Vec3.init(9, 8, 7), .rotation = .{ .w = 0 } } } });
    try bus.submitCurrent("camera", .{ .set_fov = .{ .request_id = 3, .reply_to = .core, .id = id, .vertical_fov = std.math.nan(f32) } });
    _ = try system.processCurrent(bus);
    try expectEqual(@as(usize, 1), system.count());
    try std.testing.expectEqualDeep(before, try system.get(id));
    bus.beginFrame();
    for (1..4) |request| {
        const result = (try bus.queues.core.read()).camera_result;
        try expectEqual(@as(u64, request), result.request_id);
        try expectEqual(camera.t.Status.invalid_value, result.status);
        if (request == 1) try expectEqual(@as(?camera.CameraId, null), result.camera_id);
    }
    try bus.submitCurrent("camera", .{ .destroy = .{ .request_id = 4, .reply_to = .core, .id = id } });
    try bus.submitCurrent("camera", .{ .destroy = .{ .request_id = 5, .reply_to = .core, .id = id } });
    try bus.submitCurrent("camera", .{ .set_transform = .{ .request_id = 6, .reply_to = .core, .id = id, .transform = .{} } });
    try bus.submitCurrent("camera", .{ .set_fov = .{ .request_id = 7, .reply_to = .core, .id = id, .vertical_fov = 1 } });
    try expectEqual(@as(usize, 4), try system.processCurrent(bus));
    try expectEqual(@as(usize, 0), system.count());
    bus.beginFrame();
    for (4..8) |request| {
        const result = (try bus.queues.core.read()).camera_result;
        try expectEqual(@as(u64, request), result.request_id);
        try expectEqual(if (request == 4) camera.t.Status.applied else .invalid_handle, result.status);
        try expectEqual(id, result.camera_id.?);
    }
}

test "successful property updates can omit acknowledgments" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const id = try system.create(.{ .world_id = 1 });
    try bus.submitCurrent("camera", .{ .set_transform = .{ .request_id = 1, .reply_to = .UI, .id = id, .transform = .{ .position = Vec3.init(1, 2, 3) } } });
    try bus.submitCurrent("camera", .{ .set_fov = .{ .request_id = 2, .reply_to = .UI, .id = id, .vertical_fov = 1 } });
    _ = try system.processCurrent(bus);
    try expectEqual(@as(usize, 0), bus.queues.UI.getNextCount());
    try expectVector(Vec3.init(1, 2, 3), (try system.get(id)).transform.position);
    try expectEqual(@as(f32, 1), (try system.get(id)).vertical_fov);
}

test "a saturated reply queue retains results without reapplying commands or consuming later work" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const Queue = @TypeOf(bus.queues.core);
    for (0..Queue.Capacity) |_| {
        try bus.queues.core.next.write(.{ .Pause = {} });
        try bus.queues.core.debt.write(.{ .Pause = {} });
    }
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 1, .reply_to = .core, .info = .{ .world_id = 1 } } });
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 2, .reply_to = .core, .info = .{ .world_id = 2 } } });
    try expectError(error.Full, system.processCurrent(bus));
    try expectEqual(@as(usize, 1), system.count());
    try expectEqual(@as(usize, 1), bus.queues.camera.getCount());
    try expectError(error.Full, system.processCurrent(bus));
    try expectEqual(@as(usize, 1), system.count());
    // The owner catches up; retry only delivers the first result and applies
    // the second command. It must never allocate a duplicate first camera.
    bus.beginFrame();
    bus.queues.core.active.clear();
    bus.beginFrame();
    bus.queues.core.active.clear();
    try expectEqual(@as(usize, 1), try system.processCurrent(bus));
    try expectEqual(@as(usize, 2), system.count());
    bus.beginFrame();
    const first = (try bus.queues.core.read()).camera_result;
    const second = (try bus.queues.core.read()).camera_result;
    try expectEqual(@as(u64, 1), first.request_id);
    try expectEqual(@as(u64, 2), second.request_id);
    try expectEqual(@as(u32, 1), (try system.get(first.camera_id.?)).world_id);
    try expectEqual(@as(u32, 2), (try system.get(second.camera_id.?)).world_id);
    try expect(bus.queues.core.isEmpty());
}

test "camera allocation failures return a result and do not stop later commands" {
    const bus = try newBus();
    defer std.testing.allocator.destroy(bus);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var system = CameraSystem.init(failing.allocator());
    defer system.deinit();
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 1, .reply_to = .UI, .info = .{ .world_id = 1 } } });
    try bus.submitCurrent("camera", .{ .create = .{ .request_id = 2, .reply_to = .UI, .info = .{ .world_id = 1, .vertical_fov = 0 } } });
    try expectEqual(@as(usize, 2), try system.processCurrent(bus));
    try expectEqual(@as(usize, 0), system.count());
    bus.beginFrame();
    const first = (try bus.queues.UI.read()).camera_result;
    try expectEqual(camera.t.Status.out_of_memory, first.status);
    try expectEqual(@as(?camera.CameraId, null), first.camera_id);
    try expectEqual(camera.t.Status.invalid_value, (try bus.queues.UI.read()).camera_result.status);
}
