// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The init command.
pub const command = cli.Command{
    .run = run,
    .require_repository = false,
    .name = "init",
    .description = "Create an empty repository or reinitialize an existing one",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} init [-b <branch-name> | --initial-branch=<branch-name>]
        \\           [--bare] [<directory>]
        \\
        \\Description:
        \\  This command creates an empty repository with an initial branch without any
        \\  commits.
        \\
        \\  The repository is written to a .git subdirectory (or the current directory
        \\  if it is a bare one). A different path can be used instead of .git by setting
        \\  the GIT_DIR environment.
        \\
        \\  Objects are saved in GIT_DIR/objects unless the GIT_OBJECT_DIRECTORY
        \\  environment is set.
        \\
        \\  Running this command in an existing repository is safe because no existing
        \\  items will be overwritten.
        \\
        \\Options:
        \\  <directory>
        \\    The directory in which to execute the command - it's created if it
        \\    doesn't exist. The current directory is used when missing.
        \\
        \\  -b <branch-name> | --initial-branch=<branch-name>
        \\    The name to use for the initial branch.
        \\    If not specified, the default value is "main".
        \\
        \\  --bare
        \\    Create a bare repository, i.e. without a working tree.
        \\    If GIT_DIR environment is not set, use the current directory.
    , .{build_options.app_name}),
};

fn run(allocator: Allocator, _: ?*Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    var is_bare = false;
    var initial_branch: ?[]const u8 = null;

    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--bare")) {
            is_bare = true;
        } else if (std.mem.eql(u8, arg, "-b")) {
            if (args.len <= (i + 1)) {
                try out.print("Error: '-b' requires a value.\n", .{});
                return;
            }
            i += 1;
            initial_branch = args[i];
        } else if (std.mem.startsWith(u8, arg, "--initial-branch")) {
            const offset = "--initial-branch=".len;
            if (arg.len <= offset) {
                try out.print("Error: '--initial-branch' requires a value.\n", .{});
                return;
            }
            initial_branch = arg[offset..];
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.print("Error: Unknown flag '{s}' for '{s}' command.\n", .{ arg, command.name });
            return;
        } else {
            try positional_args.append(arg);
        }
    }

    var options: zit.storage.CreateOptions = .{
        .bare = is_bare,
        .name = if (positional_args.items.len > 0) positional_args.items[0] else null,
    };
    if (initial_branch) |branch| {
        options.initial_branch = branch;
    }

    var repository = try zit.storage.createGitRepository(allocator, options);
    defer zit.storage.closeGitRepository(allocator, repository);

    try out.print("Initialized empty Git repository in {s}\n", .{repository.name() orelse "unknown"});
}
