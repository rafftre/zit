// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The help command.
pub const command = cli.Command{
    .run = run,
    .name = "help",
    .description = "Show help information",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} help [<command>]
        \\
    , .{build_options.app_name}),
};

fn run(_: Allocator, _: ?Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    if (args.len == 0) {
        try cli.printUsage(out);
        return;
    }

    const topic = args[0];
    for (cli.commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, topic)) {
            try out.print("{s} - {s}\n", .{ cmd.name, cmd.description });
            if (cmd.usage_text) |text| {
                try out.print("\n{s}\n", .{text});
            } else { // add another newline for Windows
                try out.print("\n", .{});
            }
            return;
        }
    }

    try out.print("No help topic for '{s}'\n\n", .{topic});
}
