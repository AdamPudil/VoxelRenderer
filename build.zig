const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const options = b.addOptions();
    const source_id = @import("src/sourceIdentity.zig").fingerprint(b.allocator) catch @panic("Cannot fingerprint renderer source");
    options.addOption([]const u8, "source_id", &source_id);
    options.addOption([]const u8, "zig_version", @import("builtin").zig_version_string);
    options.addOption(bool, "terrain_overlay_skips", b.option(bool, "terrain-overlay-skips", "Skip empty voxel groups in terrain edits") orelse true);
    options.addOption(bool, "vector_world_headers", b.option(bool, "vector-world-headers", "Experiment: fetch world headers as RGBA32UI records") orelse false);

    const exe = b.addExecutable(.{
        .name = "voxel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();

    exe.linkSystemLibrary("GL");
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("GLEW");

    exe.addIncludePath(b.path("libs/c/stb"));
    exe.addCSourceFile(.{
        .file = b.path("libs/c/stb/stb_image_write.c"),
        .flags = &[_][]const u8{},
    });

    exe.addCSourceFile(.{ .file = b.path("libs/c/stb/stb_image.c"), .flags = &.{} });

    //const zg = b.dependency("zig-gamedev", .{});
    //exe.root_module.addImport("zmath", zg.module("zmath"));

    const tests = b.addTest(.{ .root_source_file = b.path("src/blockTests.zig"), .target = target, .optimize = optimize });
    tests.linkLibC();
    tests.linkSystemLibrary("GL");
    tests.linkSystemLibrary("GLEW");
    tests.addIncludePath(b.path("libs/c/stb"));
    const test_step = b.step("test", "Test blocks, input, cameras and event queues");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const profiling_tests = b.addTest(.{ .root_source_file = b.path("src/graphics/frameTimings.zig"), .target = target, .optimize = optimize });
    profiling_tests.linkLibC();
    profiling_tests.linkSystemLibrary("GL");
    profiling_tests.linkSystemLibrary("GLEW");
    const run_profiling_tests = b.addRunArtifact(profiling_tests);
    b.step("test-profile", "Test profiling statistics, disabled mode and CSV output").dependOn(&run_profiling_tests.step);
    test_step.dependOn(&run_profiling_tests.step);

    const capture_tests = b.addTest(.{ .root_source_file = b.path("src/profileCapture.zig"), .target = target, .optimize = optimize });
    const run_capture_tests = b.addRunArtifact(capture_tests);
    b.top_level_steps.get("test-profile").?.step.dependOn(&run_capture_tests.step);
    test_step.dependOn(&run_capture_tests.step);

    const input_tests = b.addTest(.{ .root_source_file = b.path("src/inputTests.zig"), .target = target, .optimize = optimize });
    input_tests.linkLibC();
    const run_input_tests = b.addRunArtifact(input_tests);
    b.step("test-input", "Test input mapping and current-frame event delivery").dependOn(&run_input_tests.step);
    test_step.dependOn(&run_input_tests.step);

    const camera_tests = b.addTest(.{ .root_source_file = b.path("src/cameraTests.zig"), .target = target, .optimize = optimize });
    camera_tests.linkLibC();
    const run_camera_tests = b.addRunArtifact(camera_tests);
    b.step("test-camera", "Test camera registry, validation and resolved snapshots").dependOn(&run_camera_tests.step);
    test_step.dependOn(&run_camera_tests.step);

    const generation_tests = b.addTest(.{ .root_source_file = b.path("src/generationTests.zig"), .target = target, .optimize = optimize });
    const run_generation_tests = b.addRunArtifact(generation_tests);
    b.step("test-generation", "Test position hashes and hierarchical generation").dependOn(&run_generation_tests.step);
    test_step.dependOn(&run_generation_tests.step);

    const generation_full_tests = b.addTest(.{ .root_source_file = b.path("src/generationFullTests.zig"), .target = target, .optimize = .ReleaseSafe });
    b.step("test-generation-full", "Generate nine superchunks and all their chunks at voxel resolution").dependOn(&b.addRunArtifact(generation_full_tests).step);

    const generation_preview = b.addExecutable(.{ .name = "generation-preview", .root_source_file = b.path("src/generationPreview.zig"), .target = target, .optimize = .ReleaseSafe });
    generation_preview.linkLibC();
    generation_preview.addIncludePath(b.path("libs/c/stb"));
    generation_preview.addCSourceFile(.{ .file = b.path("libs/c/stb/stb_image_write.c"), .flags = &.{} });
    const run_generation_preview = b.addRunArtifact(generation_preview);
    if (b.args) |args| run_generation_preview.addArgs(args);
    b.step("generation-preview", "Export terrain and height-map PNGs with timings (directory, resolution, superchunks per side)").dependOn(&run_generation_preview.step);

    const run_lod_preview = b.addRunArtifact(generation_preview);
    run_lod_preview.addArg("--lod");
    if (b.args) |args| run_lod_preview.addArgs(args);
    b.step("generation-lod-preview", "Export five runtime terrain bands along a moving camera path (optional output directory)").dependOn(&run_lod_preview.step);

    const render_test = b.addExecutable(.{ .name = "block-render-test", .root_source_file = b.path("src/blockRenderTest.zig"), .target = target, .optimize = optimize });
    render_test.linkLibC();
    for ([_][]const u8{ "GL", "GLEW", "EGL" }) |lib| render_test.linkSystemLibrary(lib);
    render_test.addIncludePath(b.path("libs/c/stb"));
    for ([_][]const u8{ "libs/c/stb/stb_image.c", "libs/c/stb/stb_image_write.c" }) |path| render_test.addCSourceFile(.{ .file = b.path(path), .flags = &.{} });
    const render_run = b.addRunArtifact(render_test);
    render_run.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    render_run.setEnvironmentVariable("MESA_GL_VERSION_OVERRIDE", "4.6");
    render_run.setEnvironmentVariable("MESA_GLSL_VERSION_OVERRIDE", "460");
    b.step("test-render", "Render block icons and menu offscreen with Mesa/EGL").dependOn(&render_run.step);

    const profiling_run = b.addRunArtifact(render_test);
    profiling_run.addArg("--profile-only");
    profiling_run.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    profiling_run.setEnvironmentVariable("MESA_GL_VERSION_OVERRIDE", "4.6");
    profiling_run.setEnvironmentVariable("MESA_GLSL_VERSION_OVERRIDE", "460");
    b.step("test-profile-gpu", "Check asynchronous profiling queries offscreen with Mesa/EGL").dependOn(&profiling_run.step);

    const hierarchy_run = b.addRunArtifact(render_test);
    hierarchy_run.addArg("--hierarchy-only");
    hierarchy_run.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    hierarchy_run.setEnvironmentVariable("MESA_GL_VERSION_OVERRIDE", "4.6");
    hierarchy_run.setEnvironmentVariable("MESA_GLSL_VERSION_OVERRIDE", "460");
    b.step("test-hierarchy", "Check hierarchy levels, rings, exact shadows and lighting cache offscreen").dependOn(&hierarchy_run.step);

    const lighting_rings_run = b.addRunArtifact(render_test);
    lighting_rings_run.addArg("--lighting-rings-only");
    lighting_rings_run.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    lighting_rings_run.setEnvironmentVariable("MESA_GL_VERSION_OVERRIDE", "4.6");
    lighting_rings_run.setEnvironmentVariable("MESA_GLSL_VERSION_OVERRIDE", "460");
    b.step("test-lighting-rings", "Check near direct lighting and distant face shading offscreen").dependOn(&lighting_rings_run.step);

    const gi_run = b.addRunArtifact(render_test);
    gi_run.addArg("--gi-only");
    gi_run.setEnvironmentVariable("LIBGL_ALWAYS_SOFTWARE", "1");
    gi_run.setEnvironmentVariable("MESA_GL_VERSION_OVERRIDE", "4.6");
    gi_run.setEnvironmentVariable("MESA_GLSL_VERSION_OVERRIDE", "460");
    b.step("test-gi", "Check queued progressive global illumination offscreen").dependOn(&gi_run.step);

    for ([_]*std.Build.Step.Compile{ exe, tests, input_tests, camera_tests, generation_tests, generation_full_tests, generation_preview, render_test }) |artifact|
        artifact.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
