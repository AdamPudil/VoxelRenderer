const std = @import("std");
const Vec3 = @import("vector.zig").Vec3f32;

/// Right-handed active rotation, stored as (x, y, z, w).
pub const Quaternion = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quaternion = .{};

    /// Accept every finite, nonzero quaternion, including very small/large ones.
    pub fn normalized(self: Quaternion) error{InvalidValue}!Quaternion {
        const components = [_]f32{ self.x, self.y, self.z, self.w };
        var length_squared: f64 = 0;
        for (components) |component| {
            if (!std.math.isFinite(component)) return error.InvalidValue;
            const wide: f64 = component;
            length_squared += wide * wide;
        }
        if (length_squared == 0) return error.InvalidValue;
        const length = @sqrt(length_squared);
        return .{
            .x = @floatCast(@as(f64, self.x) / length),
            .y = @floatCast(@as(f64, self.y) / length),
            .z = @floatCast(@as(f64, self.z) / length),
            .w = @floatCast(@as(f64, self.w) / length),
        };
    }

    /// Requires a normalized quaternion. Preserves the input vector's length.
    pub fn rotate(self: Quaternion, vector: Vec3) Vec3 {
        const imaginary = Vec3.init(self.x, self.y, self.z);
        const twice_cross = imaginary.cross(vector).scale(2);
        return vector.add(twice_cross.scale(self.w)).add(imaginary.cross(twice_cross));
    }
};
