const std = @import("std");
const gl = @import("gl.zig");
const World = @import("../world/world.zig").World;
const Registry = @import("../world/blockRegistry.zig").BlockRegistry;
const wc = @import("../world/worldConstants.zig");
const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
});

pub const icon_size = 64;
const render_size = icon_size * 2; // supersample fine voxel details
pub const Icons = struct {
    allocator: std.mem.Allocator,
    textures: []c_uint,

    pub fn deinit(self: *Icons) void {
        for (self.textures) |tex| c.glDeleteTextures(1, &tex);
        self.allocator.free(self.textures);
    }

    pub fn init(allocator: std.mem.Allocator, registry: *const Registry, program: c_uint) !Icons {
        const textures = try allocator.alloc(c_uint, registry.blocks.items.len);
        @memset(textures, 0);
        var self = Icons{ .allocator = allocator, .textures = textures };
        errdefer self.deinit();
        for (registry.blocks.items, 0..) |entry, i| {
            if (entry.generated_icon) try generate(allocator, &entry, program);
            const path = try allocator.dupeZ(u8, entry.icon_path);
            defer allocator.free(path);
            var width: c_int = 0;
            var height: c_int = 0;
            var channels: c_int = 0;
            const pixels = c.stbi_load(path, &width, &height, &channels, 4);
            if (pixels == null) {
                std.debug.print("Cannot load block icon: {s}\n", .{entry.icon_path});
                return error.InvalidBlockIcon;
            }
            defer c.stbi_image_free(pixels);
            gl.activeTexture(c.GL_TEXTURE0);
            c.glGenTextures(1, &textures[i]);
            c.glBindTexture(c.GL_TEXTURE_2D, textures[i]);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, width, height, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels);
        }
        return self;
    }
};

fn generate(allocator: std.mem.Allocator, entry: *const @import("../world/blockRegistry.zig").Definition, program: c_uint) !void {
    var world = try World.init(allocator);
    defer world.deinit() catch {};
    try world.setBlock(.{ 0, 0, 0 }, &entry.model);
    const eye = [3]f32{ 30, 26, 30 };
    try world.render(eye);
    world.bindGpuTextures();

    var framebuffer: c_uint = 0;
    c.__glewGenFramebuffers.?(1, &framebuffer);
    defer c.__glewDeleteFramebuffers.?(1, &framebuffer);
    c.__glewBindFramebuffer.?(c.GL_FRAMEBUFFER, framebuffer);
    defer c.__glewBindFramebuffer.?(c.GL_FRAMEBUFFER, 0);
    var texture: c_uint = 0;
    c.glGenTextures(1, &texture);
    defer c.glDeleteTextures(1, &texture);
    c.glBindTexture(c.GL_TEXTURE_2D, texture);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, render_size, render_size, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
    c.__glewFramebufferTexture2D.?(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, texture, 0);
    if (c.__glewCheckFramebufferStatus.?(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return error.IconFramebufferIncomplete;

    gl.useProgram(program);
    gl.uniform1i(gl.getUniformLocation(program, "uIconMode"), 1);
    defer gl.uniform1i(gl.getUniformLocation(program, "uIconMode"), 0);
    const names = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
    for (names, 0..) |name, unit| gl.uniform1i(gl.getUniformLocation(program, name), @intCast(unit));
    try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), render_size, render_size);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), 8 - eye[0], 8 - eye[1], 8 - eye[2]);
    const origin = world.gpu_region_origin_chunk;
    gl.uniform3i(gl.getUniformLocation(program, "uRegionOriginChunk"), origin[0], origin[1], origin[2]);
    gl.uniform3i(gl.getUniformLocation(program, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
    c.glViewport(0, 0, render_size, render_size);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    var pixels: [render_size * render_size * 4]u8 = undefined;
    c.glReadPixels(0, 0, render_size, render_size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixels);
    var top_down: [icon_size * icon_size * 4]u8 = undefined;
    const stride = icon_size * 4;
    for (0..icon_size) |y| for (0..icon_size) |x| {
        // Downsample in premultiplied alpha to avoid dark fringes on the PNG.
        var rgba = [4]u32{ 0, 0, 0, 0 };
        for (0..2) |dy| for (0..2) |dx| {
            const index = ((render_size - 1 - (y * 2 + dy)) * render_size + x * 2 + dx) * 4;
            const alpha: u32 = pixels[index + 3];
            for (0..3) |channel| rgba[channel] += @as(u32, pixels[index + channel]) * alpha;
            rgba[3] += alpha;
        };
        const index = (y * icon_size + x) * 4;
        for (0..3) |channel| top_down[index + channel] = if (rgba[3] == 0) 0 else @intCast(rgba[channel] / rgba[3]);
        top_down[index + 3] = @intCast(rgba[3] / 4);
    };
    if (std.fs.path.dirname(entry.icon_path)) |dir| try std.fs.cwd().makePath(dir);
    const path = try allocator.dupeZ(u8, entry.icon_path);
    defer allocator.free(path);
    if (c.stbi_write_png(path, icon_size, icon_size, 4, &top_down, stride) == 0) return error.CannotWriteBlockIcon;
}
