// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The cat-file command.
pub const command = cli.Command{
    .run = run,
    .require_repository = true,
    .name = "cat-file",
    .description = "Provide contents or type and size information for objects",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} cat-file <type> <object>
        \\  {s} cat-file (-e | -p) <object>
        \\  {s} cat-file (-t | -s) [--allow-unknown-type] <object>
        \\
        \\Description:
        \\  This command provides the content or type of an object in the repository.
        \\  The type is required unless one of the flags is used.
        \\
        \\Options:
        \\  <object>
        \\    The name of the object to show.
        \\
        \\  <type>
        \\    The expected type for object.
        \\
        \\  --allow-unknown-type
        \\    Allow -s or -t to query broken/corrupt objects of unknown type.
        \\
        \\  -e
        \\    Check if object exists. Exit with non-zero status and emits an error
        \\    on stderr if object doesn't exists or is of an invalid format.
        \\
        \\  -p
        \\    Pretty-print the contents of object.
        \\
        \\  -s
        \\    Show the object size.
        \\
        \\  -t
        \\    Show the object type.
        \\
    , .{ build_options.app_name, build_options.app_name, build_options.app_name }),
};

fn run(allocator: Allocator, repository: ?Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    var allow_unknown_type = false;
    var check_exists = false;
    var pretty_print = false;
    var get_size = false;
    var get_type = false;

    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--allow-unknown-type")) {
            allow_unknown_type = true;
        } else if (std.mem.eql(u8, arg, "-e")) {
            check_exists = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            pretty_print = true;
        } else if (std.mem.eql(u8, arg, "-s")) {
            get_size = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            get_type = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.print("Error: Unknown flag '{s}' for '{s}' command.\n", .{ arg, command.name });
            return;
        } else {
            try positional_args.append(arg);
        }
    }

    if (positional_args.items.len > 1) {
        const expected_type = positional_args.items[0];
        const obj_name = positional_args.items[1];

        if (check_exists or pretty_print or get_size or get_type) {
            try out.print("Error: Too many arguments.\n", .{});
            return;
        }

        var obj = try zit.readObject(allocator, repository.?.objectStore(), obj_name, expected_type);
        defer obj.deinit(allocator);

        const bytes = try obj.serialize(allocator);
        defer allocator.free(bytes);

        try out.print("{s}", .{bytes});
    } else if (positional_args.items.len > 0) {
        const obj_name = positional_args.items[0];

        if (eptsCount(check_exists, pretty_print, get_size, get_type) > 1) {
            try out.print("Error: Selected flags are incompatible.\n", .{});
            return;
        }

        if (check_exists) {
            if (allow_unknown_type) {
                try out.print("Error: --allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var obj = zit.readObject(allocator, repository.?.objectStore(), obj_name, null) catch |err| switch (err) {
                error.FileNotFound => cli.fail(),
                else => return err,
            };
            defer obj.deinit(allocator);
        } else if (pretty_print) {
            if (allow_unknown_type) {
                try out.print("Error: --allow-unknown-type must be used with -s or -t flags.\n", .{});
                return;
            }

            var obj = try zit.readObject(allocator, repository.?.objectStore(), obj_name, null);
            defer obj.deinit(allocator);

            try out.print("{any}", .{obj});
        } else if (get_size or get_type) {
            const type_size = try zit.readTypeAndSize(allocator, repository.?.objectStore(), obj_name, allow_unknown_type);
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
