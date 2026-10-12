//! Headless integration check. Uses Mesa/EGL; writes previews under /tmp/voxel-block-smoke.
const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const Registry = @import("world/blockRegistry.zig").BlockRegistry;
const Icons = @import("graphics/blockIcons.zig").Icons;
const Menu = @import("graphics/blockMenu.zig").Menu;
const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("stb_image.h");
    @cInclude("stb_image_write.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("Smoke test leaked memory");
    const a = gpa.allocator();
    const display = c.eglGetPlatformDisplay(0x31DD, null, null);
    if (c.eglInitialize(display, null, null) == 0) return error.EglUnavailable;
    defer _ = c.eglTerminate(display);
    if (c.eglBindAPI(c.EGL_OPENGL_API) == 0) return error.EglBindFailed;
    const attrs = [_]c_int{ c.EGL_SURFACE_TYPE, c.EGL_PBUFFER_BIT, c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_BIT, c.EGL_RED_SIZE, 8, c.EGL_GREEN_SIZE, 8, c.EGL_BLUE_SIZE, 8, c.EGL_ALPHA_SIZE, 8, c.EGL_NONE };
    var config: c.EGLConfig = null;
    var count: c_int = 0;
    if (c.eglChooseConfig(display, &attrs, &config, 1, &count) == 0 or count == 0) return error.EglConfigFailed;
    const context_attrs = [_]c_int{ c.EGL_CONTEXT_MAJOR_VERSION, 4, c.EGL_CONTEXT_MINOR_VERSION, 6, c.EGL_NONE };
    const context = c.eglCreateContext(display, config, null, &context_attrs);
    if (context == null) return error.EglContextFailed;
    defer _ = c.eglDestroyContext(display, context);
    const surface_attrs = [_]c_int{ c.EGL_WIDTH, 960, c.EGL_HEIGHT, 640, c.EGL_NONE };
    const surface = c.eglCreatePbufferSurface(display, config, &surface_attrs);
    if (surface == null) return error.EglSurfaceFailed;
    defer _ = c.eglDestroySurface(display, surface);
    if (c.eglMakeCurrent(display, surface, surface, context) == 0) return error.EglMakeCurrentFailed;
    c.glewExperimental = c.GL_TRUE;
    // GLEW can report "no GLX display" after successfully loading GL on EGL.
    _ = c.glewInit();
    if (c.__glewCreateShader == null) return error.GlewUnavailable;
    while (c.glGetError() != c.GL_NO_ERROR) {}
    var vao: c_uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.bindVertexArray(vao);
    defer c.__glewDeleteVertexArrays.?(1, &vao);

    const folder = "/tmp/voxel-block-smoke";
    try @import("world/testBlocks.zig").ensure(a, folder);
    var registry = try Registry.loadDirectory(a, folder);
    defer registry.deinit();
    for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel" }) |path| {
        const program = try gl_utils.createProgram(path);
        defer gl.deleteProgram(program);
        var icons = try Icons.init(a, &registry, program);
        defer icons.deinit();
        for (registry.blocks.items) |entry| {
            const icon_path = try a.dupeZ(u8, entry.icon_path);
            defer a.free(icon_path);
            var width: c_int = 0;
            var height: c_int = 0;
            var channels: c_int = 0;
            const pixels = c.stbi_load(icon_path, &width, &height, &channels, 4);
            if (pixels == null or width != 64 or height != 64) return error.InvalidGeneratedIcon;
            defer c.stbi_image_free(pixels);
            var visible: usize = 0;
            for (0..4096) |i| if (pixels[i * 4 + 3] > 0) {
                visible += 1;
            };
            if (visible < 30 or visible > 4000) return error.IconMissingModelOrTransparency;
            std.debug.print("Icon {s} v{d}: {d} visible pixels\n", .{ entry.name, entry.variant, visible });
        }
        try checkReflections(a, program, &registry);
        var menu = try Menu.init();
        defer menu.deinit();
        menu.open = true;
        menu.selected = registry.find("Checker", 0);
        c.glViewport(0, 0, 960, 640);
        c.glClearColor(0, 0, 0, 1);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        try menu.draw(960, 640, 370, 160, &registry, &icons);
        try savePreview(a, folder ++ "/menu.png");
        if (c.glGetError() != c.GL_NO_ERROR) return error.OpenGLSmokeError;
    }
    std.debug.print("Headless block/icon/menu checks passed. Preview: {s}/menu.png\n", .{folder});
}

