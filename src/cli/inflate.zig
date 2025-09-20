// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The inflate command.
pub const command = cli.Command{
    .run = run,
    .require_repository = true,
    .name = "inflate",
    .description = "Decompresses an object in the repository",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} inflate <object>
        \\
        \\Description:
        \\  Decompresses an object in the repository and prints its encoded version,
        \\  i.e. header (type name, space, and length) and serialized data.
        \\
        \\  It only runs zlib to decompress an object, which can be useful for exploring
        \\  the object database.
        \\
        \\Options:
        \\  <object>
        \\    The name of the object to decompress.
        \\
    , .{build_options.app_name}),
};

fn run(allocator: Allocator, repository: ?Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            try out.print("Error: Unknown flag '{s}' for '{s}' command.\n", .{ arg, command.name });
            return;
        } else {
            try positional_args.append(arg);
        }
    }

    if (positional_args.items.len > 0) {
        const hex = positional_args.items[0];

        const encoded_data = try zit.readEncodedData(allocator, repository.?.objects, hex);
        defer allocator.free(encoded_data);

        try out.print("{s}", .{encoded_data});
    }
}
