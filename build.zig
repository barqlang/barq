const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "barq",
        .root_source_file = b.path("bootstrap/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.linkSystemLibrary2("LLVM", .{ .use_pkg_config = .no });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_check = b.addExecutable(.{
        .name = "barq",
        .root_source_file = b.path("bootstrap/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_check.linkLibC();
    exe_check.linkSystemLibrary2("LLVM", .{ .use_pkg_config = .no });

    const check_step = b.step("check", "Checks if the app can compile");
    check_step.dependOn(&exe_check.step);
}
