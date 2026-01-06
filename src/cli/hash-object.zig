// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const GitRepository = zit.storage.GitRepositorySha1;

/// The hash-object command.
pub const command = Command{
    .run = run,
    .name = "hash-object",
    .brief = "Compute object ID and optionally writes to the database",
    .description =
    \\This command computes the object IDs for the contents of the named
    \\files (which can be outside of the working tree), and optionally writes
    \\the resulting objects into the database.
    \\
    \\The object IDs are computed with the specified type, or as a "blob" when
    \\missing.
    \\
    \\The file content can be entered directly from stdin instead of being read
    \\from a file.
    ,
    .usage_lines = "[-t <type>] [-w] [--stdin [--literally]] <file>...",
    .parameters = &[_]Command.Parameter{
        .{ .option = .{
            .short = 't',
            .description = "The type of the object (default: \"blob\").",
            .require_value = true,
        } },
        .{ .option = .{
            .short = 'w',
            .description = "Write the object into the database.",
        } },
        .{ .option = .{
            .long = "stdin",
            .description = "Read the object from standard input instead of from a file.",
        } },
        .{ .option = .{
            .long = "literally",
            .description =
            \\Allow --stdin to hash anything into a loose object which might not
            \\otherwise pass standard object parsing.
            \\Useful for stress-testing or reproducing corrupt or bogus objects.
            ,
        } },
        .{ .positional = .{
            .name = "file",
            .description = "The file to read from (there may be multiple files).",
        } },
    },
};

fn run(allocator: Allocator, args: Command.Arguments) !void {
    const out = std.io.getStdOut().writer();

    const type_str = args.parsed.get("t") orelse "blob";
    const persist = args.parsed.get("w") != null;
    const use_stdin = args.parsed.get("stdin") != null;
    const literally = args.parsed.get("literally") != null;

    const repository = GitRepository.open(allocator, null) catch |err| switch (err) {
        error.GitDirNotFound => {
            try out.print(
                "Error: Repository not found (cannot find .git in current directory or any of the parents).\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer repository.close(allocator);

    if (use_stdin) {
        const in = std.io.getStdIn().reader();

        const oid = try zit.hashObject(allocator, repository.store, in, type_str, !literally, persist);
        defer allocator.free(oid);

        try out.print("{s}\n", .{oid});
    }

    for (args.positional.items) |path| {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try std.io.getStdErr().writer().print("Failed to open file: {s}\n", .{@errorName(err)});
            continue;
        };
        defer file.close();

        const oid = try zit.hashObject(allocator, repository.store, file.reader(), type_str, true, persist);
        defer allocator.free(oid);

        try out.print("{s}\n", .{oid});
    }
}
