// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const Sha1 = zit.hash.Sha1;

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

fn run(allocator: Allocator, out: *std.Io.Writer, args: Command.Arguments) !void {
    if (args.positional.items.len > 0) {
        const obj_name = args.positional.items[0];

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

        var obj_id = try zit.Repository(Sha1).Object.Id.fromHex(allocator, obj_name);
        defer obj_id.deinit(allocator);

        var bytes: std.Io.Writer.Allocating = .init(allocator);
        defer bytes.deinit();

        try repo.readObject(allocator, &bytes.writer, obj_id);

        try out.print("{s}", .{bytes.written()});
    } else {
        try out.print("Error: <object> is required.\n", .{});
    }
}
