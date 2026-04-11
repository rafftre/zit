// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const build_options = @import("build_options");
const Command = @import("cli/Command.zig");

const Allocator = std.mem.Allocator;
const usage_prefix = "  ";

const cat_file = @import("cli/cat-file.zig").command;
const hash_object = @import("cli/hash-object.zig").command;
const inflate = @import("cli/inflate.zig").command;
const init_repo = @import("cli/init.zig").command;
const ls_files = @import("cli/ls-files.zig").command;
const version = @import("cli/version.zig").command;

/// The help command.
const help = Command{
    .run = runHelp,
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

/// The global list of all commands.
/// To add a new command, instantiate a new `Command` and insert it into this list.
pub const commands = [_]Command{
    help,
    cat_file,
    hash_object,
    inflate,
    init_repo,
    ls_files,
    version,
};

/// Prints the main usage description by iterating through the list of all commands.
pub fn printUsage(out: *std.Io.Writer) !void {
    try out.print(
        \\{s}
        \\
        \\Usage:
        \\{s}{s} <command> [arguments]
        \\
    , .{ build_options.app_description, usage_prefix, build_options.app_name });

    try out.print("\nCommands:\n", .{});
    for (commands) |cmd| {
        try out.print("{s}{s:<20} {s}\n", .{ usage_prefix, cmd.name, cmd.brief });
    }

    try out.print(
        \\
        \\Run '{s} help <command>' for more information on a specific command.
        \\
        \\
    , .{build_options.app_name});
}

/// Exits the application with an error status.
pub inline fn fail(out: *std.Io.Writer) noreturn {
    out.flush() catch {};
    std.process.exit(1);
}

/// Finds the requested command and executes it.
pub fn runCommand(allocator: Allocator, out: *std.Io.Writer, name: [:0]u8, args: [][:0]u8) !void {
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            var cmd_args = Command.Arguments.init(allocator);
            defer cmd_args.deinit(allocator);

            cmd_args.parse(allocator, cmd, args, out) catch |err| {
                std.log.debug("Failed to parse command arguments: {s}", .{@errorName(err)});
                return;
            };

            try cmd.run(allocator, out, cmd_args);
            return;
        }
    }

    try out.print("Error: Unknown command '{s}'\n\n", .{name});
    try printUsage(out);
}

fn runHelp(_: Allocator, out: *std.Io.Writer, args: Command.Arguments) !void {
    if (args.positional.items.len <= 0) {
        try printUsage(out);
        return;
    }

    const topic = args.positional.items[0];
    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, topic)) {
            try out.print("{s} - {s}\n\n", .{ cmd.name, cmd.brief });
            try cmd.printUsage(out, build_options.app_name);
            return;
        }
    }

    try out.print("No help topic for '{s}'\n\n", .{topic});
}
