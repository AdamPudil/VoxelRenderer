const std = @import("std");

fn requireNumber(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float => {},
        else => @compileError("Vector component type must be an integer or floating-point type"),
    }
}

fn requireFloat(comptime T: type) void {
    switch (@typeInfo(T)) {
        .float => {},
        else => @compileError("This vector operation requires a floating-point component type"),
    }
}

fn divScalar(comptime T: type, a: T, b: T) T {
    return switch (@typeInfo(T)) {
        .float => a / b,
        .int => @divTrunc(a, b),
        else => unreachable,
    };
}

fn approxScalar(comptime T: type, a: T, b: T, epsilon: T) bool {
    requireFloat(T);
    return @abs(a - b) <= epsilon;
}

pub fn Vec2(comptime T: type) type {
    requireNumber(T);

    return struct {
        const Self = @This();

        x: T,
        y: T,

        pub const Component = T;
        pub const dimensions: usize = 2;

        pub fn init(x: T, y: T) Self {
            return .{ .x = x, .y = y };
        }

        pub fn zero() Self {
            return splat(0);
        }

        pub fn one() Self {
            return splat(1);
        }

        pub fn splat(value: T) Self {
            return .{ .x = value, .y = value };
        }

        pub fn fromArray(values: [2]T) Self {
            return .{ .x = values[0], .y = values[1] };
        }

        pub fn toArray(self: Self) [2]T {
            return .{ self.x, self.y };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .x = a.x + b.x, .y = a.y + b.y };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .x = a.x - b.x, .y = a.y - b.y };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{ .x = a.x * b.x, .y = a.y * b.y };
        }

        pub fn div(a: Self, b: Self) Self {
            return .{
                .x = divScalar(T, a.x, b.x),
                .y = divScalar(T, a.y, b.y),
            };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .x = self.x * scalar, .y = self.y * scalar };
        }

        pub fn divScale(self: Self, scalar: T) Self {
            return .{
                .x = divScalar(T, self.x, scalar),
                .y = divScalar(T, self.y, scalar),
            };
        }

        pub fn negate(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.x == b.x and a.y == b.y;
        }

        pub fn approxEql(a: Self, b: Self, epsilon: T) bool {
            return approxScalar(T, a.x, b.x, epsilon) and
                approxScalar(T, a.y, b.y, epsilon);
        }

        pub fn min(a: Self, b: Self) Self {
            return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y) };
        }

        pub fn max(a: Self, b: Self) Self {
            return .{ .x = @max(a.x, b.x), .y = @max(a.y, b.y) };
        }

        pub fn clamp(self: Self, lower: Self, upper: Self) Self {
            return max(lower, min(self, upper));
        }

        pub fn abs(self: Self) Self {
            return .{ .x = @abs(self.x), .y = @abs(self.y) };
        }

        pub fn sign(self: Self) Self {
            return .{
                .x = if (self.x > 0) 1 else if (self.x < 0) -1 else 0,
                .y = if (self.y > 0) 1 else if (self.y < 0) -1 else 0,
            };
        }

        pub fn dot(a: Self, b: Self) T {
            return a.x * b.x + a.y * b.y;
        }

        /// 2D cross product represented as its scalar Z component.
        pub fn cross(a: Self, b: Self) T {
            return a.x * b.y - a.y * b.x;
        }

        pub fn lengthSquared(self: Self) T {
            return dot(self, self);
        }

        pub fn length(self: Self) T {
            requireFloat(T);
            return @sqrt(self.lengthSquared());
        }

        pub fn normalized(self: Self) Self {
            requireFloat(T);
            const len = self.length();
            return if (len == 0) zero() else self.divScale(len);
        }

        pub fn distanceSquared(a: Self, b: Self) T {
            return sub(a, b).lengthSquared();
        }

        pub fn distance(a: Self, b: Self) T {
            requireFloat(T);
            return sub(a, b).length();
        }

        pub fn floor(self: Self) Self {
            requireFloat(T);
            return .{ .x = @floor(self.x), .y = @floor(self.y) };
        }

        pub fn ceil(self: Self) Self {
            requireFloat(T);
            return .{ .x = @ceil(self.x), .y = @ceil(self.y) };
        }

        pub fn round(self: Self) Self {
            requireFloat(T);
            return .{ .x = @round(self.x), .y = @round(self.y) };
        }

        pub fn trunc(self: Self) Self {
            requireFloat(T);
            return .{ .x = @trunc(self.x), .y = @trunc(self.y) };
        }

        /// Fractional part in [0, 1), including for negative coordinates.
        pub fn fract(self: Self) Self {
            requireFloat(T);
            return self.sub(self.floor());
        }

        pub fn lerp(a: Self, b: Self, t: T) Self {
            requireFloat(T);
            return a.add(b.sub(a).scale(t));
        }

        pub fn perpendicular(self: Self) Self {
            return .{ .x = -self.y, .y = self.x };
        }

        pub fn rotated(self: Self, angle_radians: T) Self {
            requireFloat(T);
            const c = @cos(angle_radians);
            const s = @sin(angle_radians);
            return .{
                .x = self.x * c - self.y * s,
                .y = self.x * s + self.y * c,
            };
        }

        pub fn reflect(self: Self, normal: Self) Self {
            requireFloat(T);
            return self.sub(normal.scale(2 * self.dot(normal)));
        }
    };
}

