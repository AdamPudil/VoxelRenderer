const c = @cImport({
    @cInclude("GL/glew.h");
});

pub fn GenVertexArrays(n: c_int, arr: [*c]c_uint) void {
    c.__glewGenVertexArrays.?(n, arr);
}
pub fn BindVertexArray(v: c_uint) void {
    c.__glewBindVertexArray.?(v);
}
pub fn CreateShader(t: c_uint) c_uint {
    return c.__glewCreateShader.?(t);
}
pub fn ShaderSource(s: c_uint, count: c_int, src: [*c][*c]const u8, len: [*c]c_int) void {
    c.__glewShaderSource.?(s, count, src, len);
}
pub fn CompileShader(s: c_uint) void {
    c.__glewCompileShader.?(s);
}
pub fn CreateProgram() c_uint {
    return c.__glewCreateProgram.?();
}
pub fn AttachShader(p: c_uint, s: c_uint) void {
    c.__glewAttachShader.?(p, s);
}
pub fn LinkProgram(p: c_uint) void {
    c.__glewLinkProgram.?(p);
}
pub fn UseProgram(p: c_uint) void {
    c.__glewUseProgram.?(p);
}
pub fn TexImage3D(
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
pub fn ActiveTexture(t: c_uint) void {
    c.__glewActiveTexture.?(t);
}
pub fn GetUniformLocation(p: c_uint, name: [*:0]const u8) c_int {
    return c.__glewGetUniformLocation.?(p, name);
}
pub fn Uniform1i(loc: c_int, v: c_int) void {
    c.__glewUniform1i.?(loc, v);
}
pub fn Uniform3fv(loc: c_int, count: c_int, ptr: [*c]const f32) void {
    c.__glewUniform3fv.?(loc, count, ptr);
}
pub fn Uniform2fv(loc: c_int, count: c_int, ptr: [*c]const f32) void {
    c.__glewUniform2fv.?(loc, count, ptr);
}

pub fn Uniform3i(loc: c_int, x: c_int, y: c_int, z: c_int) void {
    c.__glewUniform3i.?(loc, x, y, z);
}

pub fn Uniform1f(loc: c_int, v: f32) void {
    c.__glewUniform1f.?(loc, v);
}

pub fn TexSubImage3D(
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

pub fn GetShaderiv(shader: c_uint, pname: c_uint, params: *c_int) void {
    c.__glewGetShaderiv.?(shader, pname, params);
}

pub fn GetProgramiv(program: c_uint, pname: c_uint, params: *c_int) void {
    c.__glewGetProgramiv.?(program, pname, params);
}

pub fn GetShaderInfoLog(shader: c_uint, bufSize: c_int, length: ?*c_int, infoLog: [*c]u8) void {
    c.__glewGetShaderInfoLog.?(shader, bufSize, length, infoLog);
}

pub fn GetProgramInfoLog(program: c_uint, bufSize: c_int, length: ?*c_int, infoLog: [*c]u8) void {
    c.__glewGetProgramInfoLog.?(program, bufSize, length, infoLog);
}
