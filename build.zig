const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_tests = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "test",
        "src/root.zig",
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