pub fn Vec3(comptime T: type) type {
    requireNumber(T);

    return struct {
        const Self = @This();

        x: T,
        y: T,
        z: T,

        pub const Component = T;
        pub const dimensions: usize = 3;

        pub fn init(x: T, y: T, z: T) Self {
            return .{ .x = x, .y = y, .z = z };
        }

        pub fn zero() Self {
            return splat(0);
        }

        pub fn one() Self {
            return splat(1);
        }

        pub fn splat(value: T) Self {
            return .{ .x = value, .y = value, .z = value };
        }

        pub fn fromArray(values: [3]T) Self {
            return .{ .x = values[0], .y = values[1], .z = values[2] };
        }

        pub fn toArray(self: Self) [3]T {
            return .{ self.x, self.y, self.z };
        }

        pub fn xy(self: Self) Vec2(T) {
            return .{ .x = self.x, .y = self.y };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
        }

        pub fn div(a: Self, b: Self) Self {
            return .{
                .x = divScalar(T, a.x, b.x),
                .y = divScalar(T, a.y, b.y),
                .z = divScalar(T, a.z, b.z),
            };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{ .x = self.x * scalar, .y = self.y * scalar, .z = self.z * scalar };
        }

        pub fn divScale(self: Self, scalar: T) Self {
            return .{
                .x = divScalar(T, self.x, scalar),
                .y = divScalar(T, self.y, scalar),
                .z = divScalar(T, self.z, scalar),
            };
        }

        pub fn negate(self: Self) Self {
            return .{ .x = -self.x, .y = -self.y, .z = -self.z };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.x == b.x and a.y == b.y and a.z == b.z;
        }

        pub fn approxEql(a: Self, b: Self, epsilon: T) bool {
            return approxScalar(T, a.x, b.x, epsilon) and
                approxScalar(T, a.y, b.y, epsilon) and
                approxScalar(T, a.z, b.z, epsilon);
        }

        pub fn min(a: Self, b: Self) Self {
            return .{
                .x = @min(a.x, b.x),
                .y = @min(a.y, b.y),
                .z = @min(a.z, b.z),
            };
        }

        pub fn max(a: Self, b: Self) Self {
            return .{
                .x = @max(a.x, b.x),
                .y = @max(a.y, b.y),
                .z = @max(a.z, b.z),
            };
        }

        pub fn clamp(self: Self, lower: Self, upper: Self) Self {
            return max(lower, min(self, upper));
        }

        pub fn abs(self: Self) Self {
            return .{ .x = @abs(self.x), .y = @abs(self.y), .z = @abs(self.z) };
        }

        pub fn dot(a: Self, b: Self) T {
            return a.x * b.x + a.y * b.y + a.z * b.z;
        }

        pub fn cross(a: Self, b: Self) Self {
            return .{
                .x = a.y * b.z - a.z * b.y,
                .y = a.z * b.x - a.x * b.z,
                .z = a.x * b.y - a.y * b.x,
            };
        }

        pub fn lengthSquared(self: Self) T {
            return dot(self, self);
        }

        pub fn length(self: Self) T {
            requireFloat(T);
            return @sqrt(self.lengthSquared());
        }

        pub fn normalized(self: Self) Self {
            requireFloat(T);
            const len = self.length();
            return if (len == 0) zero() else self.divScale(len);
        }

        pub fn distanceSquared(a: Self, b: Self) T {
            return sub(a, b).lengthSquared();
        }

        pub fn distance(a: Self, b: Self) T {
            requireFloat(T);
            return sub(a, b).length();
        }

        pub fn floor(self: Self) Self {
            requireFloat(T);
            return .{ .x = @floor(self.x), .y = @floor(self.y), .z = @floor(self.z) };
        }

        pub fn ceil(self: Self) Self {
            requireFloat(T);
            return .{ .x = @ceil(self.x), .y = @ceil(self.y), .z = @ceil(self.z) };
        }

        pub fn round(self: Self) Self {
            requireFloat(T);
            return .{ .x = @round(self.x), .y = @round(self.y), .z = @round(self.z) };
        }

        pub fn trunc(self: Self) Self {
            requireFloat(T);
            return .{ .x = @trunc(self.x), .y = @trunc(self.y), .z = @trunc(self.z) };
        }

        /// Fractional part in [0, 1), useful for voxel/cell coordinates.
        pub fn fract(self: Self) Self {
            requireFloat(T);
            return self.sub(self.floor());
        }

        pub fn lerp(a: Self, b: Self, t: T) Self {
            requireFloat(T);
            return a.add(b.sub(a).scale(t));
        }

        pub fn reflect(self: Self, normal: Self) Self {
            requireFloat(T);
            return self.sub(normal.scale(2 * self.dot(normal)));
        }

        /// Refraction using the GLSL-style formula.
        pub fn refract(self: Self, normal: Self, eta: T) Self {
            requireFloat(T);
            const d = self.dot(normal);
            const k = 1 - eta * eta * (1 - d * d);
            return if (k < 0)
                zero()
            else
                self.scale(eta).sub(normal.scale(eta * d + @sqrt(k)));
        }
    };
}

