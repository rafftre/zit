// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const Sha1 = zit.hash.Sha1;

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
    .usage_lines = "[-t <type>] [-w] [--stdin] <file>...",
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
        .{ .positional = .{
            .name = "file",
            .description = "The file to read from (there may be multiple files).",
        } },
    },
};

fn run(allocator: Allocator, out: *std.Io.Writer, args: Command.Arguments) !void {
    const type_str = args.parsed.get("t");
    const persist = args.parsed.get("w") != null;
    const use_stdin = args.parsed.get("stdin") != null;

    var repo = zit.Repository(Sha1).open(allocator, .git, null) catch |err| switch (err) {
        error.GitDirNotFound => {
            try out.print(
                "Error: Repository not found (cannot find .git in current directory or any of the parents).\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer repo.deinit(allocator);

    const obj_type = zit.object.Type.parse(type_str) orelse .blob;

    if (use_stdin) {
        const stdin_file: std.fs.File = .stdin();
        defer stdin_file.close();

        var in_buf: [1024]u8 = undefined;
        var stdin_r = stdin_file.readerStreaming(&in_buf);
        const stdin = &stdin_r.interface;

        // FIXME: does not listen for user input
        var obj_id = try zit.object.create(allocator, stdin, Sha1, repo, obj_type, persist);
        errdefer obj_id.deinit(allocator);

        try out.print("{f}\n", .{obj_id});
    }

    for (args.positional.items) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            // TODO: move stderr to main?
            const stderr_file: std.fs.File = .stderr();
            defer stderr_file.close();

            var err_buf: [1024]u8 = undefined;
            var stderr_w = stderr_file.writer(&err_buf);
            const stderr = &stderr_w.interface;

            try stderr.print("Failed to open file: {s}\n", .{@errorName(err)});
            try stderr.flush();

            continue;
        };
        defer file.close();

        var file_buf: [4 * 1024]u8 = undefined;
        var file_r = file.readerStreaming(&file_buf);
        const reader = &file_r.interface;

        var obj_id = try zit.object.create(allocator, reader, Sha1, repo, obj_type, persist);
        errdefer obj_id.deinit(allocator);

        try out.print("{f}\n", .{obj_id});
    }
}
