const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const gpu_profile = @import("graphics/gpuProfile.zig");
const lighting = @import("lighting.zig");
const capture = @import("profileCapture.zig");
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
const CameraSystem = @import("core/camera/cameraSystem.zig").CameraSystem;

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
    var profile: gpu_profile.Profile = .auto;
    var gpu_info = false;
    var terrain_mode = true;
    var terrain_stats = false;
    var incremental_uploads = true;
    var gpu_stats = false;
    var cpu_stats = false;
    var profile_csv: ?[]const u8 = null;
    var lighting_mode = lighting.mode;
    var assets: []const u8 = "assets/blocks";
    var input_profile_path: ?[]const u8 = null;
    var benchmark = capture.Options{};
    for (args[1..]) |arg| {
        if (try benchmark.parse(arg)) continue;
        if (std.mem.startsWith(u8, arg, "--shader=")) {
            profile = try gpu_profile.Profile.parse(arg[9..]);
        } else if (std.mem.startsWith(u8, arg, "--lighting=")) {
            lighting_mode = if (std.mem.eql(u8, arg[11..], "face")) .legacy else if (std.mem.eql(u8, arg[11..], "direct")) .direct else return error.InvalidLightingMode;
        } else if (std.mem.startsWith(u8, arg, "--assets=")) {
            assets = arg[9..];
            if (assets.len == 0) return error.MissingAssetDirectory;
        } else if (std.mem.startsWith(u8, arg, "--input-profile=")) {
            input_profile_path = arg[16..];
            if (input_profile_path.?.len == 0) return error.MissingInputProfile;
        } else if (std.mem.eql(u8, arg, "--uploads=incremental")) {
            incremental_uploads = true;
        } else if (std.mem.eql(u8, arg, "--uploads=snapshot")) {
            incremental_uploads = false;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            cpu_stats = true;
            gpu_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--profile-csv=")) {
            profile_csv = arg[14..];
            if (profile_csv.?.len == 0) return error.MissingProfileCsvPath;
            cpu_stats = true;
            gpu_stats = true;
        } else if (std.mem.eql(u8, arg, "--gpu-stats")) {
            gpu_stats = true;
        } else if (std.mem.eql(u8, arg, "--terrain-stats")) {
            terrain_stats = true;
        } else if (std.mem.eql(u8, arg, "--world=terrain")) {
            terrain_mode = true;
        } else if (std.mem.eql(u8, arg, "--world=test-scene")) {
            terrain_mode = false;
        } else if (std.mem.eql(u8, arg, "--gpu-info")) {
            gpu_info = true;
        } else {
            std.debug.print("Usage: voxel [--world=terrain|test-scene] [--lighting=face|direct] [--terrain-stats] [--gpu-stats] [--profile] [--profile-csv=file.csv] [--uploads=incremental|snapshot] [--shader=auto|thinkpad|desktop|rtx3060|vega56|vega] [--gpu-info] [--assets=directory] [--input-profile=file.json] [--benchmark-frames=N] [--benchmark-visible] [--benchmark-warmup=N] [--benchmark-settle=N] [--benchmark-max-frames=N] [--camera=x,y,z] [--camera-angles=yaw,pitch] [--framebuffer=WxH] [--swap-interval=0|1] [--direct-diagnostics=power-of-two-stride]\n", .{});
            return error.UnknownArgument;
        }
    }

    if (benchmark.frames > 0 or benchmark.diagnostic_stride > 0) {
        cpu_stats = true;
        gpu_stats = true;
        if (profile_csv == null) {
            try std.fs.cwd().makePath("logs");
            profile_csv = "logs/benchmark.csv";
        }
    }
    if (benchmark.frames > 0 and @as(u64, benchmark.frames) + benchmark.warmup + benchmark.settle >= benchmark.max_frames) return error.BenchmarkFrameLimitTooSmall;

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInitFailed;
    defer c.glfwTerminate();

    // Request the desktop context first, retaining the existing GLSL 4.20 baseline.
    c.glfwWindowHint(c.GLFW_OPENGL_PROFILE, c.GLFW_OPENGL_CORE_PROFILE);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MAJOR, 4);
    c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 6);
    if (gpu_info or (benchmark.frames > 0 and !benchmark.visible)) c.glfwWindowHint(c.GLFW_VISIBLE, c.GLFW_FALSE);
    if (benchmark.frames > 0) c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_FALSE);
    const requested_size = benchmark.size orelse [2]u32{ @intFromFloat(res[0]), @intFromFloat(res[1]) };
    const window = c.glfwCreateWindow(@intCast(requested_size[0]), @intCast(requested_size[1]), "Voxel Renderer in zig", null, null) orelse fallback: {
        c.glfwWindowHint(c.GLFW_CONTEXT_VERSION_MINOR, 2);
        break :fallback c.glfwCreateWindow(@intCast(requested_size[0]), @intCast(requested_size[1]), "Voxel Renderer in zig", null, null) orelse {
            std.debug.print("Unable to create an OpenGL 4.2+ context required by the current shaders.\n", .{});
            return error.OpenGLContextUnavailable;
        };
    };
    defer c.glfwDestroyWindow(window);
    c.glfwMakeContextCurrent(window);
    if (benchmark.swap_interval) |interval| c.glfwSwapInterval(interval);
    // GLFW window dimensions can differ from framebuffer pixels on scaled displays.
    if (benchmark.size) |size| {
        var fw: c_int = 0;
        var fh: c_int = 0;
        c.glfwGetFramebufferSize(window, &fw, &fh);
        if (fw <= 0 or fh <= 0) return error.InvalidFramebuffer;
        if (fw != size[0] or fh != size[1]) {
            c.glfwSetWindowSize(window, @intCast(@as(u64, size[0]) * size[0] / @as(u32, @intCast(fw))), @intCast(@as(u64, size[1]) * size[1] / @as(u32, @intCast(fh))));
            c.glfwPollEvents();
        }
    }
    c.glewExperimental = c.GL_TRUE;
    if (c.glewInit() != c.GLEW_OK) return error.GlewInitFailed;

    const renderer = glString(c.GL_RENDERER);
    const vendor = glString(c.GL_VENDOR);
    std.debug.print("GPU: {s}\nVendor: {s}\nOpenGL: {s}\nGLSL: {s}\n", .{
        renderer, vendor, glString(c.GL_VERSION), glString(c.GL_SHADING_LANGUAGE_VERSION),
    });
    var major: c_int = 0;
    var minor: c_int = 0;
    c.glGetIntegerv(c.GL_MAJOR_VERSION, &major);
    c.glGetIntegerv(c.GL_MINOR_VERSION, &minor);
    const selected = gpu_profile.select(profile, vendor, renderer, major, minor) catch |err| {
        std.debug.print("Shader profile {s} is unsupported by OpenGL {d}.{d}; desktop/device profiles require 4.6. The thinkpad compatibility profile requires 4.2.\n", .{ @tagName(profile), major, minor });
        return err;
    };
    const shader_path = selected.profile.shaderPath();
    std.debug.print("Terrain edit empty-group skipping: {}\n", .{@import("build_options").terrain_overlay_skips});
    std.debug.print("World header fetches: {s}\n", .{if (@import("graphics/worldBufferLayout.zig").vector_headers) "vector (RGBA32UI experiment)" else "scalar (R32UI baseline)"});
    std.debug.print("Detected device: {s}\nShader profile: {s} ({s})\n", .{ selected.device.label(), @tagName(selected.profile), shader_path });
    if (selected.compatibility_fallback) std.debug.print("Using OpenGL 4.2 compatibility shaders because this context does not support 4.6.\n", .{});
    const lighting_features = lighting.featuresForMode(lighting_mode);
    std.debug.print("Build: {s}; lighting: {s}\n", .{ @tagName(@import("builtin").mode), @tagName(lighting_mode) });
    const program = try gl_utils.createDiagnosticProgram(shader_path, lighting_features, lighting.sky_extra_ray_count, benchmark.diagnostic_stride > 0);
    defer gl.deleteProgram(program);
    if (gpu_info) return;

    const diagnostic_path = if (profile_csv) |p| try std.fmt.allocPrint(allocator, "{s}.diagnostics.csv", .{p}) else null;
    defer if (diagnostic_path) |p| allocator.free(p);
    var diagnostics = try @import("graphics/directDiagnostics.zig").Diagnostics.init(program, benchmark.diagnostic_stride, diagnostic_path);
    defer diagnostics.deinit();

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
    var cam_pos = benchmark.position orelse [3]f32{ 100, 30, 100 };
    var yaw: f32 = benchmark.angles[0];
    var pitch: f32 = benchmark.angles[1];

    // world
    var world = try World.init(allocator);
    defer world.deinit() catch |err| {
        std.debug.print("{}", .{err});
    };
    world.incremental_uploads = incremental_uploads;
    var timings = try @import("graphics/frameTimings.zig").Timings.init(.{
        .cpu = cpu_stats,
        .gpu = gpu_stats,
        .csv_path = profile_csv,
    });
    defer timings.deinit();
    if (cpu_stats or gpu_stats) std.debug.print("Profiling: CPU wall={}, GPU passes={}, 120-sample summaries; swap measured separately. lighting_cache is a publication barrier; lighting evaluation is in world.\n", .{ cpu_stats, timings.options.gpu });
    world.upload_budget_bytes = @import("rendering.zig").upload_bytes_per_frame;
    if (lighting_features.point_lights) {
        try world.scene_lights.append(.{ .position = .{ cam_pos[0], cam_pos[1] + lighting.sun_height, cam_pos[2] }, .color = lighting.sun_color, .intensity = lighting.sun_intensity, .radius = lighting.sun_radius });
        std.debug.print("Lighting: above-spawn light at {any}, radius {d}; budget {d} lights, {d} sky rays\n", .{ world.scene_lights.items[0].position, lighting.sun_radius, lighting.max_lights, lighting.sky_extra_ray_count + 1 });
    }
    var lighting_cache = try @import("graphics/lightingCache.zig").Cache.init(program);
    defer lighting_cache.deinit();
    lighting_cache.population_budget = @import("rendering.zig").lighting_cache_entries_per_frame;
    var gi_cache = try @import("graphics/globalIllumination.zig").Cache.init(program, lighting_features, lighting.sky_extra_ray_count);
    defer gi_cache.deinit();
    var light_uniforms = @import("graphics/pointLights.zig").Uniforms.init(program);
    var render_policy = @import("graphics/renderPolicy.zig").Uniforms.init(program);
    if (terrain_mode) try world.enableTerrain(.{}) else try @import("world/startupBuilding.zig").place(&world);
    var focus_state = @import("rendering.zig").FocusState{};
    const geometry_settings = if (terrain_mode) @import("rendering.zig").terrain_settings else @import("rendering.zig").Settings{};
    var spawn_ready = !terrain_mode or benchmark.position != null;
    const spawn_position = cam_pos;
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
    var camera_system = CameraSystem.init(allocator);
    defer camera_system.deinit();
    var input_backend = InputBackend{ .window = @ptrCast(window) };
    input_backend.attach();
    defer input_backend.detach();
    var controls = DeveloperControls{ .menu = &menu };
    var frame: u64 = 0;
    var reported_terrain_revision: u64 = 0;
    var frame_timer = try std.time.Timer.start();
    var edit_cooldown = EditCooldown{};

    var capture_run = capture.Run{ .options = benchmark };
    const metadata_path = if (profile_csv) |p| try std.fmt.allocPrint(allocator, "{s}.meta.json", .{p}) else null;
    defer if (metadata_path) |p| allocator.free(p);
    const frames_path = if (profile_csv) |p| try std.fmt.allocPrint(allocator, "{s}.frames.csv", .{p}) else null;
    defer if (frames_path) |p| allocator.free(p);
    var frame_log: ?capture.FrameLog = if (frames_path) |p| try capture.FrameLog.init(p) else null;
    defer if (frame_log) |*log| log.deinit();
    const runtime_id = if (profile_csv != null) try @import("sourceIdentity.zig").fingerprint(allocator) else [_]u8{'0'} ** 64;
    const assets_id = if (profile_csv != null) try @import("sourceIdentity.zig").assets(allocator, assets) else [_]u8{'0'} ** 64;
    var actual_width: c_int = 0;
    var actual_height: c_int = 0;
    c.glfwGetFramebufferSize(window, &actual_width, &actual_height);
    const metadata = .{
        .framebuffer = .{ actual_width, actual_height },
        .window_visible = benchmark.frames == 0 or benchmark.visible,
        .version = 1,
        .build_source_sha256 = @import("build_options").source_id,
        .runtime_source_sha256 = runtime_id[0..],
        .identity_scope = "Sorted source, build files, libs and assets/blocks contents, including dirty/untracked files; generated icons excluded",
        .build_mode = @tagName(@import("builtin").mode),
        .zig_version = @import("build_options").zig_version,
        .vendor = vendor,
        .gpu = renderer,
        .driver = glString(c.GL_VERSION),
        .glsl = glString(c.GL_SHADING_LANGUAGE_VERSION),
        .shader = @tagName(selected.profile),
        .shader_path = shader_path,
        .vector_world_headers = @import("build_options").vector_world_headers,
        .terrain_overlay_skips = @import("build_options").terrain_overlay_skips,
        .lighting = @tagName(lighting_mode),
        .lighting_features = lighting_features,
        .sky_extra_rays = lighting.sky_extra_ray_count,
        .cache_entries = lighting.face_cache_entries,
        .cache_population_budget = lighting_cache.population_budget,
        .world = if (terrain_mode) @as([]const u8, "terrain") else "test-scene",
        .assets = assets,
        .assets_sha256 = assets_id[0..],
        .terrain_config = @import("world/generation/terrainGenerator.zig").Config{},
        .terrain_profile_version = @import("world/generation/terrainGenerator.zig").profile_version,
        .geometry_settings = geometry_settings,
        .uploads = if (incremental_uploads) @as([]const u8, "incremental") else "snapshot",
        .upload_budget_bytes = @import("rendering.zig").upload_bytes_per_frame,
        .benchmark = benchmark,
        .requested_swap_interval = benchmark.swap_interval,
        .gpu_timing_enabled = timings.options.gpu,
        .timing_notes = "cpu,total is instrumented stages; cadence,frame_interval includes profiler/log overhead, attributed to its originating frame. lighting_cache is publication barrier, direct evaluation is world. Diagnostic runs include instrumentation overhead.",
    };
    if (metadata_path) |p| try capture.writeJson(p, .{ .configuration = metadata, .result = @as(?u8, null) });
    defer if (metadata_path) |p| {
        timings.collect();
        diagnostics.collect() catch {};
        capture.writeJson(p, .{ .configuration = metadata, .result = .{
            .complete = capture_run.complete(),
            .run = capture_run,
            .rendered_frame = frame,
            .camera = cam_pos,
            .angles = .{ yaw, pitch },
            .geometry_revision = world.gpu_revision,
            .light_revision = light_uniforms.revision,
            .scene_lights = world.scene_lights.items,
            .block_light_count = world.block_lights.items.len,
            .gpu_skipped = timings.skipped_gpu,
            .gpu_pending = timings.pendingCount(),
            .diagnostic_skipped = diagnostics.skipped,
            .diagnostic_pending = diagnostics.pendingCount(),
            .gpu_allocated_bytes = world.gpuAllocatedBytes(),
        } }) catch |err| std.debug.print("Capture metadata failed: {s}\n", .{@errorName(err)});
    };

    gl.useProgram(program);

    var fps_counter = try fps.FpsCounter.init();
    defer fps_counter.deinit();

    while (c.glfwWindowShouldClose(window) == 0) {
        if (benchmark.frames > 0 and frame >= benchmark.max_frames) return error.BenchmarkDidNotSettle;
        frame_timer.reset();
        frame += 1;
        timings.begin(frame);
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
        if (gpu_stats and frame == 1) std.debug.print("Framebuffer: {d}x{d}\n", .{ framebuffer_width, framebuffer_height });
        controls.width = @floatFromInt(window_width);
        controls.height = @floatFromInt(window_height);
        controls.block_count = registry.blocks.items.len;
        try input.routing.drainForDeveloperTools(event_bus, &controls);
        _ = try camera_system.processCurrent(event_bus);
        event_bus.clearCurrent();
        // Retire the current frame; next/debt buffers remain intact.
        if (controls.quit) break;
        if (controls.toggle_fps) fps_counter.toggle();
        if (controls.reset_edit) edit_cooldown.armed = false;
        if (framebuffer_width == 0 or framebuffer_height == 0) {
            c.glfwWaitEventsTimeout(0.05);
            continue;
        }
        if (benchmark.frames > 0 and (framebuffer_width != actual_width or framebuffer_height != actual_height)) return error.FramebufferSizeMismatch;
        const left = benchmark.frames == 0 and (controls.down(.remove) or controls.pressed[@intFromEnum(input.t.Action.remove)]);
        const right_mouse = benchmark.frames == 0 and (controls.down(.place) or controls.pressed[@intFromEnum(input.t.Action.place)]);
        const x = input_system.pointer[0];
        const y = input_system.pointer[1];
        if (benchmark.frames == 0) {
            yaw -= controls.look[0] * LOOK_SPEED;
            pitch -= controls.look[1] * LOOK_SPEED;
        } else menu.open = false;
        if (benchmark.size) |size| {
            if (framebuffer_width != size[0] or framebuffer_height != size[1]) return error.FramebufferSizeMismatch;
        }

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
        if (benchmark.frames == 0) {
            for (0..3) |axis| cam_pos[axis] += forward[axis] * forward_amount * MOVE_SPEED;
            cam_pos[0] += right[0] * right_amount * MOVE_SPEED;
            cam_pos[2] += right[2] * right_amount * MOVE_SPEED;
            cam_pos[1] += controls.axis(.up, .down) * MOVE_SPEED;
        }

        gl.useProgram(program);
        c.glViewport(0, 0, framebuffer_width, framebuffer_height);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        gl.uniform1i(chunkHeaderTexLoc, 0);
        gl.uniform1i(blockHeaderTexLoc, 1);
        gl.uniform1i(voxelBlockHeaderTexLoc, 2);
        gl.uniform1i(bitmapTexLoc, 3);
        gl.uniform1i(paletteTexLoc, 4);
        gl.uniform1i(indexTexLoc, 5);

        if (!spawn_ready) {
            cam_pos = spawn_position;
        }
        timings.cpuEnd(.input);
        const policy_snapshot = try focus_state.resolve(geometry_settings, cam_pos);
        world.updateTerrain(policy_snapshot, cam_pos);
        // Both the ordinary update and an edit-triggered update share this
        // frame's upload allowance.
        world.upload_budget_bytes = @import("rendering.zig").upload_bytes_per_frame;
        world.generation_budget = @import("rendering.zig").generation_chunks_per_frame;
        try world.render(cam_pos);
        if (!spawn_ready) {
            if (world.terrainSpawnHeight(@intFromFloat(@floor(cam_pos[0])), @intFromFloat(@floor(cam_pos[2])))) |height| {
                cam_pos[1] = @as(f32, @floatFromInt(height)) + 32;
                spawn_ready = true;
                if (world.scene_lights.items.len > 0) world.scene_lights.items[0].position[1] = cam_pos[1] + lighting.sun_height;
            }
        }
        world.generation_budget = 0;
        world.upload_budget_bytes -= world.last_upload_bytes;
        timings.cpuEnd(.streaming);
        if (spawn_ready and edit_cooldown.update(c.glfwGetTime(), menu.open, left, right_mouse)) {
            if (world.raycast(cam_pos, forward, 256)) |hit| {
                if (left) {
                    if (menu.removal.voxel) {
                        if (world.terrainBlockReady(hit.blockCoord())) _ = world.removeVoxel(hit.voxel) catch |err| deferred: {
                            try reportDeferredEdit(err);
                            break :deferred false;
                        };
                    } else {
                        const empty = Block.initEmpty(0);
                        if (world.terrainBlockReady(hit.blockCoord())) world.setBlock(hit.blockCoord(), &empty) catch |err| try reportDeferredEdit(err);
                    }
                } else if (right_mouse and menu.selected != null and !std.mem.eql(i32, &hit.normal, &.{ 0, 0, 0 })) {
                    const dest = hit.adjacentBlock();
                    var contains_camera = true;
                    for (0..3) |axis| {
                        if (@as(i32, @intFromFloat(@floor(cam_pos[axis] / wc.BLOCK_VOXEL_CNT))) != dest[axis]) contains_camera = false;
                    }
                    if (!contains_camera and world.blockIsEmpty(dest)) {
                        const definition = &registry.blocks.items[menu.selected.?];
                        const orientation = @import("world/blockRotation.zig").forPlacement(definition.rotation, forward, yaw);
                        world.setBlockOriented(dest, &definition.model, orientation) catch |err| try reportDeferredEdit(err);
                    }
                }
                try world.render(cam_pos);
            }
        }
        timings.cpuEnd(.editing);
        world.bindGpuTextures();
        try render_policy.uploadSnapshot(&policy_snapshot);
        if (terrain_stats and terrain_mode and reported_terrain_revision != world.gpu_revision) {
            if (world.terrain_stream.?.resident) |batch| {
                std.debug.print("Terrain revision={d} frame_cpu_ms={d:.2} worker_ms={d:.2} queue_ms={d:.2} reused={d}/{d} requested={any} new_noise={any} hits={d} cache_bytes={d} payload_bytes={d} upload_bytes={d} cpu_staging_bytes={d} gpu_allocated_bytes={d}\n", .{
                    world.gpu_revision,                                           @as(f64, @floatFromInt(frame_timer.read())) / std.time.ns_per_ms,
                    @as(f64, @floatFromInt(batch.build_ns)) / std.time.ns_per_ms, @as(f64, @floatFromInt(batch.queue_ns)) / std.time.ns_per_ms,
                    batch.reused_tiles,                                           batch.tiles.len,
                    batch.stats.outputs_by_level,                                 batch.stats.generated,
                    batch.stats.hits,                                             batch.cache_bytes,
                    batch.bytes,                                                  world.last_upload_bytes,
                    world.cpuSnapshotAllocatedBytes(),                            world.gpuAllocatedBytes(),
                });
            }
            if (world.gpu_residency) |*resident| {
                const stats = resident.last_stats;
                std.debug.print("GPU residency new_tiles={d} reused_tiles={d} payload_uploaded={d} metadata_uploaded={d} reused_bytes={d} retired_bytes={d} pack_ms={d:.3} submit_ms={d:.3}\n", .{
                    stats.new_tiles,         stats.reused_tiles,                                  stats.payload_bytes,                                        stats.metadata_bytes, stats.reused_bytes,
                    resident.retiredBytes(), @as(f64, @floatFromInt(world.last_commit_ns)) / 1e6, @as(f64, @floatFromInt(world.last_upload_submit_ns)) / 1e6,
                });
            }
            reported_terrain_revision = world.gpu_revision;
        }
        light_uniforms.upload(world.scene_lights.items, world.block_lights.items, cam_pos);

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

        // Reuse face lighting across frames; publish misses after the draw.
        timings.gpuBegin(.prepare);
        try lighting_cache.begin(world.gpu_revision, light_uniforms.revision);
        try gi_cache.begin(&world);
        try diagnostics.begin(.{ .frame = frame, .geometry = world.gpu_revision, .lights = light_uniforms.revision, .cache_frame = lighting_cache.clock.frame, .valid_from = lighting_cache.clock.valid_from });
        timings.gpuEnd(.prepare);
        timings.cpuEnd(.prepare);

        timings.gpuBegin(.world);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        timings.gpuEnd(.world);
        timings.cpuEnd(.world);

        timings.gpuBegin(.lighting_cache);
        lighting_cache.end();
        try diagnostics.end();
        timings.gpuEnd(.lighting_cache);
        timings.cpuEnd(.lighting_cache);

        timings.gpuBegin(.gi);
        gi_cache.update();
        timings.gpuEnd(.gi);
        timings.cpuEnd(.gi);

        timings.gpuBegin(.menu);
        try menu.draw(@floatFromInt(window_width), @floatFromInt(window_height), @floatCast(x), @floatCast(y), &registry, &icons);
        timings.gpuEnd(.menu);
        timings.gpuSubmit();
        timings.cpuEnd(.menu);

        c.glfwSwapBuffers(window);
        timings.cpuEnd(.swap);

        if (controls.screenshot) {
            gl_utils.saveScreenshot(framebuffer_width, framebuffer_height) catch {};
        }
        fps_counter.update();
        timings.end();
        const ready = if (profile_csv != null) world.captureReady() else false;
        const phase = capture_run.advance(frame, ready, world.gpu_revision, light_uniforms.revision);
        if (frame_log) |*log| try log.writer.writer().print("{d},{s},{d},{d},{d},{d},{},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            frame,                      @tagName(phase),                 world.gpu_revision,      light_uniforms.revision,
            lighting_cache.clock.frame, lighting_cache.clock.valid_from, ready,                   cam_pos[0],
            cam_pos[1],                 cam_pos[2],                      yaw,                     pitch,
            framebuffer_width,          framebuffer_height,              world.last_upload_bytes, world.gpuAllocatedBytes(),
        });
        if (capture_run.invalid) return error.BenchmarkGeometryChanged;
        if (capture_run.complete()) break;
    }
    timings.closeInterval();
    if (benchmark.frames > 0 and !capture_run.complete()) return error.BenchmarkInterrupted;
    if (benchmark.frames > 0) {
        // Drain only at controlled exit, outside measured work. Collection itself
        // remains nonblocking; preserve/report anything still pending at timeout.
        c.glFlush();
        var drain_timer = try std.time.Timer.start();
        while (timings.pendingCount() + diagnostics.pendingCount() > 0 and drain_timer.read() < 2 * std.time.ns_per_s) {
            timings.collect();
            try diagnostics.collect();
            if (timings.pendingCount() + diagnostics.pendingCount() > 0) std.Thread.sleep(std.time.ns_per_ms);
        }
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

fn reportDeferredEdit(err: anyerror) !void {
    switch (err) {
        error.TerrainUnavailable => std.debug.print("Edit deferred: exact terrain is still generating.\n", .{}),
        error.EditBudgetExceeded => std.debug.print("Edit deferred: unsaved edit memory budget is full.\n", .{}),
        else => return err,
    }
}
