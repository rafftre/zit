// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The hash-object command.
pub const command = cli.Command{
    .run = run,
    .require_repository = true,
    .name = "hash-object",
    .description = "Compute object ID and optionally writes to the database.",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} hash-object [-t <type>] [-w] [--stdin [--literally]] <file>...
        \\
        \\Description:
        \\  This command computes the object IDs for the contents of the named
        \\  files (which can be outside of the working tree), and optionally writes
        \\  the resulting objects into the database.
        \\
        \\  The object IDs are computed with the specified type, or as a "blob" when
        \\  missing.
        \\
        \\  The file content can be entered directly from stdin instead of being
        \\  read from a file.
        \\
        \\Options:
        \\  <file>
        \\    The file to read from (there may be multiple files).
        \\
        \\  --literally
        \\    Allow --stdin to hash anything into a loose object which might not
        \\    otherwise pass standard object parsing.
        \\    Useful for stress-testing or reproducing corrupt or bogus objects.
        \\
        \\  --stdin
        \\    Read the object from standard input instead of from a file.
        \\
        \\  -t <type>
        \\    The type of the object (default: "blob").
        \\
        \\  -w
        \\    Write the object into the database.
        \\
    , .{build_options.app_name}),
};

fn run(allocator: Allocator, repository: ?Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    var type_str: []const u8 = "blob";
    var persist = false;
    var use_stdin = false;
    var literally = false;

    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.startsWith(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "--literally")) {
            literally = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            if (args.len <= (i + 1)) {
                try out.print("Error: '-t' requires a value.\n", .{});
                return;
            }
            i += 1;
            type_str = args[i];
        } else if (std.mem.eql(u8, arg, "-w")) {
            persist = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.print("Error: Unknown flag '{s}' for '{s}' command\n", .{ arg, command.name });
            return;
        } else {
            try positional_args.append(arg);
        }
    }

    if (use_stdin) {
        const in = std.io.getStdIn().reader();

        const oid = try zit.hashObject(allocator, repository.?.objects, in, type_str, !literally, persist);
        defer allocator.free(oid);

        try out.print("{s}\n", .{oid});
    }

    for (positional_args.items) |path| {
        var file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try std.io.getStdErr().writer().print("Failed to open file: {s}\n", .{@errorName(err)});
            continue;
        };
        defer file.close();

        const oid = try zit.hashObject(allocator, repository.?.objects, file.reader(), type_str, true, persist);
        defer allocator.free(oid);

        try out.print("{s}\n", .{oid});
    }
}
