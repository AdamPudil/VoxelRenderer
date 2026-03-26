const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const fps = @import("utils/FPScounter.zig");
//const BlockChunk = @import("world/blockchunk.zig").BlockChunk;
const World = @import("world/world.zig").World;

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

const MOVE_SPEED: f32 = 1.0;
const LOOK_SPEED: f32 = 0.002;

const SIZE = 16;

const res = [2]f32{ 1280, 720 };

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    _ = c.glfwInit();
    defer c.glfwTerminate();

    const window = c.glfwCreateWindow(res[0], res[1], "Voxel Renderer in zig", null, null);
    c.glfwMakeContextCurrent(window);
    _ = c.glewInit();

    var fps_counter = try fps.FpsCounter.init();

    var vao: c_uint = 0;
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);

    // load shaders
    const program = try gl_utils.createProgram("src/graphics/voxel.vs", "src/graphics/voxel.fs");

    std.debug.print("program = {}\n", .{program});

    // camera
    var cam_pos = [3]f32{ -20, 70, 16 * 8 + 20 };
    var yaw: f32 = 3.14;
    var pitch: f32 = 0;

    // ---- voxel data ----
    var world = World(u16, 32, 32, 8).init(allocator);
    defer world.deinit();

    //  try world.generate(cam_pos);

    //var tex: c_uint = 0;
    //world.upload(&tex);

    //gl.ActiveTexture(c.GL_TEXTURE0);
    // c.glBindTexture(c.GL_TEXTURE_3D, tex);

    //c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
    //c.glTexParameteri(c.GL_TEXTURE_3D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);

    // uniforms
    const texLoc = gl.GetUniformLocation(program, "voxels");
    const camPosLoc = gl.GetUniformLocation(program, "camPos");
    const camDirLoc = gl.GetUniformLocation(program, "camDir");
    const resLoc = gl.GetUniformLocation(program, "res");
    const worldOriginLoc = gl.GetUniformLocation(program, "worldOrigin");
    const streamedSizeLoc = gl.GetUniformLocation(program, "streamedSize");

    c.glfwSetInputMode(window, c.GLFW_CURSOR, c.GLFW_CURSOR_DISABLED);

    var lastX: f64 = 640;
    var lastY: f64 = 360;

    while (c.glfwWindowShouldClose(window) == 0) {
        // precalsulate mouse
        var x: f64 = 0;
        var y: f64 = 0;
        c.glfwGetCursorPos(window, &x, &y);

        const dx = @as(f32, @floatCast(x - lastX)) * LOOK_SPEED;
        const dy = @as(f32, @floatCast(y - lastY)) * LOOK_SPEED;

        lastX = x;
        lastY = y;

        yaw -= dx;
        pitch -= dy;

        if (pitch > 1.5) pitch = 1.5;
        if (pitch < -1.5) pitch = -1.5;

        const forward = [3]f32{
            @cos(pitch) * @sin(yaw),
            @sin(pitch),
            @cos(pitch) * @cos(yaw),
        };

        const right = [3]f32{
            @sin(yaw - 1.57),
            0.0,
            @cos(yaw - 1.57),
        };

        // input
        if (c.glfwGetKey(window, c.GLFW_KEY_ESCAPE) == c.GLFW_PRESS) break;
        if (c.glfwGetKey(window, c.GLFW_KEY_W) == c.GLFW_PRESS) {
            cam_pos[0] += forward[0] * MOVE_SPEED;
            cam_pos[1] += forward[1] * MOVE_SPEED;
            cam_pos[2] += forward[2] * MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_S) == c.GLFW_PRESS) {
            cam_pos[0] -= forward[0] * MOVE_SPEED;
            cam_pos[1] -= forward[1] * MOVE_SPEED;
            cam_pos[2] -= forward[2] * MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_A) == c.GLFW_PRESS) {
            cam_pos[0] -= right[0] * MOVE_SPEED;
            cam_pos[2] -= right[2] * MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_D) == c.GLFW_PRESS) {
            cam_pos[0] += right[0] * MOVE_SPEED;
            cam_pos[2] += right[2] * MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_SPACE) == c.GLFW_PRESS) {
            cam_pos[1] += MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_LEFT_SHIFT) == c.GLFW_PRESS) {
            cam_pos[1] -= MOVE_SPEED;
        }
        if (c.glfwGetKey(window, c.GLFW_KEY_F3) == c.GLFW_PRESS) {
            fps_counter.toggle();
        }

        fps_counter.update();

        c.glClear(c.GL_COLOR_BUFFER_BIT);
        gl.UseProgram(program);

        // render / prepare streamed texture
        const tex = try world.render(cam_pos);
        gl.ActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_3D, tex);

        // uniforms
        gl.Uniform1i(texLoc, 0);
        gl.Uniform3fv(camPosLoc, 1, &cam_pos);
        gl.Uniform3fv(camDirLoc, 1, &forward);
        gl.Uniform2fv(resLoc, 1, &res);

        gl.Uniform3i(
            worldOriginLoc,
            @intCast(world.gpu_region_origin[0]),
            @intCast(world.gpu_region_origin[1]),
            @intCast(world.gpu_region_origin[2]),
        );

        gl.Uniform3i(
            streamedSizeLoc,
            @intCast(world.streamed_voxel_size[0]),
            @intCast(world.streamed_voxel_size[1]),
            @intCast(world.streamed_voxel_size[2]),
        );

        // draw
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);

        c.glfwSwapBuffers(window);

        if (c.glfwGetKey(window, c.GLFW_KEY_F2) == c.GLFW_PRESS) {
            gl_utils.saveScreenshot(1280, 720) catch {};
        }

        c.glfwPollEvents();
    }
}

// add this to main.zig (below utils or anywhere above main use)

// call this when F2 pressed
