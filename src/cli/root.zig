// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const help = @import("help.zig").command;
const cat_file = @import("cat-file.zig").command;
const hash_object = @import("hash-object.zig").command;
const inflate = @import("inflate.zig").command;
const init_repo = @import("init.zig").command;
const version = @import("version.zig").command;

/// The interface for a command.
pub const Command = struct {
    run: *const fn (allocator: Allocator, repository: ?Repository, args: []const []const u8) anyerror!void,
    name: []const u8,
    description: []const u8,
    usage_text: ?[]const u8,
    require_repository: bool = false,
};

/// The global list of all commands.
/// To add a new command, instantiate a new `Command` and insert it into this list.
pub const commands = [_]Command{
    help,
    cat_file,
    hash_object,
    inflate,
    init_repo,
    version,
};

/// Finds the requested command and executes it.
pub fn run(allocator: Allocator, name: [:0]u8, args: [][:0]u8) !void {
    const out = std.io.getStdOut().writer();

    for (commands) |cmd| {
        if (std.mem.eql(u8, cmd.name, name)) {
            var repository: ?Repository = null;

            if (cmd.require_repository) {
                repository = zit.storage.openGitRepository(allocator, null) catch |err| switch (err) {
                    error.GitDirNotFound => {
                        try out.print(
                            "Error: Repository not found (cannot find .git in current directory or any of the parents).\n",
                            .{},
                        );
                        return;
                    },
                    else => return err,
                };
            }

            try cmd.run(allocator, repository, args);

            defer {
                if (repository) |repo| {
                    repo.close(allocator);
                }
            }

            return;
        }
    }

    try out.print("Error: Unknown command '{s}'\n\n", .{name});
    try printUsage(out);
}

/// Shows help for a specific topic or command.
pub inline fn printHelp(allocator: Allocator, topic: []const u8) !void {
    try help.run(allocator, null, &[_][]const u8{topic});
}

/// Exits the application with an error status.
pub inline fn fail() noreturn {
    std.process.exit(1);
}

/// Prints the main usage description by iterating through the list of all commands.
pub fn printUsage(writer: anytype) !void {
    try writer.print(
        \\{s}
        \\
        \\Usage:
        \\  {s} <command> [arguments]
        \\
        \\Commands:
        \\
    , .{ build_options.app_description, build_options.app_name });

    for (commands) |cmd| {
        try writer.print(
            "  {s:<20} {s}\n",
            .{ cmd.name, cmd.description },
        );
    }

    try writer.print(
        \\
        \\Run '{s} help <command>' for more information on a specific command.
        \\
        \\
    , .{build_options.app_name});
}
