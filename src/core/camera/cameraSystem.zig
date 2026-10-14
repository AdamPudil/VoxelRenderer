const std = @import("std");
pub const t = @import("types.zig");
pub const Vec3 = t.Vec3;
pub const Quaternion = t.Quaternion;
pub const WorldId = t.WorldId;
pub const CameraId = t.CameraId;
pub const Transform = t.Transform;
pub const CreateInfo = t.CreateInfo;
pub const Camera = t.Camera;
pub const ResolvedCamera = t.ResolvedCamera;

/// Main-thread registry. Use the methods to mutate cameras so validation and
/// handle generations cannot be bypassed. Read APIs return copies.
pub const CameraSystem = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(Slot) = .{},
    free_head: ?u32 = null,
    live_count: usize = 0,
    pending_result: ?PendingResult = null,

    const PendingResult = struct { reply_to: t.ReplyTo, value: t.Result };

    const Slot = struct {
        generation: u32 = 1,
        camera: ?Camera = null,
        next_free: ?u32 = null,
    };

    pub fn init(allocator: std.mem.Allocator) CameraSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CameraSystem) void {
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn count(self: *const CameraSystem) usize {
        return self.live_count;
    }

    /// Main-thread owner pass, after bus.beginFrame(). Current commands apply
    /// now; results use deferred delivery to the requester's next pass.
    /// On Full, retry before retiring current queues: the applied command's
    /// result is retained and remaining commands have not been consumed.
    pub fn processCurrent(self: *CameraSystem, bus: anytype) !usize {
        try self.flushResult(bus);
        const Handler = struct {
            system: *CameraSystem,
            bus: @TypeOf(bus),

            pub fn handle(handler: *@This(), comptime name: []const u8, command: anytype) !void {
                if (comptime !std.mem.eql(u8, name, "camera")) @compileError("CameraSystem only owns the camera queue");
                handler.system.applyCommand(command);
                try handler.system.flushResult(handler.bus);
            }
        };
        var handler = Handler{ .system = self, .bus = bus };
        return bus.drainCurrent(.camera, "camera", &handler);
    }

    fn applyCommand(self: *CameraSystem, command: anytype) void {
        std.debug.assert(self.pending_result == null);
        switch (command) {
            inline else => |data, operation| {
                var result = t.Result{
                    .request_id = data.request_id,
                    .operation = @field(t.Operation, @tagName(operation)),
                    .status = .applied,
                    .camera_id = if (comptime operation == .create) null else data.id,
                };
                switch (operation) {
                    .create => {
                        if (self.create(data.info)) |id| {
                            result.camera_id = id;
                        } else |err| result.status = switch (err) {
                            error.InvalidValue => .invalid_value,
                            error.OutOfMemory => .out_of_memory,
                            error.CapacityExceeded => .capacity_exceeded,
                        };
                    },
                    .destroy => self.destroy(data.id) catch {
                        result.status = .invalid_handle;
                    },
                    .set_transform => self.setTransform(data.id, data.transform) catch |err| {
                        result.status = updateStatus(err);
                    },
                    .set_fov => self.setFov(data.id, data.vertical_fov) catch |err| {
                        result.status = updateStatus(err);
                    },
                }
                const acknowledge = if (comptime operation == .create or operation == .destroy) true else data.acknowledge;
                if (acknowledge or result.status != .applied) {
                    self.pending_result = .{ .reply_to = data.reply_to, .value = result };
                }
            },
        }
    }

    fn flushResult(self: *CameraSystem, bus: anytype) !void {
        const pending = self.pending_result orelse return;
        switch (pending.reply_to) {
            inline else => |owner| {
                const name = @tagName(owner);
                const Queue = @TypeOf(@field(bus.queues, name));
                if (Queue.Descriptor.onFull.action != .debt_queue)
                    @compileError("camera results require a lossless reply queue");
                _ = try bus.submit(name, Queue.Value{ .camera_result = pending.value });
            },
        }
        self.pending_result = null;
    }

    pub fn create(self: *CameraSystem, info: CreateInfo) !CameraId {
        const transform = try info.transform.validated();
        try validateFov(info.vertical_fov);

        const index = if (self.free_head) |free| free else blk: {
            if (self.slots.items.len >= std.math.maxInt(u32)) return error.CapacityExceeded;
            const next: u32 = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{});
            break :blk next;
        };
        const slot = &self.slots.items[index];
        self.free_head = slot.next_free;
        slot.next_free = null;
        const id = CameraId{ .index = index, .generation = slot.generation };
        slot.camera = .{
            .id = id,
            .world_id = info.world_id,
            .transform = transform,
            .vertical_fov = info.vertical_fov,
        };
        self.live_count += 1;
        return id;
    }

    /// View-reference protection will be added with render-view ownership.
    pub fn destroy(self: *CameraSystem, id: CameraId) error{InvalidHandle}!void {
        _ = try self.get(id);
        const slot = &self.slots.items[id.index];
        slot.camera = null;
        self.live_count -= 1;
        // Retire exhausted slots instead of wrapping and reviving stale IDs.
        if (slot.generation < std.math.maxInt(u32)) {
            slot.generation += 1;
            slot.next_free = self.free_head;
            self.free_head = id.index;
        }
    }

    pub fn get(self: *const CameraSystem, id: CameraId) error{InvalidHandle}!Camera {
        if (id.index >= self.slots.items.len) return error.InvalidHandle;
        const slot = &self.slots.items[id.index];
        if (id.generation != slot.generation) return error.InvalidHandle;
        return slot.camera orelse error.InvalidHandle;
    }

    pub fn setTransform(self: *CameraSystem, id: CameraId, transform: Transform) !void {
        _ = try self.get(id);
        const validated = try transform.validated();
        self.slots.items[id.index].camera.?.transform = validated;
    }

    pub fn setFov(self: *CameraSystem, id: CameraId, vertical_fov: f32) !void {
        _ = try self.get(id);
        try validateFov(vertical_fov);
        self.slots.items[id.index].camera.?.vertical_fov = vertical_fov;
    }

    /// Y-up, camera-local forward -Z, right +X, up +Y.
    pub fn resolve(self: *const CameraSystem, id: CameraId) error{InvalidHandle}!ResolvedCamera {
        const camera = try self.get(id);
        const rotation = camera.transform.rotation;
        return .{
            .id = id,
            .world_id = camera.world_id,
            .position = camera.transform.position,
            .rotation = rotation,
            .vertical_fov = camera.vertical_fov,
            .forward = rotation.rotate(Vec3.init(0, 0, -1)),
            .right = rotation.rotate(Vec3.init(1, 0, 0)),
            .up = rotation.rotate(Vec3.init(0, 1, 0)),
        };
    }
};

fn updateStatus(err: error{ InvalidHandle, InvalidValue }) t.Status {
    return switch (err) {
        error.InvalidHandle => .invalid_handle,
        error.InvalidValue => .invalid_value,
    };
}

fn validateFov(vertical_fov: f32) error{InvalidValue}!void {
    if (!std.math.isFinite(vertical_fov) or vertical_fov <= 0 or vertical_fov >= @as(f32, std.math.pi))
        return error.InvalidValue;
}

test "exhausted generations retire a slot without reviving stale handles" {
    var system = CameraSystem.init(std.testing.allocator);
    defer system.deinit();
    const original = try system.create(.{ .world_id = 1 });
    // Exercise exhaustion without billions of allocations.
    system.slots.items[original.index].generation = std.math.maxInt(u32);
    const last = CameraId{ .index = original.index, .generation = std.math.maxInt(u32) };
    system.slots.items[last.index].camera.?.id = last;
    try system.destroy(last);
    const replacement = try system.create(.{ .world_id = 1 });
    try std.testing.expect(replacement.index != original.index);
    try std.testing.expectError(error.InvalidHandle, system.get(original));
    try std.testing.expectError(error.InvalidHandle, system.get(last));
}
