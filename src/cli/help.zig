// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const cli = @import("../cli.zig");
const build_options = @import("build_options");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;

/// The help command.
pub const command = Command{
    .run = handler,
    .name = "help",
    .brief = "Show help information",
    .description = "Show help information for a command.",
    .usage_lines = "[<command>]",
    .parameters = &[_]Command.Parameter{
        .{ .positional = .{
            .name = "command",
            .description = "The name of the command for which to display help information.",
        } },
    },
};

fn handler(ctx: Command.Context, args: Command.Arguments) !void {
    if (args.positional.items.len <= 0) {
        try cli.printGlobalUsage(ctx.stdout);
        return;
    }

    const topic = args.positional.items[0];
    for (cli.command_list) |cmd| {
        if (std.mem.eql(u8, cmd.name, topic)) {
            try ctx.stdout.print("{s} - {s}\n\n", .{ cmd.name, cmd.brief });
            try cmd.printUsage(ctx.stdout, build_options.app_name);
            return;
        }
    }

    try ctx.stderr.print("No help topic for '{s}'\n\n", .{topic});
}