fn savePreview(a: std.mem.Allocator, path: [*:0]const u8) !void {
    const pixels = try a.alloc(u8, 960 * 640 * 4);
    defer a.free(pixels);
    const flipped = try a.alloc(u8, pixels.len);
    defer a.free(flipped);
    c.glReadPixels(0, 0, 960, 640, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
    for (0..640) |y| @memcpy(flipped[y * 3840 ..][0..3840], pixels[(639 - y) * 3840 ..][0..3840]);
    if (c.stbi_write_png(path, 960, 640, 4, flipped.ptr, 3840) == 0) return error.PreviewWriteFailed;
}

// The target is behind the viewer: it can appear only through a reflected ray.
fn reflectionPixel(a: std.mem.Allocator, program: c_uint, mirror: *const @import("world/block.zig").Block, target_color: [3]u8, axis: usize, sign: f32) ![4]u8 {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    var world = try World.init(a);
    defer world.deinit() catch {};
    const base = [3]i32{ -2, 6, -2 };
    try world.setBlock(base, mirror);
    var target_position = base;
    target_position[axis] += if (sign > 0) 4 else -4;
    var target_material = Voxel.rgb(target_color[0], target_color[1], target_color[2]);
    target_material.luminescence = 255;
    const target = Block.initMono(0, target_material);
    try world.setBlock(target_position, &target);
    var eye: [3]f32 = undefined;
    for (0..3) |i| eye[i] = @as(f32, @floatFromInt(base[i] * 16)) + 8;
    eye[axis] += sign * 32;
    var direction = [3]f32{ 0, 0, 0 };
    direction[axis] = -sign;
    return scenePixel(&world, program, eye, direction);
}

fn scenePixel(world: *@import("world/world.zig").World, program: c_uint, eye: [3]f32, direction: [3]f32) ![4]u8 {
    const wc = @import("world/worldConstants.zig");
    try world.render(eye);
    world.bindGpuTextures();
    gl.useProgram(program);
    gl.uniform1i(gl.getUniformLocation(program, "uIconMode"), 0);
    const names = [_][*:0]const u8{ "uChunkHeaderTex", "uBlockHeaderTex", "uVoxelBlockHeaderTex", "uBitmapTex", "uPaletteTex", "uIndexTex" };
    for (names, 0..) |name, unit| gl.uniform1i(gl.getUniformLocation(program, name), @intCast(unit));
    try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), 65, 65);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), eye[0], eye[1], eye[2]);
    try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), direction[0], direction[1], direction[2]);
    const origin = world.gpu_region_origin_chunk;
    gl.uniform3i(gl.getUniformLocation(program, "uRegionOriginChunk"), origin[0], origin[1], origin[2]);
    gl.uniform3i(gl.getUniformLocation(program, "uRegionSizeChunks"), wc.STREAM_CHUNKS_XZ, wc.STREAM_CHUNKS_Y, wc.STREAM_CHUNKS_XZ);
    c.glViewport(0, 0, 65, 65);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    var pixel: [4]u8 = undefined;
    c.glReadPixels(32, 32, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixel);
    return pixel;
}

fn checkReflections(a: std.mem.Allocator, program: c_uint, registry: *const Registry) !void {
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const mirror = &registry.blocks.items[registry.find("Mirror", 0).?].model;
    const pixel = try reflectionPixel(a, program, mirror, .{ 0, 255, 0 }, 2, 1);
    if (pixel[1] < 180 or pixel[0] > 20 or pixel[2] > 20 or pixel[3] != 255) return error.MirrorDidNotReflectScene;
    const matte = Block.initMono(0, Voxel.rgb(255, 255, 255));
    const no_reflection = try reflectionPixel(a, program, &matte, .{ 0, 255, 0 }, 2, 1);
    if (@abs(@as(i32, no_reflection[1]) - no_reflection[0]) > 1) return error.MatteMaterialReflected;
    var polished = Voxel.rgb(255, 255, 255);
    polished.reflectiveness = 255;
    const mono = Block.initMono(0, polished);
    for (0..3) |axis| for ([_]f32{ -1, 1 }) |sign| {
        const result = try reflectionPixel(a, program, &mono, .{ 0, 255, 0 }, axis, sign);
        if (result[1] < 180 or result[0] > 2 or result[2] > 2) return error.ReflectionFaceOrSelfIntersection;
    };
    var previous: ?[4]u8 = null;
    for ([_][]const u8{ "Gold", "Copper", "Iron", "Mirror" }) |name| {
        const model = &registry.blocks.items[registry.find(name, 0).?].model;
        const result = try reflectionPixel(a, program, model, .{ 255, 255, 255 }, 2, 1);
        if (previous) |before| if (std.mem.eql(u8, &before, &result)) return error.MaterialsNotDistinct;
        if ((std.mem.eql(u8, name, "Gold") or std.mem.eql(u8, name, "Copper")) and result[0] < @as(u16, result[2]) + 30) return error.MetalReflectionNotTinted;
        previous = result;
        std.debug.print("Reflection {s}: {any}\n", .{ name, result });
    }
}
