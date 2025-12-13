// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

// keep these properties in sync with build.zig.zon
const app_name = "zit";
const app_description = "Zit is a Git implementation written in Zig.";
const app_version = "0.4.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules -----------------------------------------------------------------

    const lib_mod = b.addModule("zit", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zit", lib_mod);

    const options = b.addOptions();
    options.addOption([]const u8, "app_name", app_name);
    options.addOption([]const u8, "app_description", app_description);
    options.addOption([]const u8, "app_version", app_version);
    exe_mod.addOptions("build_options", options);

    // Artifacts ---------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "zit",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    b.installArtifact(exe);

    const doc_obj = b.addObject(.{
        .name = "lib",
        .root_module = lib_mod,
    });

    // Run ---------------------------------------------------------------------

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test --------------------------------------------------------------------

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Docs --------------------------------------------------------------------

    const install_docs = b.addInstallDirectory(.{
        .source_dir = doc_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&install_docs.step);
}
