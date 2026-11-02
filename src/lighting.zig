//! Lighting settings are in world voxel units (16 voxels per block).
const std = @import("std");

pub const Mode = enum { legacy, direct, global_illumination };
pub const mode: Mode = .direct;
pub const gi_normal_probes = true;
pub const gi_indirect = true;
pub const gi_samples = 64; // power of two: bit reversal is an exact permutation
pub const gi_max_batch = 8;
pub const gi_ray_budget = 8192;
pub const gi_queue_capacity = 4096;
pub const gi_max_jobs = 256;
pub const gi_max_distance: f32 = 512;
pub const gi_max_radiance: f32 = 64; // finite HDR guard before display encoding
pub const gi_retention_frames = 120;
pub const gi_maintenance_slots = 1024;
pub const point_attenuation: f32 = 16;

pub fn applicationFeatures() Features {
    if (mode == .legacy) return .{ .point_lights = false, .sky_lighting = false };
    if (mode == .direct) return .{ .mode = .direct, .face_shading = false, .normal_probes = false, .indirect = false };
    return .{ .mode = mode, .normal_probes = gi_normal_probes, .indirect = gi_indirect };
}

pub fn hemisphereIndex(index: u32) u32 {
    comptime std.debug.assert(std.math.isPowerOfTwo(gi_samples) and gi_samples > 1);
    const shift: u5 = @intCast(32 - @as(u32, std.math.log2_int(u32, gi_samples)));
    return @bitReverse(index) >> shift;
}

pub const LightingFeatures = struct {
    pub const face_shading = true;
    pub const point_lights = true;
    pub const sky_lighting = true;
};
// Lighting always samples the center of each finest-voxel face. Disabling
// caching changes reuse only in the older direct-lighting variants. GI always
// uses its queued cache: 2^18 entries use 22 MiB (9 MiB for the older cache).
pub const face_cache = true;
pub const face_cache_entries = 1 << 18;
pub const Features = struct {
    mode: Mode = .legacy, // explicit reference/test variants retain their old behavior
    normal_probes: bool = true,
    indirect: bool = true,
    diagnostics: bool = false, // per-pixel cache counters are opt-in
    face_cache: bool = face_cache,
    face_shading: bool = LightingFeatures.face_shading,
    point_lights: bool = LightingFeatures.point_lights,
    sky_lighting: bool = LightingFeatures.sky_lighting,
};
pub const max_lights = 8; // CPU selects this many nearby lights; no global GPU scan.
pub const sky_extra_ray_count = 8; // 0 = vertical only; 4 = fast; 8–16 = quality.
pub const sky_color = [3]f32{ 0.6, 0.75, 1.0 };
pub const sky_intensity: f32 = 0.65;
pub const sky_first_ring_degrees: f32 = 10;
pub const sky_ring_step_degrees: f32 = 5;
pub const sky_ring_rotation_degrees: f32 = 22.5; // alternate rings interleave
pub const sky_max_ring_degrees: f32 = 85; // keep all rays above the horizon

pub const SkySample = struct { direction: [3]f32, weight: f32 };

/// Prefix-stable rings: N/E/S/W, then NE/SE/SW/NW; eight rays per ring.
/// World north is -Z and east is +X. Tilt reduces contribution by cos(tilt).
pub fn skySample(index: u32) SkySample {
    const ring = index / 8;
    const slot = index % 8;
    const tilt = @min(sky_max_ring_degrees, sky_first_ring_degrees + @as(f32, @floatFromInt(ring)) * sky_ring_step_degrees) * std.math.pi / 180;
    const azimuth = (@as(f32, @floatFromInt(slot % 4)) * 90 +
        (if (slot >= 4) @as(f32, 45) else 0) +
        (if (ring % 2 == 1) sky_ring_rotation_degrees else 0)) * std.math.pi / 180;
    var direction = [3]f32{ @sin(azimuth) * @sin(tilt), @cos(tilt), -@cos(azimuth) * @sin(tilt) };
    // Cardinal rays must be axis-aligned, not tiny trigonometric residuals.
    for (&direction) |*component| if (@abs(component.*) < 1e-6) {
        component.* = 0;
    };
    return .{ .direction = direction, .weight = @cos(tilt) };
}
pub const sky_max_distance: f32 = 4096;
pub const shadow_epsilon: f32 = 0.002; // fraction of one finest voxel, not a block
pub const shadow_steps = 2048; // conservative occlusion if exhausted
pub const background = [3]f32{ 0.4, 0.1, 0.1 };
pub const sun_height: f32 = 256;
// Blue sky + warm sun approach neutral white on ground beneath the spawn sun.
// Keep the sum below clipping so neutrality is not just saturated RGB channels.
pub const sun_color = [3]f32{ 1.0, 0.825, 0.535 };
pub const sun_intensity: f32 = 0.75;
pub const sun_radius: f32 = 2048;

