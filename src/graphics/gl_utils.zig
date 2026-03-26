const std = @import("std");
const gl = @import("gl.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("stb_image_write.c");
});

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 1 << 20);
}

fn compileShader(src: []const u8, kind: c_uint) c_uint {
    const shader = gl.CreateShader(kind);

    var ptrs: [1][*c]const u8 = .{src.ptr};
    var len: c_int = @intCast(src.len);

    gl.ShaderSource(shader, 1, &ptrs, &len);
    gl.CompileShader(shader);

    return shader;
}

pub fn createProgram(vsPath: []const u8, fsPath: []const u8) !c_uint {
    const gpa = std.heap.page_allocator;

    const vs_src = try readFile(vsPath, gpa);
    const fs_src = try readFile(fsPath, gpa);

    const vs = compileShader(vs_src, c.GL_VERTEX_SHADER);
    const fs = compileShader(fs_src, c.GL_FRAGMENT_SHADER);

    const prog = gl.CreateProgram();

    gl.AttachShader(prog, vs);
    gl.AttachShader(prog, fs);

    gl.LinkProgram(prog);

    return prog;
}

pub fn saveScreenshot(width: i32, height: i32) !void {
    const size = @as(usize, @intCast(width * height * 3));
    var buffer = try std.heap.page_allocator.alloc(u8, size);
    defer std.heap.page_allocator.free(buffer);

    c.glPixelStorei(c.GL_PACK_ALIGNMENT, 1);
    c.glReadBuffer(c.GL_FRONT);
    c.glReadPixels(0, 0, width, height, c.GL_RGB, c.GL_UNSIGNED_BYTE, buffer.ptr);

    // flip vertically (OpenGL is upside down)
    const row = @as(usize, @intCast(width * 3));
    const tmp = try std.heap.page_allocator.alloc(u8, row);
    defer std.heap.page_allocator.free(tmp);

    var y: usize = 0;
    while (y < @as(usize, @intCast(@divFloor(height, 2)))) : (y += 1) {
        const top = y * row;
        const bot = (@as(usize, @intCast(height)) - 1 - y) * row;

        std.mem.copyForwards(u8, tmp[0..row], buffer[top .. top + row]);
        std.mem.copyForwards(u8, buffer[top .. top + row], buffer[bot .. bot + row]);
        std.mem.copyForwards(u8, buffer[bot .. bot + row], tmp[0..row]);
    }

    try std.fs.cwd().makePath("screenshots");

    var name_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(
        &name_buf,
        "screenshots/screenshot_{d}.png",
        .{std.time.timestamp()},
    );

    _ = c.stbi_write_png(
        path.ptr,
        width,
        height,
        3,
        buffer.ptr,
        width * 3,
    );
}
