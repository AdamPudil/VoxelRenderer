//! One layout choice shared by shader specialization and every world uploader.
const std = @import("std");
const c = @cImport({
    @cInclude("GL/glew.h");
});
pub const vector_headers = @import("build_options").vector_world_headers;

pub fn texelBytes(header: bool) usize {
    return if (header and vector_headers) 16 else 4;
}

pub fn format(header: bool) c_uint {
    return if (header and vector_headers) c.GL_RGBA32UI else c.GL_R32UI;
}

pub fn allocationBytes(bytes: usize, header: bool) usize {
    return @max(bytes, texelBytes(header));
}

pub fn validate(bytes: usize, header: bool, max_texels: usize) !void {
    const stride = texelBytes(header);
    if (bytes % stride != 0) return error.MisalignedWorldBuffer;
    if (allocationBytes(bytes, header) / stride > max_texels or bytes > std.math.maxInt(i32))
        return error.GeometryTextureLimit;
}

test "world texture limits count texels and include empty backing storage" {
    const stride = texelBytes(true);
    try validate(2 * stride, true, 2);
    try std.testing.expectError(error.GeometryTextureLimit, validate(3 * stride, true, 2));
    try std.testing.expectError(error.MisalignedWorldBuffer, validate(stride + 1, true, 2));
    try validate(0, true, 1);
    try std.testing.expectError(error.GeometryTextureLimit, validate(0, true, 0));
    try std.testing.expectEqual(stride, allocationBytes(0, true));
    try validate(8, false, 2);
    try std.testing.expectError(error.GeometryTextureLimit, validate(12, false, 2));
}
