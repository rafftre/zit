// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const GitRepository = zit.storage.GitRepositorySha1;

/// The inflate command.
pub const command = Command{
    .run = run,
    .name = "inflate",
    .brief = "Decompresses an object in the repository",
    .description =
    \\This command decompresses an object in the repository and prints its
    \\encoded version, i.e. header (type name, space, and length) and
    \\serialized data.
    \\
    \\It only runs zlib to decompress an object, which can be useful for
    \\exploring the object database.
    ,
    .usage_lines = "<object>",
    .parameters = &[_]Command.Parameter{
        .{ .positional = .{
            .name = "object",
            .description = "The name of the object to decompress.",
        } },
    },
};

fn run(allocator: Allocator, args: Command.Arguments) !void {
    const out = std.io.getStdOut().writer();

    if (args.positional.items.len > 0) {
        const hex = args.positional.items[0];

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

        const encoded_data = try zit.readEncodedData(allocator, repository.store, hex);
        defer allocator.free(encoded_data);

        try out.print("{s}", .{encoded_data});
    }
}
