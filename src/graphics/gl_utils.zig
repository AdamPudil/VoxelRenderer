const std = @import("std");
const gl = @import("gl.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
    @cInclude("stb_image_write.c");
});

const ShaderStage = enum {
    vertex,
    fragment,
};

const EntryPair = struct {
    vertex_path: []u8,
    fragment_path: []u8,
};

fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 16 << 20);
}

fn dirNameAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.dirname(path)) |d| {
        return allocator.dupe(u8, d);
    }
    return allocator.dupe(u8, ".");
}

fn joinPathAlloc(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ a, b });
}

fn replaceExtAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    old_suffix: []const u8,
    new_suffix: []const u8,
) ![]u8 {
    std.debug.assert(std.mem.endsWith(u8, path, old_suffix));
    const stem = path[0 .. path.len - old_suffix.len];
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, new_suffix });
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn inferStage(path: []const u8) ?ShaderStage {
    if (std.mem.endsWith(u8, path, ".vs")) return .vertex;
    if (std.mem.endsWith(u8, path, ".fs")) return .fragment;
    if (std.mem.endsWith(u8, path, ".vert.glsl")) return .vertex;
    if (std.mem.endsWith(u8, path, ".frag.glsl")) return .fragment;
    return null;
}

fn stripKnownEntrySuffix(path: []const u8) []const u8 {
    const suffixes = [_][]const u8{
        ".vs",
        ".fs",
        ".vert.glsl",
        ".frag.glsl",
    };

    inline for (suffixes) |suf| {
        if (std.mem.endsWith(u8, path, suf)) {
            return path[0 .. path.len - suf.len];
        }
    }
    return path;
}

fn resolveEntryPair(path_or_stem: []const u8, allocator: std.mem.Allocator) !EntryPair {
    const stem = stripKnownEntrySuffix(path_or_stem);

    const cand_vs = try std.fmt.allocPrint(allocator, "{s}.vs", .{stem});
    errdefer allocator.free(cand_vs);

    const cand_fs = try std.fmt.allocPrint(allocator, "{s}.fs", .{stem});
    errdefer allocator.free(cand_fs);

    if (fileExists(cand_vs) and fileExists(cand_fs)) {
        return .{
            .vertex_path = cand_vs,
            .fragment_path = cand_fs,
        };
    }

    allocator.free(cand_vs);
    allocator.free(cand_fs);

    const cand_vert = try std.fmt.allocPrint(allocator, "{s}.vert.glsl", .{stem});
    errdefer allocator.free(cand_vert);

    const cand_frag = try std.fmt.allocPrint(allocator, "{s}.frag.glsl", .{stem});
    errdefer allocator.free(cand_frag);

    if (fileExists(cand_vert) and fileExists(cand_frag)) {
        return .{
            .vertex_path = cand_vert,
            .fragment_path = cand_frag,
        };
    }

    return error.ShaderEntryPairNotFound;
}

fn appendSlice(list: *std.ArrayList(u8), s: []const u8) !void {
    try list.appendSlice(s);
}

fn trimSpaces(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn parseIncludePath(line: []const u8) ?[]const u8 {
    const t = trimSpaces(line);
    if (!std.mem.startsWith(u8, t, "#include")) return null;

    const first_quote = std.mem.indexOfScalar(u8, t, '"') orelse return null;
    const after_first = t[first_quote + 1 ..];
    const second_rel = std.mem.indexOfScalar(u8, after_first, '"') orelse return null;

    return after_first[0..second_rel];
}

fn loadShaderSourceRecursive(
    allocator: std.mem.Allocator,
    path: []const u8,
    out: *std.ArrayList(u8),
    include_stack: *std.ArrayList([]u8),
) !void {
    for (include_stack.items) |p| {
        if (std.mem.eql(u8, p, path)) return error.ShaderIncludeCycle;
    }

    try include_stack.append(try allocator.dupe(u8, path));
    defer {
        const p = include_stack.pop();
        allocator.free(p);
    }

    const src = try readFile(path, allocator);
    defer allocator.free(src);

    const base_dir = try dirNameAlloc(allocator, path);
    defer allocator.free(base_dir);

    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line_raw| {
        const maybe_inc = parseIncludePath(line_raw);
        if (maybe_inc) |inc_rel| {
            const inc_path = try joinPathAlloc(allocator, base_dir, inc_rel);
            defer allocator.free(inc_path);

            try loadShaderSourceRecursive(allocator, inc_path, out, include_stack);
        } else {
            try appendSlice(out, line_raw);
            try out.append('\n');
        }
    }
}

fn loadShaderSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    var include_stack = std.ArrayList([]u8).init(allocator);
    defer include_stack.deinit();

    try loadShaderSourceRecursive(allocator, path, &out, &include_stack);
    return try out.toOwnedSlice();
}