pub fn Vec4(comptime T: type) type {
    requireNumber(T);

    return struct {
        const Self = @This();

        x: T,
        y: T,
        z: T,
        w: T,

        pub const Component = T;
        pub const dimensions: usize = 4;

        pub fn init(x: T, y: T, z: T, w: T) Self {
            return .{ .x = x, .y = y, .z = z, .w = w };
        }

        pub fn zero() Self {
            return splat(0);
        }

        pub fn one() Self {
            return splat(1);
        }

        pub fn splat(value: T) Self {
            return .{ .x = value, .y = value, .z = value, .w = value };
        }

        pub fn xyz(self: Self) Vec3(T) {
            return .{ .x = self.x, .y = self.y, .z = self.z };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{
                .x = a.x + b.x,
                .y = a.y + b.y,
                .z = a.z + b.z,
                .w = a.w + b.w,
            };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{
                .x = a.x - b.x,
                .y = a.y - b.y,
                .z = a.z - b.z,
                .w = a.w - b.w,
            };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{
                .x = a.x * b.x,
                .y = a.y * b.y,
                .z = a.z * b.z,
                .w = a.w * b.w,
            };
        }

        pub fn div(a: Self, b: Self) Self {
            return .{
                .x = divScalar(T, a.x, b.x),
                .y = divScalar(T, a.y, b.y),
                .z = divScalar(T, a.z, b.z),
                .w = divScalar(T, a.w, b.w),
            };
        }

        pub fn scale(self: Self, scalar: T) Self {
            return .{
                .x = self.x * scalar,
                .y = self.y * scalar,
                .z = self.z * scalar,
                .w = self.w * scalar,
            };
        }

        pub fn divScale(self: Self, scalar: T) Self {
            return .{
                .x = divScalar(T, self.x, scalar),
                .y = divScalar(T, self.y, scalar),
                .z = divScalar(T, self.z, scalar),
                .w = divScalar(T, self.w, scalar),
            };
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w;
        }

        pub fn dot(a: Self, b: Self) T {
            return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
        }

        pub fn lengthSquared(self: Self) T {
            return dot(self, self);
        }

        pub fn length(self: Self) T {
            requireFloat(T);
            return @sqrt(self.lengthSquared());
        }

        pub fn normalized(self: Self) Self {
            requireFloat(T);
            const len = self.length();
            return if (len == 0) zero() else self.divScale(len);
        }

        pub fn floor(self: Self) Self {
            requireFloat(T);
            return .{
                .x = @floor(self.x),
                .y = @floor(self.y),
                .z = @floor(self.z),
                .w = @floor(self.w),
            };
        }

        pub fn ceil(self: Self) Self {
            requireFloat(T);
            return .{
                .x = @ceil(self.x),
                .y = @ceil(self.y),
                .z = @ceil(self.z),
                .w = @ceil(self.w),
            };
        }

        pub fn fract(self: Self) Self {
            requireFloat(T);
            return self.sub(self.floor());
        }

        pub fn lerp(a: Self, b: Self, t: T) Self {
            requireFloat(T);
            return a.add(b.sub(a).scale(t));
        }
    };
}

