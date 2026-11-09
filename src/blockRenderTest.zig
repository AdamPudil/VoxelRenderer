//! Headless integration check. Uses Mesa/EGL; writes previews under /tmp/voxel-block-smoke.
const std = @import("std");
const gl = @import("graphics/gl.zig");
const gl_utils = @import("graphics/gl_utils.zig");
const Registry = @import("world/blockRegistry.zig").BlockRegistry;
const Icons = @import("graphics/blockIcons.zig").Icons;
const LightingCache = @import("graphics/lightingCache.zig").Cache;
const LightUniforms = @import("graphics/pointLights.zig").Uniforms;
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

    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--profile-only")) {
        try @import("profilingRenderChecks.zig").run();
        return;
    }
    try @import("hierarchyRenderChecks.zig").runLightingRings(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--lighting-rings-only")) return;
    try @import("hierarchyRenderChecks.zig").run(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--hierarchy-only")) return;
    try @import("giRenderChecks.zig").run(a);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--gi-only")) return;
    try checkFlatLighting(a);
    try checkSkyWeights(a);
    const folder = "/tmp/voxel-block-smoke";
    try @import("world/testBlocks.zig").ensure(a, folder);
    var registry = try Registry.loadDirectory(a, folder);
    defer registry.deinit();
    for ([_][]const u8{ "src/graphics/shaders/voxel", "src/graphics/shaders/desktop/voxel" }) |path| {
        // Compile/link all eight variants on both supported GLSL profiles.
        for (0..8) |mask| {
            const variant = try gl_utils.createLightingProgram(path, .{ .face_shading = mask & 1 != 0, .point_lights = mask & 2 != 0, .sky_lighting = mask & 4 != 0 }, 8);
            defer gl.deleteProgram(variant);
            if (mask & 2 == 0 and gl.getUniformLocation(variant, "uLightCount") != -1) return error.DisabledLightResourcePresent;
            if (mask & 6 == 0 and gl.getUniformLocation(variant, "uLightingCacheFrame") != -1) return error.DisabledCacheResourcePresent;
        }
        try checkLighting(a, path, &registry);
        try checkLedSticks(a, path, &registry);
        try checkLightingCache(a, path);
        try checkDaylightBalance(a, path);
        // Existing optical baselines describe the legacy face-only renderer.
        const program = try gl_utils.createLightingProgram(path, .{ .face_shading = true, .point_lights = false, .sky_lighting = false }, 0);
        defer gl.deleteProgram(program);
        try checkBlockRotation(a, program);
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
        try checkGlass(a, program, &registry);
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
    return cachedScenePixel(world, program, eye, direction, null, null);
}

fn checkBlockRotation(a: std.mem.Allocator, program: c_uint) !void {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const rotation = @import("world/blockRotation.zig");
    var world = try World.init(a);
    defer world.deinit() catch {};
    var model = try Block.initVoxel(a, 42);
    defer model.deinit(a);
    var green = Voxel.rgb(0, 255, 0);
    green.luminescence = 255;
    model.blockData.voxel.setPaletteEntry(1, green);
    model.blockData.voxel.setPaletteEntry(2, Voxel.rgb(255, 0, 0));
    model.blockData.voxel.setVoxel(1, 2, 3, 1);
    model.blockData.voxel.setVoxel(4, 5, 6, 2);
    model.light = .{ .position = .{ 1.5, 2.5, 3.5 } };
    const views = [_][3]f32{ .{ 0, 0, -1 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 } };
    const targets = [_][3]i32{ .{ 1, 98, 3 }, .{ 3, 98, 14 }, .{ 14, 98, 12 }, .{ 12, 98, 1 } };
    for (views, targets) |view, target| {
        try world.setBlockOriented(.{ 0, 6, 0 }, &model, rotation.forPlacement(.yaw, view, 0));
        const center = [3]f32{ @as(f32, @floatFromInt(target[0])) + 0.5, @as(f32, @floatFromInt(target[1])) + 0.5, @as(f32, @floatFromInt(target[2])) + 0.5 };
        var eye = center;
        eye[2] += 4;
        const pixel = try scenePixel(&world, program, eye, .{ 0, 0, -1 });
        if (pixel[1] < 180 or pixel[0] > 2 or pixel[2] > 2) return error.RotatedVoxelNotRendered;
        if (world.block_lights.items.len != 1 or !std.mem.eql(f32, &center, &world.block_lights.items[0].position)) return error.RotatedLightPosition;
        const hit = world.raycast(eye, .{ 0, 0, -1 }, 8) orelse return error.RotatedVoxelNotPickable;
        if (!std.mem.eql(i32, &hit.voxel, &target)) return error.RotatedPickMismatch;
        // Moving the GPU region must preserve the owned orientation and light.
        try world.render(.{ 8192, 98, 8192 });
        if (world.block_lights.items.len != 0) return error.RotatedLightStayedInRegion;
        const returned = try scenePixel(&world, program, eye, .{ 0, 0, -1 });
        if (!std.mem.eql(u8, &pixel, &returned) or world.block_lights.items.len != 1) return error.RotatedBlockLostOnReentry;
        if (!try world.removeVoxel(target)) return error.RotatedVoxelNotRemovable;
        const removed = try scenePixel(&world, program, eye, .{ 0, 0, -1 });
        if (std.mem.eql(u8, &pixel, &removed) or world.block_lights.items.len != 0) return error.RotatedRemovalNotRendered;
    }
    std.debug.print("Four placement rotations: GPU geometry, picking, lights, reentry and removal passed.\n", .{});
}

fn cachedScenePixel(world: *@import("world/world.zig").World, program: c_uint, eye: [3]f32, direction: [3]f32, cache: ?*LightingCache, light_uniforms: ?*LightUniforms) ![4]u8 {
    const wc = @import("world/worldConstants.zig");
    try world.render(eye);
    world.bindGpuTextures();
    gl.useProgram(program);
    var lights = @import("graphics/pointLights.zig").Uniforms.init(program);
    const uniforms = light_uniforms orelse &lights;
    uniforms.upload(world.scene_lights.items, world.block_lights.items, eye);
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
    if (cache) |active| try active.begin(world.gpu_revision, uniforms.revision);
    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    if (cache) |active| active.end();
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

fn glassPixel(a: std.mem.Allocator, program: c_uint, front: *const @import("world/block.zig").Block, back: ?*const @import("world/block.zig").Block) ![4]u8 {
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    var world = try @import("world/world.zig").World.init(a);
    defer world.deinit() catch {};
    try world.setBlock(.{ 0, 6, 0 }, front);
    if (back) |model| try world.setBlock(.{ 0, 6, -1 }, model);
    var target = Voxel.rgb(180, 180, 180);
    target.luminescence = 255;
    const backdrop = Block.initMono(0, target);
    try world.setBlock(.{ 0, 6, -3 }, &backdrop);
    return scenePixel(&world, program, .{ 8, 104, 48 }, .{ 0, 0, -1 });
}

fn checkGlass(a: std.mem.Allocator, program: c_uint, registry: *const Registry) !void {
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const World = @import("world/world.zig").World;
    const clear = &registry.blocks.items[registry.find("Glass White", 0).?].model;
    const sanded = &registry.blocks.items[registry.find("Sanded Glass White", 0).?].model;
    const red = &registry.blocks.items[registry.find("Glass Red", 0).?].model;
    const green = &registry.blocks.items[registry.find("Glass Green", 0).?].model;
    const blue = &registry.blocks.items[registry.find("Glass Blue", 0).?].model;
    const clear_pixel = try glassPixel(a, program, clear, null);
    const sanded_pixel = try glassPixel(a, program, sanded, null);
    const red_pixel = try glassPixel(a, program, red, null);
    const green_pixel = try glassPixel(a, program, green, null);
    const blue_pixel = try glassPixel(a, program, blue, null);
    const mixed = try glassPixel(a, program, red, green);
    std.debug.print("Glass clear={any} sanded={any} red={any} green={any} blue={any} mixed={any}\n", .{ clear_pixel, sanded_pixel, red_pixel, green_pixel, blue_pixel, mixed });
    if (clear_pixel[1] < 180 or clear_pixel[3] != 255) return error.GlassDoesNotTransmit;
    if (@as(u16, sanded_pixel[1]) + 20 >= clear_pixel[1]) return error.SandedGlassNotCloudier;
    if (red_pixel[0] < @as(u16, red_pixel[1]) + 60 or green_pixel[1] < @as(u16, green_pixel[0]) + 60 or blue_pixel[2] < @as(u16, blue_pixel[0]) + 60) return error.GlassNotTinted;
    if (mixed[0] >= red_pixel[0] or mixed[1] >= green_pixel[1] or mixed[2] >= @min(red_pixel[2], green_pixel[2])) return error.GlassLayersDoNotMix;

    var world = try World.init(a);
    defer world.deinit() catch {};
    var material = Voxel.rgb(255, 255, 255);
    material.opacity = 0;
    material.refractive_index = Voxel.encodeIor(1);
    var glass = Block.initMono(0, material);
    var red_target = Voxel.rgb(255, 0, 0);
    var green_target = Voxel.rgb(0, 255, 0);
    red_target.luminescence = 255;
    green_target.luminescence = 255;
    const red_block = Block.initMono(0, red_target);
    const green_block = Block.initMono(0, green_target);
    try world.setBlock(.{ 0, 6, 0 }, &glass);
    try world.setBlock(.{ 0, 6, -3 }, &red_block);
    try world.setBlock(.{ 1, 6, -3 }, &green_block);
    const straight = try scenePixel(&world, program, .{ 0, 104, 48 }, .{ 0.205, 0, -1 });
    glass.blockData.mono.refractive_index = Voxel.encodeIor(1.5);
    try world.setBlock(.{ 0, 6, 0 }, &glass);
    const bent = try scenePixel(&world, program, .{ 0, 104, 48 }, .{ 0.205, 0, -1 });
    std.debug.print("Refraction straight={any} bent={any}\n", .{ straight, bent });
    if (straight[1] < @as(u16, straight[0]) + 70 or bent[0] < @as(u16, bent[1]) + 70) return error.RefractionDidNotBendRay;
    // An internal layer with maximal reflectivity must still transmit into its
    // green target. The camera and target are inside glass, avoiding outer faces.
    {
        var internal_world = try World.init(a);
        defer internal_world.deinit() catch {};
        try internal_world.setBlock(.{ 0, 6, 0 }, &glass);
        var second = try clear.clone(a);
        defer second.deinit(a);
        var reflective_glass = glass.blockData.mono;
        reflective_glass.reflectiveness = 255;
        second.blockData.voxel.setPaletteEntry(1, reflective_glass);
        second.blockData.voxel.setPaletteEntry(2, green_target);
        for (0..8) |z| for (0..16) |y| for (0..16) |x| {
            second.blockData.voxel.setVoxel(x, y, z, 2);
        };
        try internal_world.setBlock(.{ 0, 6, -1 }, &second);
        const internal = try scenePixel(&internal_world, program, .{ 8, 104, 8 }, .{ 0, 0, -1 });
        std.debug.print("Glass-to-glass transmission={any}\n", .{internal});
        if (internal[1] < 240 or internal[0] > 5 or internal[2] > 5) return error.InternalGlassBoundaryReflected;
    }
    // Camera inside glass: first hit is a supercritical side exit, then the
    // internally reflected ray leaves the front face toward this green target.
    try world.setBlock(.{ -1, 6, 2 }, &green_block);
    const tir = try scenePixel(&world, program, .{ 15, 104, 8 }, .{ 0.5, 0, 0.8660254 });
    std.debug.print("Total internal reflection={any}\n", .{tir});
    if (tir[1] < 150 or tir[0] > 60) return error.TotalInternalReflectionFailed;
}

fn checkLighting(a: std.mem.Allocator, path: []const u8, registry: *const Registry) !void {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const white = Block.initMono(0, Voxel.rgb(255, 255, 255));
    const empty = Block.initEmpty(0);
    const eye = [3]f32{ 8, 104, 64 };
    const dir = [3]f32{ 0, 0, -1 };
    var world = try World.init(a);
    defer world.deinit() catch {};
    try world.setBlock(.{ 0, 6, 0 }, &white);
    const point = try gl_utils.createLightingProgram(path, .{ .face_shading = false, .point_lights = true, .sky_lighting = false }, 0);
    defer gl.deleteProgram(point);
    try world.scene_lights.append(.{ .position = .{ 40, 104, 40 }, .radius = 128, .intensity = 3 });
    for (0..3) |channel| {
        world.scene_lights.items[0].color = .{ 0, 0, 0 };
        world.scene_lights.items[0].color[channel] = 1;
        const pixel = try scenePixel(&world, point, eye, dir);
        if (pixel[channel] < 100 or pixel[(channel + 1) % 3] > 2 or pixel[(channel + 2) % 3] > 2) return error.PointLightColorFailed;
    }
    try world.setBlock(.{ 1, 6, 1 }, &white);
    const shadow = try scenePixel(&world, point, eye, dir);
    if (shadow[2] > 2) return error.PointShadowFailed;
    var glass_voxel = Voxel.rgb(255, 255, 255);
    glass_voxel.opacity = 128;
    glass_voxel.refractive_index = Voxel.encodeIor(1.5);
    const glass = Block.initMono(0, glass_voxel);
    try world.setBlock(.{ 1, 6, 1 }, &glass);
    const through_glass = try scenePixel(&world, point, eye, dir);
    if (through_glass[2] < 100) return error.TransparentShadowPolicyFailed;
    var sparse = try Block.initVoxel(a, 0);
    defer sparse.deinit(a);
    sparse.blockData.voxel.setPaletteEntry(1, Voxel.rgb(255, 255, 255));
    sparse.blockData.voxel.setVoxel(8, 8, 12, 1);
    try world.setBlock(.{ 1, 6, 1 }, &sparse);
    const voxel_shadow = try scenePixel(&world, point, eye, dir);
    if (voxel_shadow[2] > 2) return error.VoxelShadowFailed;
    _ = try world.removeVoxel(.{ 24, 104, 28 });
    // Geometry past the light must never occlude it.
    try world.setBlock(.{ 3, 6, 2 }, &white);
    const past_light = try scenePixel(&world, point, eye, dir);
    if (past_light[2] < 100) return error.PointDistanceBoundFailed;
    try world.setBlock(.{ 3, 6, 2 }, &empty);
    try world.setBlock(.{ 1, 6, 1 }, &empty);
    world.scene_lights.items[0].radius = 8;
    const outside = try scenePixel(&world, point, eye, dir);
    if (outside[2] > 2) return error.PointRadiusFailed;
    // Actual outward normals and epsilon ownership on every face, including
    // negative chunk/block coordinates and exactly axis-aligned shadow rays.
    try world.setBlock(.{ -2, 6, -2 }, &white);
    for (0..3) |axis| for ([_]f32{ -1, 1 }) |sign| {
        var view = [3]f32{ -24, 104, -24 };
        var direction = [3]f32{ 0, 0, 0 };
        world.scene_lights.items[0] = .{ .position = view, .color = .{ 1, 1, 1 }, .radius = 128 };
        world.scene_lights.items[0].position[axis] += sign * 32;
        view[axis] += sign * 48;
        direction[axis] = -sign;
        const face_pixel = try scenePixel(&world, point, view, direction);
        if (face_pixel[0] < 100) return error.LightingFaceSelfIntersection;
    };
    try world.setBlock(.{ -2, 6, -2 }, &empty);
    world.scene_lights.clearRetainingCapacity();

    for ([_]u32{ 0, 4, 8, 12, 16 }) |extra| {
        const sky = try gl_utils.createLightingProgram(path, .{ .face_shading = false, .point_lights = false, .sky_lighting = true }, extra);
        defer gl.deleteProgram(sky);
        const open = try scenePixel(&world, sky, eye, dir);
        if (open[2] < 80 or open[2] <= open[0]) return error.SkyTintFailed;
        for (0..3) |x| for (0..3) |z| {
            try world.setBlock(.{ @as(i32, @intCast(x)) - 1, 8, @intCast(z) }, &white);
        };
        const covered = try scenePixel(&world, sky, eye, dir);
        if (covered[2] > 2) return error.SkyRoofFailed;
        for (0..3) |x| for (0..3) |z| {
            try world.setBlock(.{ @as(i32, @intCast(x)) - 1, 8, @intCast(z) }, &empty);
        };
        // A narrow roof covers the vertical ray, but cone rays escape around it.
        try world.setBlock(.{ 0, 10, 1 }, &white);
        const edge = try scenePixel(&world, sky, eye, dir);
        if ((extra == 0 and edge[2] > 2) or (extra > 0 and edge[2] < 20)) return error.SkyConeFailed;
        try world.setBlock(.{ 0, 10, 1 }, &empty);
        const underside = try scenePixel(&world, sky, .{ 8, 80, 8 }, .{ 0, 1, 0 });
        if (underside[2] > 2) return error.SkyUndersideFailed;
        std.debug.print("Sky extra={d}: open={any}, roof={any}, edge={any}\n", .{ extra, open, covered, edge });
    }
    const unlit = try gl_utils.createLightingProgram(path, .{ .face_shading = false, .point_lights = false, .sky_lighting = false }, 0);
    defer gl.deleteProgram(unlit);
    const fallback = try scenePixel(&world, unlit, eye, dir);
    if (fallback[0] != 255 or fallback[1] != 255 or fallback[2] != 255) return error.UnlitFallbackFailed;

    const lamp = &registry.blocks.items[registry.find("Sci-Fi Lamp", 0).?].model;
    try world.setBlock(.{ -2, 6, -2 }, lamp);
    try world.render(eye);
    if (world.block_lights.items.len != 1) return error.LampNotRegistered;
    const position = world.block_lights.items[0].position;
    if (@abs(position[0] + 24.5) > 0.001 or @abs(position[1] - 103.5) > 0.001 or @abs(position[2] + 24.5) > 0.001) return error.LampWorldCoordinates;
    try world.setBlock(.{ -2, 6, -2 }, lamp);
    try world.render(eye);
    if (world.block_lights.items.len != 1) return error.DuplicateLamp;
    try world.render(.{ 8192, 104, 8192 });
    if (world.block_lights.items.len != 0) return error.UnloadedLampRetained;
    try world.render(eye);
    if (world.block_lights.items.len != 1) return error.ReloadedLampMissing;
    try world.setBlock(.{ -2, 6, -2 }, &empty);
    try world.render(eye);
    if (world.block_lights.items.len != 0) return error.RemovedLampRetained;

    // Voxel edits retain ownership while an emitter exists, then remove it.
    sparse.light = .{};
    var emitter = Voxel.rgb(90, 220, 255);
    emitter.luminescence = 255;
    sparse.blockData.voxel.setPaletteEntry(2, emitter);
    sparse.blockData.voxel.setVoxel(8, 9, 12, 2);
    try world.setBlock(.{ -2, 6, -2 }, &sparse);
    _ = try world.removeVoxel(.{ -24, 104, -20 });
    try world.render(eye);
    if (world.block_lights.items.len != 1) return error.DamagedLampLostOwnership;
    _ = try world.removeVoxel(.{ -24, 105, -20 });
    try world.render(eye);
    if (world.block_lights.items.len != 0) return error.DestroyedEmitterRetained;

    // Emissive inserts remain visible with no external light; casing stays dark.
    var unpowered = try lamp.clone(a);
    defer unpowered.deinit(a);
    unpowered.light = null;
    try world.setBlock(.{ 0, 6, 0 }, &unpowered);
    const luminous = try scenePixel(&world, point, .{ 7.5, 128, 7.5 }, .{ 0, -1, 0 });
    if (luminous[2] < 180 or luminous[2] <= luminous[0]) return error.LampEmissionFailed;
    const casing = try scenePixel(&world, point, .{ 0.5, 128, 0.5 }, .{ 0, -1, 0 });
    if (casing[2] > 5) return error.LampCasingEmits;
    try world.setBlock(.{ 0, 6, 0 }, lamp);
    // The neighboring face sees the central light through an opening. Its
    // opaque emitter must not shadow itself; an added cage voxel must shadow it.
    try world.setBlock(.{ 1, 6, 0 }, &white);
    const lamp_lit = try scenePixel(&world, point, .{ 15.9, 103.5, 7.5 }, .{ 1, 0, 0 });
    if (lamp_lit[2] < 10 or lamp_lit[2] <= lamp_lit[0]) return error.LampDoesNotIlluminate;
    var blocked_lamp = try lamp.clone(a);
    defer blocked_lamp.deinit(a);
    blocked_lamp.blockData.voxel.setVoxel(14, 7, 7, 2);
    try world.setBlock(.{ 0, 6, 0 }, &blocked_lamp);
    const lamp_shadow = try scenePixel(&world, point, .{ 15.9, 103.5, 7.5 }, .{ 1, 0, 0 });
    if (lamp_shadow[2] > 2) return error.LampCageDoesNotShadow;
    std.debug.print("Point lights: shadow={any}, radius={any}; lamp={any}, neighbor={any}\n", .{ shadow, outside, luminous, lamp_lit });
}

fn checkLightingCache(a: std.mem.Allocator, path: []const u8) !void {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const white = Block.initMono(0, Voxel.rgb(255, 255, 255));
    const empty = Block.initEmpty(0);
    const eye = [3]f32{ 8.5, 104.5, 64 };
    const direction = [3]f32{ 0, 0, -1 };
    var world = try World.init(a);
    defer world.deinit() catch {};
    try world.setBlock(.{ 0, 6, 0 }, &white);
    try world.scene_lights.append(.{ .position = .{ 40, 104, 40 }, .color = .{ 1, 0, 0 } });
    const program = try gl_utils.createLightingProgram(path, .{ .face_cache = true, .face_shading = false, .point_lights = true, .sky_lighting = false }, 8);
    defer gl.deleteProgram(program);
    var cache = try LightingCache.init(program);
    defer cache.deinit();
    if (cache.frame_loc < 0) return error.CacheCompiledOut;
    var lights = LightUniforms.init(program);
    const cold = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    var cold_image: [65 * 65 * 4]u8 = undefined;
    c.glReadPixels(0, 0, 65, 65, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &cold_image);
    const warm = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    var warm_image: [65 * 65 * 4]u8 = undefined;
    c.glReadPixels(0, 0, 65, 65, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &warm_image);
    if (!std.mem.eql(u8, &cold_image, &warm_image)) return error.CacheFrameNotStable;
    if (!std.mem.eql(u8, &cold, &warm) or warm[0] < 100) return error.CacheWarmMismatch;
    const valid_from = cache.clock.valid_from;
    _ = try cachedScenePixel(&world, program, .{ 8.5, 104.5, 63 }, direction, &cache, &lights);
    if (cache.clock.valid_from != valid_from) return error.CameraInvalidatesLighting;

    try world.setBlock(.{ 4096, 6, 4096 }, &white);
    const after_distant_edit = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (cache.clock.valid_from != valid_from or !std.mem.eql(u8, &warm, &after_distant_edit)) return error.DistantEditInvalidatesLighting;

    // Confirm actual GPU entries were filled, rather than only taking fallback.
    const entries = @import("lighting.zig").face_cache_entries;
    const stamps = try a.alloc(u32, entries);
    defer a.free(stamps);
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(entries * 4), stamps.ptr);
    var written: usize = 0;
    for (stamps) |stamp| if (stamp > 0) {
        written += 1;
    };
    if (written == 0) return error.CacheNeverWritten;

    // A deliberately full table with wrong keys must not alias another face.
    const keys = try a.alloc([4]i32, entries);
    defer a.free(keys);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[1]);
    c.__glewGetBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(entries * 16), keys.ptr);
    var center_slot: ?usize = null;
    for (keys, 0..) |key, i| {
        if (stamps[i] > 0 and std.mem.eql(i32, &key, &.{ 8, 104, 15, 5 })) {
            center_slot = i;
            break;
        }
    }
    const slot = center_slot orelse return error.CacheCenterNotWritten;
    // Substitute a blue payload in the already-published red face. A blue next
    // frame proves the renderer actually reuses GPU values rather than retracing.
    const blue_payload = [4]f32{ 0, 0, 1, 1 };
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[2]);
    c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, @intCast(slot * 16), 16, &blue_payload);
    const reused = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (reused[2] < 250 or reused[0] > 2) return error.CacheNeverRead;
    c.__glewMemoryBarrier.?(c.GL_BUFFER_UPDATE_BARRIER_BIT);
    @memset(keys, .{ 123456, -654321, 222222, 0 });
    @memset(stamps, cache.clock.frame);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[0]);
    c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(entries * 4), stamps.ptr);
    try gl.bindBuffer(c.GL_TEXTURE_BUFFER, cache.buffers[1]);
    c.__glewBufferSubData.?(c.GL_TEXTURE_BUFFER, 0, @intCast(entries * 16), keys.ptr);
    const collision = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (!std.mem.eql(u8, &cold, &collision)) return error.CacheCollisionAliasesFace;

    try world.setBlock(.{ 1, 6, 1 }, &white);
    const shadow = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (shadow[0] > 2 or cache.clock.valid_from == valid_from) return error.CacheGeometryInvalidation;
    try world.setBlock(.{ 1, 6, 1 }, &empty);
    const restored = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (restored[0] < 100) return error.CacheRemovalInvalidation;
    world.scene_lights.items[0].color = .{ 0, 1, 0 };
    const green = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (green[0] > 2 or green[1] < 100) return error.CacheLightColorInvalidation;
    world.scene_lights.items[0].radius = 1;
    const dark = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (dark[1] > 2) return error.CacheLightRadiusInvalidation;
    world.scene_lights.items[0].radius = 128;
    world.scene_lights.items[0].position = .{ 8, 104, -32 };
    const behind = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (behind[1] > 2) return error.CacheLightPositionInvalidation;
    world.scene_lights.clearRetainingCapacity();
    const removed = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    if (removed[1] > 2) return error.CacheLightRemovalInvalidation;

    // Separate faces and negative coordinates must keep their own illumination.
    try world.setBlock(.{ -2, 6, -2 }, &white);
    try world.scene_lights.append(.{ .position = .{ -24, 136, -24 }, .color = .{ 0, 0, 1 } });
    for (0..3) |axis| for ([_]f32{ -1, 1 }) |sign| {
        var view = [3]f32{ -23.5, 104.5, -23.5 };
        var dir = [3]f32{ 0, 0, 0 };
        view[axis] += sign * 48;
        dir[axis] = -sign;
        const first = try cachedScenePixel(&world, program, view, dir, &cache, &lights);
        const second = try cachedScenePixel(&world, program, view, dir, &cache, &lights);
        if (!std.mem.eql(u8, &first, &second)) return error.CacheFaceKeyMismatch;
        if (axis == 1 and ((sign > 0 and second[2] < 100) or (sign < 0 and second[2] > 2))) return error.CacheNormalAliases;
    };
    std.debug.print("Face cache {s}: {d} populated entries; reuse, collisions, edits and lights passed\n", .{ path, written });
    // Sky occlusion has the same invalidation contract, including streaming.
    const sky_program = try gl_utils.createLightingProgram(path, .{ .face_cache = true, .face_shading = false, .point_lights = false, .sky_lighting = true }, 8);
    defer gl.deleteProgram(sky_program);
    var sky_cache = try LightingCache.init(sky_program);
    defer sky_cache.deinit();
    var sky_uniforms = LightUniforms.init(sky_program);
    const open = try cachedScenePixel(&world, sky_program, eye, direction, &sky_cache, &sky_uniforms);
    if (open[2] < 80) return error.CacheSkyMissing;
    for (0..3) |x| for (0..3) |z| try world.setBlock(.{ @as(i32, @intCast(x)) - 1, 8, @intCast(z) }, &white);
    const covered = try cachedScenePixel(&world, sky_program, eye, direction, &sky_cache, &sky_uniforms);
    if (covered[2] > 2) return error.CacheSkyRoofStale;
    for (0..3) |x| for (0..3) |z| try world.setBlock(.{ @as(i32, @intCast(x)) - 1, 8, @intCast(z) }, &empty);
    const reopened = try cachedScenePixel(&world, sky_program, eye, direction, &sky_cache, &sky_uniforms);
    if (!std.mem.eql(u8, &open, &reopened)) return error.CacheSkyRemovalStale;
    const old_generation = sky_cache.clock.valid_from;
    _ = try cachedScenePixel(&world, sky_program, .{ 8192, 104, 8192 }, direction, &sky_cache, &sky_uniforms);
    const reloaded = try cachedScenePixel(&world, sky_program, eye, direction, &sky_cache, &sky_uniforms);
    if (!std.mem.eql(u8, &open, &reloaded) or sky_cache.clock.valid_from <= old_generation) return error.CacheStreamingStale;
    try benchmarkLightingCache(a, path);
}