fn compileShader(src: []const u8, kind: c_uint) !c_uint {
    const shader = gl.createShader(kind);

    var ptrs: [1][*c]const u8 = .{src.ptr};
    var len: c_int = @intCast(src.len);

    gl.shaderSource(shader, 1, &ptrs, &len);
    gl.compileShader(shader);

    var ok: c_int = 0;
    gl.getShaderiv(shader, c.GL_COMPILE_STATUS, &ok);

    if (ok == 0) {
        var log_len: c_int = 0;
        gl.getShaderiv(shader, c.GL_INFO_LOG_LENGTH, &log_len);

        const alloc_len: usize = @intCast(if (log_len > 1) log_len else 1024);
        const log = try std.heap.page_allocator.alloc(u8, alloc_len);
        defer std.heap.page_allocator.free(log);

        var written: c_int = 0;
        gl.getShaderInfoLog(shader, @intCast(log.len), &written, log.ptr);

        const kind_name =
            if (kind == c.GL_VERTEX_SHADER) "vertex" else if (kind == c.GL_FRAGMENT_SHADER) "fragment" else "unknown";

        std.debug.print(
            "{s} shader compile failed:\n{s}\n",
            .{ kind_name, log[0..@intCast(if (written > 0) written else 0)] },
        );

        return error.ShaderCompileFailed;
    }

    return shader;
}

fn compileShaderFromPath(
    path: []const u8,
    stage: ShaderStage,
    allocator: std.mem.Allocator,
) !c_uint {
    const src = try loadShaderSource(allocator, path);
    defer allocator.free(src);

    std.debug.print("expanded shader [{s}]:\n{s}\n", .{ path, src });

    return switch (stage) {
        .vertex => compileShader(src, c.GL_VERTEX_SHADER),
        .fragment => compileShader(src, c.GL_FRAGMENT_SHADER),
    };
}

pub fn createProgram(path_or_stem: []const u8) !c_uint {
    const allocator = std.heap.page_allocator;

    const pair = try resolveEntryPair(path_or_stem, allocator);
    defer allocator.free(pair.vertex_path);
    defer allocator.free(pair.fragment_path);

    const vs = try compileShaderFromPath(pair.vertex_path, .vertex, allocator);
    errdefer gl.deleteShader(vs);

    const fs = try compileShaderFromPath(pair.fragment_path, .fragment, allocator);
    errdefer gl.deleteShader(fs);

    const prog = gl.createProgram();
    errdefer gl.deleteProgram(prog);

    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);

    var ok: c_int = 0;
    gl.getProgramiv(prog, c.GL_LINK_STATUS, &ok);

    if (ok == 0) {
        var log_len: c_int = 0;
        gl.getProgramiv(prog, c.GL_INFO_LOG_LENGTH, &log_len);

        const alloc_len: usize = @intCast(if (log_len > 1) log_len else 1024);
        const log = try allocator.alloc(u8, alloc_len);
        defer allocator.free(log);

        var written: c_int = 0;
        gl.getProgramInfoLog(prog, @intCast(log.len), &written, log.ptr);

        std.debug.print(
            "program link failed:\n{s}\n",
            .{log[0..@intCast(if (written > 0) written else 0)]},
        );

        return error.ProgramLinkFailed;
    }

    gl.deleteShader(vs);
    gl.deleteShader(fs);

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
