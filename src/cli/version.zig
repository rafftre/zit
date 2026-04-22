// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;

/// The version command.
pub const command = Command{
    .run = handler,
    .name = "version",
    .brief = "Show version information",
    .description = "Show the version of the application.",
};

fn handler(ctx: Command.Context, _: Command.Arguments) !void {
    try ctx.stdout.print("{s} version {s}\n", .{ build_options.app_name, build_options.app_version });
}
