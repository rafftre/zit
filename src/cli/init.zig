// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const Sha1 = zit.hash.Sha1;

/// The init command.
pub const command = Command{
    .run = handler,
    .name = "init",
    .brief = "Create an empty repository or reinitialize an existing one",
    .description =
    \\This command creates an empty repository with an initial branch without
    \\any commits.
    \\
    \\The repository is written to a .git subdirectory (or the current directory
    \\if it is a bare one). A different path can be used instead of .git by
    \\setting the GIT_DIR environment.
    \\
    \\Objects are saved in GIT_DIR/objects unless the GIT_OBJECT_DIRECTORY
    \\environment is set.
    \\
    \\Running this command in an existing repository is safe because no existing
    \\items will be overwritten.
    ,
    .usage_lines =
    \\[-b <branch-name> | --initial-branch=<branch-name>]
    \\[--bare] [<directory>]
    ,
    .parameters = &[_]Command.Parameter{
        .{ .option = .{
            .short = 'b',
            .long = "initial-branch",
            .description =
            \\The name to use for the initial branch.
            \\If not specified, the default is "main".
            ,
            .require_value = true,
        } },
        .{ .option = .{
            .long = "bare",
            .description =
            \\Create a bare repository, i.e. without a working tree.
            \\If GIT_DIR environment is not set, use the current directory.
            ,
        } },
        .{ .positional = .{
            .name = "directory",
            .description =
            \\The directory in which to execute the command - it's created if
            \\it doesn't exist. The current directory is used when missing.
            ,
        } },
    },
};

fn handler(allocator: Allocator, stdout: *std.Io.Writer, _: *std.Io.Writer, args: Command.Arguments) !void {
    const name = if (args.positional.items.len > 0) args.positional.items[0] else null;

    var options: zit.SetupOptions = .{
        .bare = args.parsed.get("bare") != null,
    };

    const initial_branch = args.parsed.get("initial-branch");
    if (initial_branch) |branch| {
        options.initial_branch = branch;
    }

    var repo = try zit.Repository(Sha1).setup(allocator, .git, name, options);
    defer repo.deinit(allocator);

    try stdout.print("Initialized empty Git repository in {s}\n", .{repo.name() orelse "unknown"});
}
