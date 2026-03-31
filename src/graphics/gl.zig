const c = @cImport({
    @cInclude("GL/glew.h");
});

pub const Error = error{
    MissingOpenGLFunction,
};

// Shaders
pub fn createShader(t: c_uint) c_uint {
    return c.__glewCreateShader.?(t);
}
pub fn shaderSource(
    s: c_uint,
    count: c_int,
    src: [*c][*c]const u8,
    len: [*c]c_int,
) void {
    c.__glewShaderSource.?(s, count, src, len);
}
pub fn compileShader(s: c_uint) void {
    c.__glewCompileShader.?(s);
}

pub fn attachShader(p: c_uint, s: c_uint) void {
    c.__glewAttachShader.?(p, s);
}

pub fn getShaderiv(
    shader: c_uint,
    pname: c_uint,
    params: *c_int,
) void {
    c.__glewGetShaderiv.?(shader, pname, params);
}

pub fn getShaderInfoLog(
    shader: c_uint,
    bufSize: c_int,
    length: ?*c_int,
    infoLog: [*c]u8,
) void {
    c.__glewGetShaderInfoLog.?(shader, bufSize, length, infoLog);
}

pub fn deleteShader(shader: c_uint) void {
    const f = c.__glewDeleteShader orelse return;
    f(shader);
}

// Program

pub fn createProgram() c_uint {
    return c.__glewCreateProgram.?();
}

pub fn linkProgram(p: c_uint) void {
    c.__glewLinkProgram.?(p);
}

pub fn useProgram(p: c_uint) void {
    c.__glewUseProgram.?(p);
}

pub fn deleteProgram(program: c_uint) void {
    const f = c.__glewDeleteProgram orelse return;
    f(program);
}

pub fn getProgramiv(
    program: c_uint,
    pname: c_uint,
    params: *c_int,
) void {
    c.__glewGetProgramiv.?(program, pname, params);
}

pub fn getProgramInfoLog(
    program: c_uint,
    bufSize: c_int,
    length: ?*c_int,
    infoLog: [*c]u8,
) void {
    c.__glewGetProgramInfoLog.?(program, bufSize, length, infoLog);
}

// uniforms

pub fn getUniformLocation(p: c_uint, name: [*:0]const u8) c_int {
    return c.__glewGetUniformLocation.?(p, name);
}

pub fn uniform1i(loc: c_int, v: c_int) void {
    c.__glewUniform1i.?(loc, v);
}

pub fn uniform1f(loc: c_int, v: f32) void {
    c.__glewUniform1f.?(loc, v);
}

pub fn uniform2f(location: c.GLint, v0: c.GLfloat, v1: c.GLfloat) Error!void {
    const f = c.__glewUniform2f orelse return Error.MissingOpenGLFunction;
    f(location, v0, v1);
}

pub fn uniform2fv(loc: c_int, count: c_int, ptr: [*c]const f32) void {
    c.__glewUniform2fv.?(loc, count, ptr);
}

pub fn uniform3i(
    loc: c_int,
    x: c_int,
    y: c_int,
    z: c_int,
) void {
    c.__glewUniform3i.?(loc, x, y, z);
}

pub fn uniform3f(
    location: c.GLint,
    v0: c.GLfloat,
    v1: c.GLfloat,
    v2: c.GLfloat,
) Error!void {
    const f = c.__glewUniform3f orelse return Error.MissingOpenGLFunction;
    f(location, v0, v1, v2);
}

pub fn uniform3fv(
    loc: c_int,
    count: c_int,
    ptr: [*c]const f32,
) void {
    c.__glewUniform3fv.?(loc, count, ptr);
}

// vertex buffer

pub fn genVertexArrays(n: c_int, arr: [*c]c_uint) void {
    c.__glewGenVertexArrays.?(n, arr);
}
pub fn bindVertexArray(v: c_uint) void {
    c.__glewBindVertexArray.?(v);
}

// Boffers

pub fn bufferData(
    target: c.GLenum,
    size: c.GLsizeiptr,
    data: ?*const anyopaque,
    usage: c.GLenum,
) Error!void {
    const f = c.__glewBufferData orelse return Error.MissingOpenGLFunction;
    f(target, size, data, usage);
}

pub fn genBuffers(n: c.GLsizei, buffers: *c.GLuint) Error!void {
    const f = c.__glewGenBuffers orelse return Error.MissingOpenGLFunction;
    f(n, buffers);
}

pub fn deleteBuffers(n: c.GLsizei, buffers: *const c.GLuint) Error!void {
    const f = c.__glewDeleteBuffers orelse return Error.MissingOpenGLFunction;
    f(n, buffers);
}

pub fn bindBuffer(target: c.GLenum, buffer: c.GLuint) Error!void {
    const f = c.__glewBindBuffer orelse return Error.MissingOpenGLFunction;
    f(target, buffer);
}

pub fn bindBufferBase(
    target: c.GLenum,
    index: c.GLuint,
    buffer: c.GLuint,
) Error!void {
    const f = c.__glewBindBufferBase orelse return Error.MissingOpenGLFunction;
    f(target, index, buffer);
}

// Texture 3D

pub fn texImage3D(
    target: c_uint,
    level: c_int,
    internal: c_int,
    w: c_int,
    h: c_int,
    d: c_int,
    border: c_int,
    format: c_uint,
    typ: c_uint,
    data: ?*const anyopaque,
) void {
    c.__glewTexImage3D.?(target, level, internal, w, h, d, border, format, typ, data);
}
pub fn activeTexture(t: c_uint) void {
    c.__glewActiveTexture.?(t);
}

pub fn texSubImage3D(
    target: c_uint,
    level: c_int,
    xoffset: c_int,
    yoffset: c_int,
    zoffset: c_int,
    width: c_int,
    height: c_int,
    depth: c_int,
    format: c_uint,
    typ: c_uint,
    data: ?*const anyopaque,
) void {
    c.__glewTexSubImage3D.?(
        target,
        level,
        xoffset,
        yoffset,
        zoffset,
        width,
        height,
        depth,
        format,
        typ,
        data,
    );
}

pub fn genTextures(n: c.GLsizei, textures: *c.GLuint) void {
    c.glGenTextures(n, textures);
}

pub fn deleteTextures(n: c.GLsizei, textures: *const c.GLuint) void {
    c.glDeleteTextures(n, textures);
}

pub fn bindTexture(target: c.GLenum, texture: c.GLuint) void {
    c.glBindTexture(target, texture);
}

pub fn texBuffer(
    target: c.GLenum,
    internalformat: c.GLenum,
    buffer: c.GLuint,
) Error!void {
    const f = c.__glewTexBuffer orelse return Error.MissingOpenGLFunction;
    f(target, internalformat, buffer);
}
