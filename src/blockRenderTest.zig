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