fn benchmarkLightingCache(a: std.mem.Allocator, path: []const u8) !void {
    var world = try @import("world/world.zig").World.init(a);
    defer world.deinit() catch {};
    try @import("world/startupBuilding.zig").place(&world);
    try world.scene_lights.append(.{ .position = .{ 100, 286, 100 }, .color = .{ 1, 0.94, 0.82 }, .radius = 2048, .intensity = 2 });
    // Include open-air views: these were reported as slower than the interior.
    const views = [_]struct { name: []const u8, eye: [3]f32, dir: [3]f32 }{
        .{ .name = "interior", .eye = .{ 100, 30, 100 }, .dir = .{ 0, 0, -1 } },
        .{ .name = "outside roof", .eye = .{ 100, 192, 100 }, .dir = .{ 0, -1, 0 } },
        .{ .name = "outside wall", .eye = .{ 120, 40, -100 }, .dir = .{ 0, 0, 1 } },
    };
    var timings: [views.len][2]f64 = undefined;
    var cold_times: [views.len]f64 = undefined;
    for ([_]bool{ false, true }, 0..) |enabled, i| {
        const program = try gl_utils.createLightingProgram(path, .{ .face_cache = enabled }, 8);
        defer gl.deleteProgram(program);
        var cache = try LightingCache.init(program);
        defer cache.deinit();
        var lights = LightUniforms.init(program);
        for (views, 0..) |view, v| {
            _ = try cachedScenePixel(&world, program, view.eye, view.dir, &cache, &lights);
            try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), 640, 360);
            c.glViewport(0, 0, 640, 360);
            // Exclude driver JIT, then deliberately invalidate for a cold draw.
            try cache.begin(world.gpu_revision, lights.revision);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
            c.glFinish();
            var timer = try std.time.Timer.start();
            try cache.begin(world.gpu_revision + 1, lights.revision);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
            c.glFinish();
            if (enabled) cold_times[v] = @as(f64, @floatFromInt(timer.read())) / 1e6;
            for (0..5) |_| {
                try cache.begin(world.gpu_revision + 1, lights.revision);
                c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
                cache.end();
            }
            c.glFinish();
            timer.reset();
            for (0..20) |_| {
                try cache.begin(world.gpu_revision + 1, lights.revision);
                c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
                cache.end();
            }
            c.glFinish();
            timings[v][i] = @as(f64, @floatFromInt(timer.read())) / 1e6 / 20;
        }
    }
    for (views, 0..) |view, v| {
        std.debug.print("Lighting benchmark {s}, {s}, 640x360, warm 20 frames: uncached={d:.2} ms cached={d:.2} ms ({d:.2}x), cold={d:.2} ms\n", .{ path, view.name, timings[v][0], timings[v][1], timings[v][0] / timings[v][1], cold_times[v] });
    }
}

