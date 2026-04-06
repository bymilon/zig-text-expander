const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "text-expander",
        .root_module = app_mod,
    });

    exe.linkSystemLibrary("user32");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the text expander");
    run_step.dependOn(&run_cmd.step);

    if (b.lazyDependency("tui", .{})) |tui_dep| {
        const tui_mod = b.createModule(.{
            .root_source_file = b.path("src/tui_main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        tui_mod.addImport("tui", tui_dep.module("tui"));

        const tui_exe = b.addExecutable(.{
            .name = "text-expander-tui",
            .root_module = tui_mod,
        });
        b.installArtifact(tui_exe);

        const tui_build_step = b.step("tui", "Build the text expander TUI");
        tui_build_step.dependOn(&tui_exe.step);

        const run_tui_cmd = b.addRunArtifact(tui_exe);
        run_tui_cmd.step.dependOn(b.getInstallStep());
        const run_tui_step = b.step("tui-run", "Run the text expander TUI");
        run_tui_step.dependOn(&run_tui_cmd.step);
    }
}