// Convenient aliases.
pub const Vec2i32 = Vec2(i32);
pub const Vec2i64 = Vec2(i64);
pub const Vec2f32 = Vec2(f32);
pub const Vec2f64 = Vec2(f64);

pub const Vec3i32 = Vec3(i32);
pub const Vec3i64 = Vec3(i64);
pub const Vec3f32 = Vec3(f32);
pub const Vec3f64 = Vec3(f64);

pub const Vec4i32 = Vec4(i32);
pub const Vec4i64 = Vec4(i64);
pub const Vec4f32 = Vec4(f32);
pub const Vec4f64 = Vec4(f64);

test "Vec2 integer arithmetic" {
    const a = Vec2i32.init(4, 8);
    const b = Vec2i32.init(2, 3);

    try std.testing.expect(a.add(b).eql(.{ .x = 6, .y = 11 }));
    try std.testing.expect(a.sub(b).eql(.{ .x = 2, .y = 5 }));
    try std.testing.expect(a.mul(b).eql(.{ .x = 8, .y = 24 }));
    try std.testing.expect(a.div(b).eql(.{ .x = 2, .y = 2 }));
}

test "Vec3 floating-point operations" {
    const v = Vec3f32.init(3, 4, 0);
    const n = v.normalized();

    try std.testing.expectApproxEqAbs(@as(f32, 1), n.length(), 0.0001);
    try std.testing.expect(v.floor().eql(v));
    try std.testing.expect(Vec3f32.init(-1.25, 2.75, 3.5).fract().approxEql(
        Vec3f32.init(0.75, 0.75, 0.5),
        0.0001,
    ));
}

test "Vec3 cross product" {
    const x = Vec3i32.init(1, 0, 0);
    const y = Vec3i32.init(0, 1, 0);

    try std.testing.expect(x.cross(y).eql(Vec3i32.init(0, 0, 1)));
}