/// Two vec4s, uploaded as uniform arrays on both GL 4.2 and 4.6. Scene data,
/// independent of shader specialization; future light types can use other arrays.
pub const PointLight = extern struct {
    position: [3]f32 = .{ 7.5, 7.5, 7.5 }, // center of lamp emitter; block-local until collected by World
    radius: f32 = 128,
    color: [3]f32 = .{ 0.25, 0.8, 1.0 }, // linear RGB
    intensity: f32 = 3,
};

pub fn specialize(a: std.mem.Allocator, source: []const u8, features: Features, extra_rays: u32) ![]u8 {
    if (!std.mem.startsWith(u8, source, "#version ")) return error.MissingShaderVersion;
    const line = (std.mem.indexOfScalar(u8, source, '\n') orelse return error.MissingShaderVersion) + 1;
    const preamble = try std.fmt.allocPrint(a, "{s}#define USE_FACE_SHADING {d}\n#define USE_POINT_LIGHTS {d}\n#define USE_SKY_LIGHTING {d}\n" ++
        "#define USE_LIGHTING_CACHE {d}\n#define LIGHTING_CACHE_SIZE {d}\n" ++
        "#define MAX_POINT_LIGHTS {d}\n#define SKY_EXTRA_RAYS {d}\n" ++
        "#define SKY_RGB vec3({d:.6}, {d:.6}, {d:.6})\n#define SKY_INTENSITY {d:.6}\n" ++
        "#define SKY_MAX_DISTANCE {d:.6}\n" ++
        "#define SHADOW_EPSILON {d:.6}\n#define SHADOW_STEPS {d}\n" ++
        "#define BACKGROUND_RGB vec3({d:.6}, {d:.6}, {d:.6})\n", .{ source[0..line], @intFromBool(features.face_shading), @intFromBool(features.point_lights), @intFromBool(features.sky_lighting), @intFromBool(features.face_cache and (features.point_lights or features.sky_lighting)), face_cache_entries, max_lights, extra_rays, sky_color[0], sky_color[1], sky_color[2], sky_intensity, sky_max_distance, shadow_epsilon, shadow_steps, background[0], background[1], background[2] });
    defer a.free(preamble);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice(preamble);
    const writer = out.writer();
    try writer.print("#define USE_GI {d}\n#define GI_NORMAL_PROBES {d}\n#define GI_INDIRECT {d}\n#define GI_DIAGNOSTICS {d}\n" ++
        "#define GI_SAMPLES {d}\n#define GI_SAMPLE_BITS {d}\n#define GI_MAX_BATCH {d}\n" ++
        "#define GI_QUEUE_CAPACITY {d}\n#define GI_MAX_JOBS {d}\n#define GI_MAX_DISTANCE {d:.6}\n#define GI_MAX_RADIANCE {d:.6}\n" ++
        "#define GI_RETENTION_FRAMES {d}u\n#define GI_MAINTENANCE_SLOTS {d}u\n#define POINT_ATTENUATION {d:.6}\n", .{
        @intFromBool(features.mode == .global_illumination), @intFromBool(features.normal_probes), @intFromBool(features.indirect), @intFromBool(features.diagnostics),
        gi_samples,                                          std.math.log2_int(u32, gi_samples),   gi_max_batch,                    gi_queue_capacity,
        gi_max_jobs,                                         gi_max_distance,                      gi_max_radiance,                 gi_retention_frames,
        gi_maintenance_slots,                                point_attenuation,
    });
    if (features.sky_lighting and extra_rays > 0) {
        try writer.writeAll("#if USE_SKY_LIGHTING && SKY_EXTRA_RAYS > 0\nconst vec4 SKY_SAMPLES[SKY_EXTRA_RAYS] = vec4[](\n");
        for (0..extra_rays) |i| {
            const sample = skySample(@intCast(i));
            try writer.print("vec4({d:.9}, {d:.9}, {d:.9}, {d:.9}){s}\n", .{ sample.direction[0], sample.direction[1], sample.direction[2], sample.weight, if (i + 1 < extra_rays) "," else "" });
        }
        try writer.writeAll(");\n#endif\n");
    }
    try writer.print("#line 2\n{s}", .{source[line..]});
    return out.toOwnedSlice();
}

