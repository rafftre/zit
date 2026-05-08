// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const cli = @import("../cli.zig");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha1 = zit.hash.Sha1;

/// The cat-file command.
pub const command = Command{
    .run = handler,
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

fn handler(ctx: Command.Context, args: Command.Arguments) !void {
    const allow_unknown_type = args.parsed.get("allow-unknown-type") != null;
    const check_exists = args.parsed.get("e") != null;
    const pretty_print = args.parsed.get("p") != null;
    const get_size = args.parsed.get("s") != null;
    const get_type = args.parsed.get("t") != null;

    var repo = zit.Repository(Sha1).open(
        ctx.io,
        .git,
        null,
        ctx.env,
        ctx.allocator,
    ) catch |err| switch (err) {
        error.GitDirNotFound => {
            try ctx.stderr.print(
                "Repository not found (cannot find .git in current directory or any of the parents).\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer repo.deinit(ctx.allocator);

    if (args.positional.items.len > 1) {
        const expected_type = args.positional.items[0];
        const obj_name = args.positional.items[1];

        if (check_exists or pretty_print or get_size or get_type) {
            try ctx.stderr.print("Too many arguments.\n", .{});
            return;
        }

        const obj_type = zit.object.Type.parse(expected_type);

        const obj_id = try zit.Repository(Sha1).Object.Id.fromHex(obj_name);

        var loose_obj = try zit.object.read(ctx.io, ctx.allocator, Sha1, repo, &obj_id, obj_type);
        defer loose_obj.deinit(ctx.allocator);

        try ctx.stdout.print("{s}", .{loose_obj.content});
    } else if (args.positional.items.len > 0) {
        const obj_name = args.positional.items[0];

        var obj_id = try zit.Repository(Sha1).Object.Id.fromHex(obj_name);

        if (eptsCount(check_exists, pretty_print, get_size, get_type) > 1) {
            try ctx.stderr.print("Selected flags are incompatible.\n", .{});
            return;
        }

        if (check_exists) {
            if (allow_unknown_type) {
                try ctx.stderr.print("--allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var loose_obj = zit.object.read(ctx.io, ctx.allocator, Sha1, repo, &obj_id, null) catch |err| switch (err) {
                error.FileNotFound => cli.fail(ctx.stdout, ctx.stderr),
                else => return err,
            };
            defer loose_obj.deinit(ctx.allocator);
        } else if (pretty_print) {
            if (allow_unknown_type) {
                try ctx.stderr.print("--allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var loose_obj = try zit.object.read(ctx.io, ctx.allocator, Sha1, repo, &obj_id, null);
            defer loose_obj.deinit(ctx.allocator);

            var obj: zit.Repository(Sha1).Object = try .deserialize(ctx.allocator, &loose_obj);
            defer obj.deinit(ctx.allocator);

            try ctx.stdout.print("{f}", .{obj});
        } else if (get_size) {
            const obj_size = try zit.object.getSize(ctx.io, ctx.allocator, Sha1, repo, &obj_id, allow_unknown_type);
            try ctx.stdout.print("{d}\n", .{obj_size});
        } else if (get_type) {
            const obj_type = try zit.object.getType(ctx.io, ctx.allocator, Sha1, repo, &obj_id, allow_unknown_type);
            try ctx.stdout.print("{s}\n", .{obj_type.toString() orelse "unknown"});
        }
    } else {
        try ctx.stderr.print("<object> is required with -e, -p, -s or -t flags.\n", .{});
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
