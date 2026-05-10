// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const build_options = @import("build_options");
const zit = @import("zit");
const Command = @import("cli/Command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const usage_prefix = "  ";

/// The global list of all command_list.
/// To add a new command, instantiate a new `Command` and insert it into this list.
pub const command_list = [_]Command{
    @import("cli/cat-file.zig").command,
    @import("cli/hash-object.zig").command,
    @import("cli/help.zig").command,
    @import("cli/inflate.zig").command,
    @import("cli/init.zig").command,
    @import("cli/ls-files.zig").command,
    @import("cli/update-index.zig").command,
    @import("cli/version.zig").command,
};

/// Prints the main usage description by iterating through the list of all commands.
pub fn printGlobalUsage(out: *std.Io.Writer) !void {
    try out.print(
        \\{s}
        \\
        \\Usage:
        \\{s}{s} <command> [arguments]
        \\
    , .{ build_options.app_description, usage_prefix, build_options.app_name });

    try out.print("\nCommands:\n", .{});
    for (command_list) |cmd| {
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
pub fn fail(stdout: *std.Io.Writer, stderr: *std.Io.Writer) noreturn {
    stdout.flush() catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Finds the requested command and executes it.
pub fn dispatchCommand(
    io: Io,
    allocator: Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    name: [:0]const u8,
    iter: *std.process.Args.Iterator,
    env: *std.process.Environ.Map,
) !void {
    for (command_list) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            var args: Command.Arguments = .{};
            defer args.deinit(allocator);

            const ctx: Command.Context = .{
                .io = io,
                .allocator = allocator,
                .stdout = stdout,
                .stderr = stderr,
                .env = env,
            };

            try args.parse(allocator, stderr, cmd, iter);
            try cmd.run(ctx, args);
            return;
        }
    }

    try stderr.print("Unknown command '{s}'\n\n", .{name});
    try printGlobalUsage(stderr);
}
