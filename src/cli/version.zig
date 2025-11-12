// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The version command.
pub const command = cli.Command{
    .run = run,
    .name = "version",
    .description = "Show version information",
    .usage_text = null,
};

fn run(_: Allocator, _: ?*Repository, _: []const []const u8) !void {
    const out = std.io.getStdOut().writer();
    try out.print("{s} version {s}\n", .{ build_options.app_name, build_options.app_version });
}
