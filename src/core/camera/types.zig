const std = @import("std");
pub const Vec3 = @import("../math/vector.zig").Vec3f32;
pub const Quaternion = @import("../math/quaternion.zig").Quaternion;

/// Matches the existing world event identifier. World ownership is external.
pub const WorldId = u32;

/// Handles are scoped to the CameraSystem that allocated them.
pub const CameraId = struct {
    index: u32,
    generation: u32,
};

pub const Transform = struct {
    position: Vec3 = Vec3.zero(),
    rotation: Quaternion = .identity,

    pub fn validated(self: Transform) error{InvalidValue}!Transform {
        for (self.position.toArray()) |component| {
            if (!std.math.isFinite(component)) return error.InvalidValue;
        }
        return .{ .position = self.position, .rotation = try self.rotation.normalized() };
    }
};

/// Standalone world-space cameras; parent attachment is a later increment.
pub const CreateInfo = struct {
    world_id: WorldId,
    transform: Transform = .{},
    vertical_fov: f32 = std.math.pi / 2.0,
};

pub const Camera = struct {
    id: CameraId,
    world_id: WorldId,
    transform: Transform,
    vertical_fov: f32,
};

/// Owned frame data with no pointers into the registry. Resolution belongs to
/// the future render view. Basis vectors include the camera's full roll.
pub const ResolvedCamera = struct {
    id: CameraId,
    world_id: WorldId,
    position: Vec3,
    rotation: Quaternion,
    vertical_fov: f32,
    forward: Vec3,
    right: Vec3,
    up: Vec3,
};

/// Only these owner queues register camera_result. No callbacks or broadcast.
pub const ReplyTo = enum { core, UI, entity, world, render };
pub const Operation = enum { create, destroy, set_transform, set_fov };
pub const Status = enum { applied, invalid_handle, invalid_value, out_of_memory, capacity_exceeded };

pub const Result = struct {
    request_id: u64,
    operation: Operation,
    status: Status,
    /// Allocated handle on successful create; target handle for other commands.
    camera_id: ?CameraId = null,
};

pub const Create = struct {
    request_id: u64,
    reply_to: ReplyTo,
    info: CreateInfo,
};

pub const Destroy = struct {
    request_id: u64,
    reply_to: ReplyTo,
    id: CameraId,
};

pub const SetTransform = struct {
    request_id: u64,
    reply_to: ReplyTo,
    id: CameraId,
    transform: Transform,
    /// Failures always reply, even when successful updates are silent.
    acknowledge: bool = false,
};

pub const SetFov = struct {
    request_id: u64,
    reply_to: ReplyTo,
    id: CameraId,
    vertical_fov: f32,
    acknowledge: bool = false,
};
