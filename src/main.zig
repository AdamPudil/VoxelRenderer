const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const fps = @import("utils/FPScounter.zig");
const World = @import("world/world.zig").World;
const Registry = @import("world/blockRegistry.zig").BlockRegistry;
const test_blocks = @import("world/testBlocks.zig");
const Icons = @import("graphics/blockIcons.zig").Icons;
const Menu = @import("graphics/blockMenu.zig").Menu;
const EditCooldown = @import("world/blockEditing.zig").EditCooldown;
const Block = @import("world/block.zig").Block;
const wc = @import("world/worldConstants.zig");
const input = @import("core/input/inputSystem.zig");
const InputBackend = @import("core/input/glfwBackend.zig").Backend;

const c = @cImport({
    @cInclude("GL/glew.h");
    @cInclude("GLFW/glfw3.h");
});

const MOVE_SPEED: f32 = 1.0;
const LOOK_SPEED: f32 = 0.002;

const CHUNK_BLOCK_CNT = 16;

const res = [2]f32{ 1920, 1080 };

const STREAM_CHUNKS_XZ = wc.STREAM_CHUNKS_XZ;
const STREAM_CHUNKS_Y = wc.STREAM_CHUNKS_Y;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var profile: []const u8 = "auto";
    var gpu_info = false;
    var assets: []const u8 = "assets/blocks";
    var input_profile_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--shader=")) {
            profile = arg[9..];
            if (!std.mem.eql(u8, profile, "auto") and
                !std.mem.eql(u8, profile, "thinkpad") and
                !std.mem.eql(u8, profile, "desktop")) return error.InvalidShaderProfile;
        } else if (std.mem.startsWith(u8, arg, "--assets=")) {
            assets = arg[9..];
            if (assets.len == 0) return error.MissingAssetDirectory;
        } else if (std.mem.startsWith(u8, arg, "--input-profile=")) {
            input_profile_path = arg[16..];
            if (input_profile_path.?.len == 0) return error.MissingInputProfile;
        } else if (std.mem.eql(u8, arg, "--gpu-info")) {
            gpu_info = true;
        } else {
            std.debug.print("Usage: voxel [--shader=auto|thinkpad|desktop] [--gpu-info] [--assets=directory] [--input-profile=file.json]\n", .{});
            return error.UnknownArgument;
        }
    }

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    // Request the desktop context first, retaining the existing GLSL 4.20 baseline.
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 4);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 6);
    if (gpu_info) c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    const window = c.glfwCreateWindow(res[0], res[1], "Voxel Renderer in zig", null, null) orelse fallback: {
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 2);
        break :fallback c.glfwCreateWindow(res[0], res[1], "Voxel Renderer in zig", null, null) orelse {
            std.debug.print("Unable to create an OpenGL 4.2+ context required by the current shaders.\n", .{});
            return error.OpenGLContextUnavailable;
        };
    };
    defer c.glfwDestroyWindow(window);
    c.glfwMakeContextCurrent(window);
    c.glewExperimental = c.GL_TRUE;
    if (c.glewInit() != c.GLEW_OK) return error.GlewInitFailed;

    const renderer = glString(c.GL_RENDERER);
    std.debug.print("GPU: {s}\nVendor: {s}\nOpenGL: {s}\nGLSL: {s}\n", .{
        renderer, glString(c.GL_VENDOR), glString(c.GL_VERSION), glString(c.GL_SHADING_LANGUAGE_VERSION),
    });
    var major: c_int = 0;
    var minor: c_int = 0;
    c.glGetIntegerv(c.GL_MAJOR_VERSION, &major);
    c.glGetIntegerv(c.GL_MINOR_VERSION, &minor);
    const supports_desktop = major > 4 or (major == 4 and minor >= 6);
    const desktop = std.mem.eql(u8, profile, "desktop") or
        (std.mem.eql(u8, profile, "auto") and supports_desktop and
        std.mem.indexOf(u8, renderer, "RTX 3060") != null);
    if (desktop and !supports_desktop) {
        std.debug.print("The desktop shader requires OpenGL 4.6 / GLSL 4.60. Use --shader=thinkpad on this GPU.\n", .{});
        return error.DesktopShaderUnsupported;
    }
    const shader_path = if (desktop) "src/graphics/shaders/desktop/voxel" else "src/graphics/shaders/voxel";
    std.debug.print("Shader profile: {s} ({s})\n", .{ if (desktop) "desktop" else "thinkpad", shader_path });
    const program = try gl_utils.createProgram(shader_path);
    defer gl.deleteProgram(program);
    if (gpu_info) return;

    var vao: c_uint = 0;
    gl.genVertexArrays(1, &vao);
    gl.bindVertexArray(vao);
    defer c.__glewDeleteVertexArrays.?(1, &vao);

    try test_blocks.ensure(allocator, assets);
    var registry = try Registry.loadDirectory(allocator, assets);
    defer registry.deinit();
    var icons = try Icons.init(allocator, &registry, program);
    defer icons.deinit();
    var menu = try Menu.init();
    defer menu.deinit();
    std.debug.print("Loaded {d} block models. TAB opens the block menu.\n", .{registry.blocks.items.len});

    // camera
    var cam_pos = [3]f32{ 100, 30, 100 };
    var yaw: f32 = 3.14;
    var pitch: f32 = 0;

    // world
    var world = try World.init(allocator);
    defer world.deinit() catch |err| {
        std.debug.print("{}", .{err});
    };
    try @import("world/startupBuilding.zig").place(&world);
    try world.startGenerator();
    //try world.enqueueInitialArea();

    // uniforms
    const voxelModeLoc = gl.getUniformLocation(program, "uVoxelMode");
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

    const event_bus = try allocator.create(input.Bus);
    defer allocator.destroy(event_bus);
    event_bus.* = .{};
    if (input_profile_path) |path| {
        const bindings = try input.t.loadProfile(allocator, std.fs.cwd(), path);
        _ = try event_bus.submit("input", input.Command{ .apply_profile = .{ .request_id = 1, .profile = bindings } });
    }
    var input_system = input.InputSystem{ .bus = event_bus };
    var input_backend = InputBackend{ .window = @ptrCast(window) };
    input_backend.attach();
    defer input_backend.detach();
    var controls = DeveloperControls{ .menu = &menu };
    var frame: u64 = 0;
    var edit_cooldown = EditCooldown{};

    gl.useProgram(program);

    var fps_counter = try fps.FpsCounter.init();
    defer fps_counter.deinit();

    while (c.glfwWindowShouldClose(window) == 0) {
        frame += 1;
        controls.begin();
        event_bus.beginFrame();
        try input_system.begin(frame);
        try input_backend.poll(&input_system);
        var framebuffer_width: c_int = 0;
        var framebuffer_height: c_int = 0;
        var window_width: c_int = 0;
        var window_height: c_int = 0;
        c.glfwGetFramebufferSize(window, &framebuffer_width, &framebuffer_height);
        c.glfwGetWindowSize(window, &window_width, &window_height);
        controls.width = @floatFromInt(window_width);
        controls.height = @floatFromInt(window_height);
        controls.block_count = registry.blocks.items.len;
        try input.routing.drainForDeveloperTools(event_bus, &controls);
        event_bus.clearCurrent();
        // Retire the current frame; next/debt buffers remain intact.
        if (controls.quit) break;
        if (controls.toggle_fps) fps_counter.toggle();
        if (controls.reset_edit) edit_cooldown.armed = false;
        if (framebuffer_width == 0 or framebuffer_height == 0) {
            c.glfwWaitEventsTimeout(0.05);
            continue;
        }
        const left = controls.down(.remove) or controls.pressed[@intFromEnum(input.t.Action.remove)];
        const right_mouse = controls.down(.place) or controls.pressed[@intFromEnum(input.t.Action.place)];
        const x = input_system.pointer[0];
        const y = input_system.pointer[1];
        yaw -= controls.look[0] * LOOK_SPEED;
        pitch -= controls.look[1] * LOOK_SPEED;

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

        const forward_amount = controls.axis(.forward, .backward);
        const right_amount = controls.axis(.right, .left);
        for (0..3) |axis| cam_pos[axis] += forward[axis] * forward_amount * MOVE_SPEED;
        cam_pos[0] += right[0] * right_amount * MOVE_SPEED;
        cam_pos[2] += right[2] * right_amount * MOVE_SPEED;
        cam_pos[1] += controls.axis(.up, .down) * MOVE_SPEED;

        gl.useProgram(program);
        c.glViewport(0, 0, framebuffer_width, framebuffer_height);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        gl.uniform1i(chunkHeaderTexLoc, 0);
        gl.uniform1i(blockHeaderTexLoc, 1);
        gl.uniform1i(voxelBlockHeaderTexLoc, 2);
        gl.uniform1i(bitmapTexLoc, 3);
        gl.uniform1i(paletteTexLoc, 4);
        gl.uniform1i(indexTexLoc, 5);

        // render / prepare streamed texture
        try world.render(cam_pos);
        if (edit_cooldown.update(c.glfwGetTime(), menu.open, left, right_mouse)) {
            if (world.raycast(cam_pos, forward, 256)) |hit| {
                if (left) {
                    if (menu.removal.voxel) {
                        _ = try world.removeVoxel(hit.voxel);
                    } else {
                        const empty = Block.initEmpty(0);
                        try world.setBlock(hit.blockCoord(), &empty);
                    }
                } else if (right_mouse and menu.selected != null and !std.mem.eql(i32, &hit.normal, &.{ 0, 0, 0 })) {
                    const dest = hit.adjacentBlock();
                    var contains_camera = true;
                    for (0..3) |axis| {
                        if (@as(i32, @intFromFloat(@floor(cam_pos[axis] / wc.BLOCK_VOXEL_CNT))) != dest[axis]) contains_camera = false;
                    }
                    if (!contains_camera and world.blockIsEmpty(dest)) {
                        try world.setBlock(dest, &registry.blocks.items[menu.selected.?].model);
                    }
                }
                try world.render(cam_pos);
            }
        }
        world.bindGpuTextures();

        // Outline exactly the cell affected by the current removal mode.
        gl.uniform1i(voxelModeLoc, @intFromBool(menu.removal.voxel));

        // uniforms
        try gl.uniform2f(
            resLoc,
            @floatFromInt(framebuffer_width),
            @floatFromInt(framebuffer_height),
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

        try menu.draw(@floatFromInt(window_width), @floatFromInt(window_height), @floatCast(x), @floatCast(y), &registry, &icons);
        c.glfwSwapBuffers(window);

        if (controls.screenshot) {
            gl_utils.saveScreenshot(framebuffer_width, framebuffer_height) catch {};
        }
        fps_counter.update();
    }
}

