//! Uploads independent LOD policies. Shader defaults (zero rings) are exact.
const std = @import("std");
const gl = @import("gl.zig");
const policy = @import("../rendering.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
});
pub const Uniforms = struct {
    reference: c_int,
    geometry_count: c_int,
    lighting_count: c_int,
    geometry: c_int,
    lighting: c_int,
    focus: c_int,
    guard: c_int,
    transition: c_int,
    interaction: c_int,
    focus_state: policy.FocusState = .{},

    pub fn init(program: c_uint) Uniforms {
        return .{
            .reference = gl.getUniformLocation(program, "uHierarchyReference"),
            .geometry_count = gl.getUniformLocation(program, "uGeometryRingCount"),
            .lighting_count = gl.getUniformLocation(program, "uLightingRingCount"),
            .geometry = gl.getUniformLocation(program, "uGeometryRings"),
            .lighting = gl.getUniformLocation(program, "uLightingRings"),
            .focus = gl.getUniformLocation(program, "uLodFocus"),
            .guard = gl.getUniformLocation(program, "uLodGuard"),
            .transition = gl.getUniformLocation(program, "uLodTransition"),
            .interaction = gl.getUniformLocation(program, "uInteractionRadius"),
        };
    }

    pub fn upload(self: *Uniforms, settings: policy.Settings, position: [3]f32) !void {
        const snapshot = try self.focus_state.resolve(settings, position);
        try self.uploadSnapshot(&snapshot);
    }

    pub fn uploadSnapshot(self: *Uniforms, snapshot: *const policy.Snapshot) !void {
        const settings = snapshot.settings();
        const focus = snapshot.focus;
        gl.uniform1i(self.reference, @intFromBool(!settings.exact_hierarchy));
        try gl.uniform3f(self.focus, focus[0], focus[1], focus[2]);
        c.__glewUniform1f.?(self.guard, settings.hysteresis_voxels);
        c.__glewUniform1f.?(self.transition, settings.transition_width_voxels);
        c.__glewUniform1f.?(self.interaction, settings.interaction_radius_voxels);
        uploadRings(self.geometry, self.geometry_count, settings.geometry_rings);
        uploadRings(self.lighting, self.lighting_count, settings.lighting_rings);
    }

    fn uploadRings(location: c_int, count: c_int, rings: []const policy.Ring) void {
        var values: [policy.max_rings][2]f32 = undefined;
        for (rings, 0..) |ring, i| values[i] = .{ ring.outer_radius_voxels, @floatFromInt(ring.cell_size_voxels) };
        c.__glewUniform2fv.?(location, @intCast(rings.len), &values[0][0]);
        gl.uniform1i(count, @intCast(rings.len));
    }
};