// Every probe is one exact voxel-face center on an unobstructed opaque floor.
// Compare to analytic lighting: matching cold/warm images alone cannot detect
// an incorrect shadow that was computed once and then faithfully cached.
fn checkFlatLighting(a: std.mem.Allocator) !void {
    const settings = @import("lighting.zig");
    const World = @import("world/world.zig").World;
    const Chunk = @import("world/worldChunk.zig").Chunk;
    const Voxel = @import("world/voxel.zig").Voxel;
    const size = 512;
    var world = try World.init(a);
    defer world.deinit() catch {};
    for (0..4) |x| for (0..4) |z| {
        try world.chunks.put(.{ .x = @as(i32, @intCast(x)) - 2, .y = -1, .z = @as(i32, @intCast(z)) - 2 }, Chunk.initMono(0, Voxel.rgb(255, 255, 255)));
    };
    try world.scene_lights.append(.{ .position = .{ 100, 286, 100 }, .radius = 2048, .color = .{ 1, 1, 1 }, .intensity = 0.4 });
    const pixels = try a.alloc(u8, size * size * 4);
    defer a.free(pixels);
    const cases = [_]struct { mode: u8, cache: bool }{ .{ .mode = 1, .cache = false }, .{ .mode = 1, .cache = true }, .{ .mode = 2, .cache = true }, .{ .mode = 3, .cache = true } };
    for (cases) |case| {
        const mode = case.mode;
        const program = try gl_utils.createLightingProgram("src/graphics/shaders/tests/lighting_probe", .{ .face_cache = case.cache, .face_shading = false, .point_lights = mode & 1 != 0, .sky_lighting = mode & 2 != 0 }, 8);
        defer gl.deleteProgram(program);
        var cache = try LightingCache.init(program);
        defer cache.deinit();
        var lights = LightUniforms.init(program);
        _ = try cachedScenePixel(&world, program, .{ 0, 32, 0 }, .{ 0, -1, 0 }, null, &lights);
        gl.uniform3i(gl.getUniformLocation(program, "uProbeOrigin"), -256, 0, -256);
        c.glViewport(0, 0, size, size);
        for (0..3) |frame| {
            const offsets = [3][2]f32{ .{ 0.33, -0.27 }, .{ -0.41, 0.49 }, .{ 0.1, 0.1 } };
            try gl.uniform2f(gl.getUniformLocation(program, "uProbeSubface"), offsets[frame][0], offsets[frame][1]);
            if (frame > 0) try cache.begin(world.gpu_revision, lights.revision);
            c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
            cache.end();
            c.glReadPixels(0, 0, size, size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
            var bad: usize = 0;
            for (0..size) |z| for (0..size) |x| {
                var expected = [3]f32{ 0, 0, 0 };
                if (mode & 2 != 0) for (0..3) |ch| {
                    expected[ch] += settings.sky_color[ch] * settings.sky_intensity;
                };
                if (mode & 1 != 0) {
                    const dx = 100 - (@as(f32, @floatFromInt(x)) - 255.5);
                    const dy = 286 - settings.shadow_epsilon;
                    const dz = 100 - (@as(f32, @floatFromInt(z)) - 255.5);
                    const distance = @sqrt(dx * dx + dy * dy + dz * dz);
                    const r = distance / 2048;
                    const cutoff = 1 - r * r;
                    const value = 0.4 * cutoff * cutoff / (1 + 16 * r * r) * dy / distance;
                    for (&expected) |*ch| ch.* += value;
                }
                var wrong = false;
                for (0..3) |ch| {
                    const want: i32 = @intFromFloat(@round(@min(1, expected[ch]) * 255));
                    if (@abs(@as(i32, pixels[(z * size + x) * 4 + ch]) - want) > 1) wrong = true;
                }
                if (wrong) {
                    if (bad < 5) std.debug.print("Flat floor mismatch mode={d} frame={d} at ({d}, {d}): actual={any}, expected={any}\n", .{ mode, frame, @as(i32, @intCast(x)) - 256, @as(i32, @intCast(z)) - 256, pixels[(z * size + x) * 4 ..][0..3], expected });
                    bad += 1;
                }
            };
            std.debug.print("Flat floor mode={d} cache={} frame={d}: {d}/{d} incorrect voxel faces\n", .{ mode, case.cache, frame, bad, size * size });
            if (bad > 0) {
                _ = c.stbi_write_png("/tmp/voxel-flat-lighting.png", size, size, 4, pixels.ptr, size * 4);
                return error.FlatFloorLightingArtifacts;
            }
        }
        if (mode == 2) {
            gl.uniform1i(gl.getUniformLocation(program, "uProbeTrace"), 1);
            try gl.uniform2f(gl.getUniformLocation(program, "uResolution"), size, size);
            try gl.uniform3f(gl.getUniformLocation(program, "uCamDir"), 0.3, -1.5, 0.7);
            for ([_]f32{ -256.5, -128.5, -0.5, 0.5, 128.5, 256.5 }) |position| {
                try gl.uniform3f(gl.getUniformLocation(program, "uCamPos"), position, 30, position);
                for (0..2) |frame| {
                    if (frame == 0) c.__glewUniform1ui.?(cache.frame_loc, 0) else try cache.begin(world.gpu_revision, lights.revision);
                    c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
                    cache.end();
                    c.glReadPixels(0, 0, size, size, c.GL_RGBA, c.GL_UNSIGNED_BYTE, pixels.ptr);
                    var bad: usize = 0;
                    for (0..size * size) |i| {
                        var wrong = false;
                        for (0..3) |ch| {
                            const want: i32 = @intFromFloat(@round(std.math.pow(f32, settings.sky_color[ch] * settings.sky_intensity, 1.0 / 2.2) * 255));
                            if (@abs(@as(i32, pixels[i * 4 + ch]) - want) > 1) wrong = true;
                        }
                        if (wrong) bad += 1;
                    }
                    std.debug.print("Traced floor camera={d} cached={d}: {d} incorrect pixels\n", .{ position, frame, bad });
                    if (bad > 0) {
                        _ = c.stbi_write_png("/tmp/voxel-flat-traced.png", size, size, 4, pixels.ptr, size * 4);
                        return error.TracedFloorLightingArtifacts;
                    }
                }
            }
        }
    }
}

// A roof covers the +X/+Z quadrant at the sample, leaving a known subset of
// cardinal/diagonal directions visible. Check angular weights on the GPU.
fn checkSkyWeights(a: std.mem.Allocator) !void {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    const settings = @import("lighting.zig");
    var world = try World.init(a);
    defer world.deinit() catch {};
    const white = Block.initMono(0, Voxel.rgb(255, 255, 255));
    try world.setBlock(.{ 0, 6, 0 }, &white);
    try world.setBlock(.{ 0, 8, 0 }, &white);
    const inner = @cos(@as(f32, 10) * std.math.pi / 180);
    const outer = @cos(@as(f32, 15) * std.math.pi / 180);
    const counts = [_]u32{ 0, 4, 8, 12, 16 };
    const visible = [_]f32{ 0, 2 * inner, 5 * inner, 5 * inner + 3 * outer, 5 * inner + 6 * outer };
    for (counts, visible) |count, weight| {
        const program = try gl_utils.createLightingProgram("src/graphics/shaders/tests/lighting_probe", .{ .face_cache = false, .face_shading = false, .point_lights = false, .sky_lighting = true }, count);
        defer gl.deleteProgram(program);
        _ = try scenePixel(&world, program, .{ 8, 128, 48 }, .{ 0, -1, 0 });
        gl.uniform3i(gl.getUniformLocation(program, "uProbeOrigin"), 0, 112, 0);
        c.glViewport(0, 0, 1, 1);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        var pixel: [4]u8 = undefined;
        c.glReadPixels(0, 0, 1, 1, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &pixel);
        const total = 1 + @as(f32, @floatFromInt(@min(count, 8))) * inner + @as(f32, @floatFromInt(count - @min(count, 8))) * outer;
        for (0..3) |ch| {
            const expected: i32 = @intFromFloat(@round(settings.sky_color[ch] * settings.sky_intensity * weight / total * 255));
            if (@abs(@as(i32, pixel[ch]) - expected) > 1) return error.SkyRingWeightMismatch;
        }
        std.debug.print("Sky rings {d} extra: weighted visibility {d:.4}, pixel={any}\n", .{ count, weight / total, pixel });
    }
}

// Check the combined tint on gray material, below clipping, so a saturated
// white output cannot conceal an unbalanced sky/sun contribution.
fn checkDaylightBalance(a: std.mem.Allocator, path: []const u8) !void {
    const settings = @import("lighting.zig");
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    var world = try World.init(a);
    defer world.deinit() catch {};
    const gray = Block.initMono(0, Voxel.rgb(180, 180, 180));
    try world.setBlock(.{ 0, 6, 0 }, &gray);
    try world.scene_lights.append(.{
        .position = .{ 8.5, 112 + 30 + settings.sun_height, 8.5 },
        .radius = settings.sun_radius,
        .color = settings.sun_color,
        .intensity = settings.sun_intensity,
    });
    const features = settings.Features{ .mode = .direct, .face_shading = false, .normal_probes = false, .indirect = false };
    const program = try gl_utils.createLightingProgram(path, features, settings.sky_extra_ray_count);
    defer gl.deleteProgram(program);
    if (gl.getUniformLocation(program, "uGiFrame") != -1) return error.DirectModeHasGiQueue;
    var cache = try LightingCache.init(program);
    defer cache.deinit();
    if (cache.frame_loc < 0) return error.DirectModeCacheMissing;
    var lights = LightUniforms.init(program);
    const eye = [3]f32{ 8.5, 136, 8.5 };
    const direction = [3]f32{ 0, -1, 0 };
    const cold = try cachedScenePixel(&world, program, eye, direction, &cache, &lights);
    const revision = cache.clock.valid_from;
    const warm = try cachedScenePixel(&world, program, .{ 8.6, 136, 8.5 }, direction, &cache, &lights);
    if (!std.mem.eql(u8, &cold, &warm) or revision != cache.clock.valid_from) return error.DirectCacheNotPersistent;
    const low = @min(warm[0], @min(warm[1], warm[2]));
    const high = @max(warm[0], @max(warm[1], warm[2]));
    if (high - low > 3 or low < 120 or high > 230) return error.DaylightNotNeutralBelowClipping;
    var sky_features = features;
    sky_features.point_lights = false;
    const sky = try gl_utils.createLightingProgram(path, sky_features, settings.sky_extra_ray_count);
    defer gl.deleteProgram(sky);
    const sky_pixel = try scenePixel(&world, sky, eye, direction);
    if (@as(u16, sky_pixel[2]) < @as(u16, sky_pixel[0]) + 12) return error.SkylightNotBlue;
    var sun_features = features;
    sun_features.sky_lighting = false;
    const sun = try gl_utils.createLightingProgram(path, sun_features, 0);
    defer gl.deleteProgram(sun);
    const sun_pixel = try scenePixel(&world, sun, eye, direction);
    if (@as(u16, sun_pixel[0]) < @as(u16, sun_pixel[2]) + 12 or sun_pixel[1] <= sun_pixel[2]) return error.SunlightNotWarm;
    std.debug.print("Direct daylight {s}: sky={any}, sun={any}, combined={any}; cold/warm cache and camera motion match\n", .{ path, sky_pixel, sun_pixel, warm });
}

fn checkLedSticks(a: std.mem.Allocator, path: []const u8, registry: *const Registry) !void {
    const World = @import("world/world.zig").World;
    const Block = @import("world/block.zig").Block;
    const Voxel = @import("world/voxel.zig").Voxel;
    var world = try World.init(a);
    defer world.deinit() catch {};
    const target = Block.initMono(0, Voxel.rgb(180, 180, 180));
    try world.setBlock(.{ 4, 6, 0 }, &target);
    try world.setBlock(.{ 0, 5, 0 }, &target);
    const program = try gl_utils.createLightingProgram(path, .{ .mode = .direct, .face_shading = false, .sky_lighting = false }, 0);
    defer gl.deleteProgram(program);
    var cache = try LightingCache.init(program);
    defer cache.deinit();
    var lights = LightUniforms.init(program);
    const names = [_][]const u8{ "Cold White LED Stick", "Warm White LED Stick", "Neutral White LED Stick", "Red LED Stick", "Green LED Stick", "Blue LED Stick" };
    for (names, 0..) |name, index| {
        const model = &registry.blocks.items[registry.find(name, 0) orelse return error.LedStickMissing].model;
        try world.setBlock(.{ 0, 6, 0 }, model);
        // Side-on ray sees a neutral receiver lit by the stick's tip. This
        // catches accidentally burying the source in its opaque shaft.
        const pixel = try cachedScenePixel(&world, program, .{ 63.5, 101.5, 7.5 }, .{ 1, 0, 0 }, &cache, &lights);
        if (world.block_lights.items.len != 1) return error.LedStickLightOwnership;
        switch (index) {
            0 => if (@as(u16, pixel[2]) < @as(u16, pixel[0]) + 15 or pixel[1] <= pixel[0]) return error.ColdWhiteStickTint,
            1 => if (@as(u16, pixel[0]) < @as(u16, pixel[2]) + 15 or pixel[1] <= pixel[2]) return error.WarmWhiteStickTint,
            2 => if (pixel[0] < 30 or @abs(@as(i16, pixel[0]) - pixel[1]) > 1 or @abs(@as(i16, pixel[1]) - pixel[2]) > 1) return error.NeutralWhiteStickTint,
            else => {
                const channel = index - 3;
                if (pixel[channel] < 30 or pixel[(channel + 1) % 3] > 2 or pixel[(channel + 2) % 3] > 2) return error.ColoredStickTint;
            },
        }
        const below = try cachedScenePixel(&world, program, .{ 3.5, 98, 7.5 }, .{ 0, -1, 0 }, &cache, &lights);
        if (@max(below[0], @max(below[1], below[2])) < 30) return error.LedStickShadowsOwnBase;
        std.debug.print("{s}: receiver={any}, below={any}\n", .{ name, pixel, below });
    }
    // An opaque non-emitting segment still blocks the light, even inside the
    // source's own block. Only its matching luminous material is exempt.
    var obstructed = try registry.blocks.items[registry.find("Blue LED Stick", 0).?].model.clone(a);
    defer obstructed.deinit(a);
    obstructed.blockData.voxel.setPaletteEntry(2, Voxel.rgb(64, 64, 64));
    obstructed.blockData.voxel.setVoxel(7, 4, 7, 2);
    try world.setBlock(.{ 0, 6, 0 }, &obstructed);
    const shadow = try cachedScenePixel(&world, program, .{ 3.5, 98, 7.5 }, .{ 0, -1, 0 }, &cache, &lights);
    if (shadow[2] > 2) return error.LedOpaqueSegmentDoesNotShadow;
}