fn glString(name: c_uint) []const u8 {
    const value = c.glGetString(name);
    return if (value == null) "unavailable" else std.mem.span(value);
}

/// Temporary adapters consume routed test-target events for the existing camera
/// and tools. No real entity/world target is resolved from the placeholder IDs.
/// Device details never cross this boundary; held state survives queue draining.
const DeveloperControls = struct {
    menu: *Menu,
    width: f32 = 0,
    height: f32 = 0,
    block_count: usize = 0,
    held: [input.t.action_count]bool = .{false} ** input.t.action_count,
    pressed: [input.t.action_count]bool = .{false} ** input.t.action_count,
    look: [2]f32 = .{ 0, 0 },
    quit: bool = false,
    screenshot: bool = false,
    toggle_fps: bool = false,
    reset_edit: bool = false,

    fn begin(self: *DeveloperControls) void {
        self.pressed = .{false} ** input.t.action_count;
        self.look = .{ 0, 0 };
        self.screenshot = false;
        self.toggle_fps = false;
        self.reset_edit = false;
    }
    fn down(self: *const DeveloperControls, action: input.t.Action) bool {
        return self.held[@intFromEnum(action)];
    }
    fn axis(self: *const DeveloperControls, positive: input.t.Action, negative: input.t.Action) f32 {
        return @as(f32, if (self.down(positive)) 1 else 0) - @as(f32, if (self.down(negative)) 1 else 0);
    }
    pub fn handle(self: *DeveloperControls, comptime name: []const u8, event: input.Output) !void {
        _ = name;
        switch (event) {
            .action => |action| {
                const i = @intFromEnum(action.action);
                switch (action.phase) {
                    .started => {
                        self.held[i] = true;
                        self.pressed[i] = true;
                    },
                    .ended => self.held[i] = false,
                    .cancelled => {
                        self.held[i] = false;
                        self.pressed[i] = false;
                    },
                    .changed => {},
                }
                if (action.action == .look) {
                    if (action.phase == .cancelled) {
                        self.look = .{ 0, 0 };
                        self.pressed[@intFromEnum(input.t.Action.remove)] = false;
                        self.pressed[@intFromEnum(input.t.Action.place)] = false;
                        self.reset_edit = true;
                    } else {
                        self.look[0] += action.value[0];
                        self.look[1] += action.value[1];
                    }
                }
                if (action.action == .toggle_menu and action.phase == .changed) {
                    self.menu.open = action.value[0] != 0;
                    self.reset_edit = true;
                }
                if (action.phase != .started) return;
                switch (action.action) {
                    .back => self.quit = true,
                    .toggle_removal => {
                        self.menu.removal.voxel = !self.menu.removal.voxel;
                        self.reset_edit = true;
                    },
                    .activate => self.menu.click(self.width, self.height, action.value[0], action.value[1], self.block_count),
                    .deselect => self.menu.selected = null,
                    .screenshot => self.screenshot = true,
                    .toggle_fps => self.toggle_fps = !self.toggle_fps,
                    else => {},
                }
            },
            // Settings can consume these responses here when its UI is added.
            // Queue dumping remains available through EventSystem.printCurrent.
            .command_result, .bindings_snapshot, .rebind_candidate => {},
        }
    }
};
