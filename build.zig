const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
