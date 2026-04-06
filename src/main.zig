const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const fps = @import("utils/FPScounter.zig");
const World = @import("world/world.zig").World;
const wc = @import("world/worldConstants.zig");

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

const MOVE_SPEED: f32 = 1.0;
const LOOK_SPEED: f32 = 0.002;

const CHUNK_BLOCK_CNT = 16;

const res = [2]f32{ 640, 480 };

const STREAM_CHUNKS_XZ = wc.STREAM_CHUNKS_XZ;
const STREAM_CHUNKS_Y = wc.STREAM_CHUNKS_Y;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    _ = c.glfwInit();
    defer c.glfwTerminate();

    const window = c.glfwCreateWindow(res[0], res[1], "Voxel Renderer in zig", null, null);
    c.glfwMakeContextCurrent(window);
    _ = c.glewInit();

    var fps_counter = try fps.FpsCounter.init();

    var vao: c_uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.bindVertexArray(vao);

    // load shaders
    const program = try gl_utils.createProgram("src/graphics/shaders/voxel");
    std.debug.print("program = {}\n", .{program});

    // camera
    var cam_pos = [3]f32{ 100, 30, 100 };
    var yaw: f32 = 3.14;
    var pitch: f32 = 0;

    // world
    var world = try World.init(allocator);
    defer world.deinit() catch |err| {
        std.debug.print("{}", .{err});
    };
    try world.startGenerator();
    //try world.enqueueInitialArea();

    // uniforms
    const resLoc = gl.getUniformLocation(program, "uResolution");
    const camPosLoc = gl.getUniformLocation(program, "uCamPos");
    const camDirLoc = gl.getUniformLocation(program, "uCamDir");
    const regionOriginLoc = gl.getUniformLocation(program, "uRegionOriginChunk");
    const regionSizeLoc = gl.getUniformLocation(program, "uRegionSizeChunks");

    const chunkHeaderTexLoc = gl.getUniformLocation(program, "uChunkHeaderTex");
    const blockHeaderTexLoc = gl.getUniformLocation(program, "uBlockHeaderTex");
    const voxelBlockHeaderTexLoc = gl.getUniformLocation(program, "uVoxelBlockHeaderTex");
    const bitmapTexLoc = gl.getUniformLocation(program, "uBitmapTex");
    const paletteTexLoc = gl.getUniformLocation(program, "uPaletteTex");
    const indexTexLoc = gl.getUniformLocation(program, "uIndexTex");

    c.glfwSetInputMode(window, c.GLFW_CURSOR, c.GLFW_CURSOR_DISABLED);

    var lastX: f64 = 640;
    var lastY: f64 = 360;

    gl.useProgram(program);

    while (c.glfwWindowShouldClose(window) == 0) {
        // precalculations
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

        gl.uniform1i(chunkHeaderTexLoc, 0);
        gl.uniform1i(blockHeaderTexLoc, 1);
        gl.uniform1i(voxelBlockHeaderTexLoc, 2);
        gl.uniform1i(bitmapTexLoc, 3);
        gl.uniform1i(paletteTexLoc, 4);
        gl.uniform1i(indexTexLoc, 5);

        // render / prepare streamed texture
        try world.render(cam_pos);
        world.bindGpuTextures();

        // uniforms
        try gl.uniform2f(
            resLoc,
            res[0],
            res[1],
        );

        try gl.uniform3f(camPosLoc, cam_pos[0], cam_pos[1], cam_pos[2]);
        try gl.uniform3f(camDirLoc, forward[0], forward[1], forward[2]);

        gl.uniform3i(
            regionOriginLoc,
            world.gpu_region_origin_chunk[0],
            world.gpu_region_origin_chunk[1],
            world.gpu_region_origin_chunk[2],
        );

        gl.uniform3i(
            regionSizeLoc,
            STREAM_CHUNKS_XZ,
            STREAM_CHUNKS_Y,
            STREAM_CHUNKS_XZ,
        );

        // draw
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);

        c.glfwSwapBuffers(window);

        if (c.glfwGetKey(window, c.GLFW_KEY_F2) == c.GLFW_PRESS) {
            gl_utils.saveScreenshot(res[0], res[1]) catch {};
        }

        c.glfwPollEvents();
    }
}
