//! Bounded CPU light selection. All scene descriptors remain editable without
//! shader recompilation. Uniform arrays avoid requiring SSBOs on the GL 4.2 path.
const std = @import("std");
const settings = @import("../lighting.zig");
const Light = settings.PointLight;
const gl = @import("gl.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});

pub const Selection = struct {
    lights: [settings.max_lights]Light = undefined,
    count: usize = 0,

    pub fn select(scene: []const Light, blocks: []const Light, eye: [3]f32) Selection {
        var result = Selection{};
        var scores = [_]f32{std.math.inf(f32)} ** settings.max_lights;
        for ([_][]const Light{ scene, blocks }) |list| for (list) |light| {
            if (light.radius <= 0 or light.intensity <= 0) continue;
            var distance2: f32 = 0;
            for (0..3) |axis| distance2 += (light.position[axis] - eye[axis]) * (light.position[axis] - eye[axis]);
            // Radius-normalized distance keeps the broad above-spawn light
            // relevant alongside small local lamps. Stable insertion breaks ties.
            const score = distance2 / (light.radius * light.radius);
            var index: usize = 0;
            while (index < settings.max_lights and scores[index] <= score) : (index += 1) {}
            if (index == settings.max_lights) continue;
            var j = @min(result.count, settings.max_lights - 1);
            while (j > index) : (j -= 1) {
                result.lights[j] = result.lights[j - 1];
                scores[j] = scores[j - 1];
            }
            result.lights[index] = light;
            scores[index] = score;
            result.count = @min(result.count + 1, settings.max_lights);
        };
        return result;
    }
};

pub const Uniforms = struct {
    count_loc: c_int = -1,
    positions_loc: c_int = -1,
    colors_loc: c_int = -1,
    previous: Selection = .{},
    uploaded: bool = false,
    revision: u64 = 0,

    pub fn init(program: c_uint) Uniforms {
        if (!settings.LightingFeatures.point_lights) return .{};
        return .{ .count_loc = gl.getUniformLocation(program, "uLightCount"), .positions_loc = gl.getUniformLocation(program, "uLightPositionRadius[0]"), .colors_loc = gl.getUniformLocation(program, "uLightColorIntensity[0]") };
    }

    pub fn upload(self: *Uniforms, scene: []const Light, blocks: []const Light, eye: [3]f32) void {
        if (!settings.LightingFeatures.point_lights or self.count_loc < 0) return;
        const selected = Selection.select(scene, blocks, eye);
        if (self.uploaded and sameLights(selected, self.previous)) return;
        var positions: [settings.max_lights][4]f32 = undefined;
        var colors: [settings.max_lights][4]f32 = undefined;
        for (selected.lights[0..selected.count], 0..) |light, i| {
            positions[i] = light.position ++ .{light.radius};
            colors[i] = light.color ++ .{light.intensity};
        }
        gl.uniform1i(self.count_loc, @intCast(selected.count));
        if (selected.count > 0) {
            c.__glewUniform4fv.?(self.positions_loc, @intCast(selected.count), @ptrCast(&positions));
            c.__glewUniform4fv.?(self.colors_loc, @intCast(selected.count), @ptrCast(&colors));
        }
        self.previous = selected;
        self.uploaded = true;
        self.revision +%= 1;
    }
};

test "selection is bounded, stable and retains broad lights" {
    var lamps: [20]Light = undefined;
    for (&lamps, 0..) |*lamp, i| lamp.* = .{ .position = .{ @floatFromInt(i * 32), 0, 0 }, .radius = 64 };
    const sun = Light{ .position = .{ 0, 256, 0 }, .radius = 2048 };
    const selection = Selection.select(&.{sun}, &lamps, .{ 0, 0, 0 });
    try std.testing.expectEqual(@as(usize, settings.max_lights), selection.count);
    try std.testing.expectEqual(sun.radius, selection.lights[1].radius);
    try std.testing.expectEqual(@as(usize, 0), Selection.select(&.{}, &.{}, .{ 0, 0, 0 }).count);
}

// Camera movement can reorder the same selection. That does not change lighting,
// so retain the uploaded order and cache rather than invalidating on every step.
fn sameLights(a: Selection, b: Selection) bool {
    if (a.count != b.count) return false;
    var matched = [_]bool{false} ** settings.max_lights;
    for (a.lights[0..a.count]) |light| {
        var found = false;
        for (b.lights[0..b.count], 0..) |other, i| {
            if (!matched[i] and std.meta.eql(light, other)) {
                matched[i] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

test "light revisions ignore selection order but retain all descriptor changes" {
    const red = Light{ .color = .{ 1, 0, 0 } };
    const blue = Light{ .color = .{ 0, 0, 1 } };
    var a = Selection{ .count = 2 };
    var b = Selection{ .count = 2 };
    a.lights[0] = red;
    a.lights[1] = blue;
    b.lights[0] = blue;
    b.lights[1] = red;
    try std.testing.expect(sameLights(a, b));
    b.lights[1].intensity += 1;
    try std.testing.expect(!sameLights(a, b));
    b.lights[1] = blue;
    try std.testing.expect(!sameLights(a, b));
}
