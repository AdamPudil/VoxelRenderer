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

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
