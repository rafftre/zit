// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const cli = @import("root.zig");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const GitRepository = zit.storage.GitRepositorySha1;

/// The cat-file command.
pub const command = Command{
    .run = run,
    .name = "cat-file",
    .brief = "Provide contents or type and size information for objects",
    .description =
    \\Provide contents or type and size information for an object in the
    \\repository. The type is required unless one of the flags is used.
    ,
    .usage_lines =
    \\<type> <object>
    \\(-e | -p) <object>
    \\(-t | -s) [--allow-unknown-type] <object>
    ,
    .parameters = &[_]Command.Parameter{
        .{ .option = .{
            .short = 'e',
            .description =
            \\Check if object exists. Exit with non-zero status and emits an
            \\error on stderr if object doesn't exists or is of an invalid format.
            ,
        } },
        .{ .option = .{
            .short = 'p',
            .description = "Pretty-print the contents of object.",
        } },
        .{ .option = .{
            .short = 't',
            .description = "Show the object type.",
        } },
        .{ .option = .{
            .short = 's',
            .description = "Show the object size.",
        } },
        .{ .option = .{
            .long = "allow-unknown-type",
            .description = "Allow -s or -t to query broken/corrupt objects of unknown type.",
        } },
        .{ .positional = .{
            .name = "object",
            .description = "The name of the object to show.",
        } },
        .{ .positional = .{
            .name = "type",
            .description = "The expected type for object.",
        } },
    },
};

fn run(allocator: Allocator, args: Command.Arguments) !void {
    const out = std.io.getStdOut().writer();

    const allow_unknown_type = args.parsed.get("allow-unknown-type") != null;
    const check_exists = args.parsed.get("e") != null;
    const pretty_print = args.parsed.get("p") != null;
    const get_size = args.parsed.get("s") != null;
    const get_type = args.parsed.get("t") != null;

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

    if (args.positional.items.len > 1) {
        const expected_type = args.positional.items[0];
        const obj_name = args.positional.items[1];

        if (check_exists or pretty_print or get_size or get_type) {
            try out.print("Error: Too many arguments.\n", .{});
            return;
        }

        var obj = try zit.readObject(allocator, repository.store, obj_name, expected_type);
        defer obj.deinit(allocator);

        const bytes = try obj.serialize(allocator);
        defer allocator.free(bytes);

        try out.print("{s}", .{bytes});
    } else if (args.positional.items.len > 0) {
        const obj_name = args.positional.items[0];

        if (eptsCount(check_exists, pretty_print, get_size, get_type) > 1) {
            try out.print("Error: Selected flags are incompatible.\n", .{});
            return;
        }

        if (check_exists) {
            if (allow_unknown_type) {
                try out.print("Error: --allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var obj = zit.readObject(allocator, repository.store, obj_name, null) catch |err| switch (err) {
                error.FileNotFound => cli.fail(),
                else => return err,
            };
            defer obj.deinit(allocator);
        } else if (pretty_print) {
            if (allow_unknown_type) {
                try out.print("Error: --allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var obj = try zit.readObject(allocator, repository.store, obj_name, null);
            defer obj.deinit(allocator);

            try out.print("{any}", .{obj});
        } else if (get_size or get_type) {
            const type_size = try zit.readTypeAndSize(allocator, repository.store, obj_name, allow_unknown_type);
            if (get_size) {
                try out.print("{d}\n", .{type_size.obj_size});
            } else {
                try out.print("{s}\n", .{type_size.obj_type});
            }
        }
    } else {
        try out.print("Error: <object> is required with -e, -p, -s or -t flags.\n", .{});
    }
}

inline fn eptsCount(
    check_exists: bool,
    pretty_print: bool,
    get_size: bool,
    get_type: bool,
) usize {
    var count: usize = 0;

    if (check_exists) {
        count += 1;
    }
    if (pretty_print) {
        count += 1;
    }
    if (get_size) {
        count += 1;
    }
    if (get_type) {
        count += 1;
    }

    return count;
}