test "GI bit reversal spans the full hemisphere budget without duplicate samples" {
    var seen = [_]bool{false} ** gi_samples;
    for (0..gi_samples) |i| {
        const index = hemisphereIndex(@intCast(i));
        try std.testing.expect(index < gi_samples and !seen[index]);
        seen[index] = true;
    }
    try std.testing.expectEqual(@as(u32, gi_samples / 2), hemisphereIndex(1));
    const src = try specialize(std.testing.allocator, "#version 420 core\nvoid main() {}\n", .{ .mode = .global_illumination }, 8);
    defer std.testing.allocator.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "#define USE_GI 1") != null);
}

test "variant preamble preserves version and accepts all independent combinations" {
    for (0..8) |mask| {
        const src = try specialize(std.testing.allocator, "#version 420 core\nvoid main() {}\n", .{ .face_shading = mask & 1 != 0, .point_lights = mask & 2 != 0, .sky_lighting = mask & 4 != 0 }, 0);
        defer std.testing.allocator.free(src);
        try std.testing.expect(std.mem.startsWith(u8, src, "#version 420 core\n#define"));
        try std.testing.expect(std.mem.indexOf(u8, src, "#define SKY_EXTRA_RAYS 0\n") != null);
    }
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(PointLight));
}

test "sky rings use cardinals then diagonals with interleaved wider rings" {
    const sin10 = @sin(@as(f32, 10) * std.math.pi / 180);
    const cos10 = @cos(@as(f32, 10) * std.math.pi / 180);
    const cardinal = [4][3]f32{ .{ 0, cos10, -sin10 }, .{ sin10, cos10, 0 }, .{ 0, cos10, sin10 }, .{ -sin10, cos10, 0 } };
    for (cardinal, 0..) |expected, i| {
        const sample = skySample(@intCast(i));
        for (0..3) |axis| try std.testing.expectApproxEqAbs(expected[axis], sample.direction[axis], 1e-6);
        try std.testing.expectApproxEqAbs(cos10, sample.weight, 1e-6);
    }
    for (4..8) |i| {
        const sample = skySample(@intCast(i));
        try std.testing.expectApproxEqAbs(@abs(sample.direction[0]), @abs(sample.direction[2]), 1e-6);
        try std.testing.expectApproxEqAbs(cos10, sample.direction[1], 1e-6);
    }
    const outer = skySample(8);
    try std.testing.expectApproxEqAbs(@cos(@as(f32, 15) * std.math.pi / 180), outer.direction[1], 1e-6);
    try std.testing.expect(outer.weight < skySample(0).weight);
    try std.testing.expect(outer.direction[0] > 0 and outer.direction[2] < 0);
    try std.testing.expectApproxEqAbs(@tan(@as(f32, 22.5) * std.math.pi / 180), outer.direction[0] / -outer.direction[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), skySample(16).direction[0]);
    for (0..128) |i| {
        const sample = skySample(@intCast(i));
        var length2: f32 = 0;
        for (sample.direction) |v| length2 += v * v;
        try std.testing.expectApproxEqAbs(@as(f32, 1), length2, 1e-6);
        try std.testing.expect(sample.direction[1] > 0 and sample.weight > 0);
    }
}
