// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Sha1 = zit.hash.Sha1;

pub const command = Command{
    .run = handler,
    .name = "update-index",
    .brief = "Register file contents in the working tree to the index",
    .description =
    \\Modifies the index. Each file mentioned is updated in the index
    \\and any unmerged or needs-updating state is cleared.
    ,
    .usage_lines =
    \\[--add|--remove|--force-remove] [--chmod=(+|-)x] <file>...
    \\--refresh
    \\--cacheinfo <mode>,<object>,<path>
    ,
    .parameters = &[_]Command.Parameter{
        .{ .option = .{
            .long = "add",
            .description = "Add the file to the index, hashing and writing the blob object.",
        } },
        .{ .option = .{
            .long = "remove",
            .description =
            \\Remove the entry from the index. Fails if the file still exists
            \\in the working tree; use --force-remove to bypass this check.
            ,
        } },
        .{ .option = .{
            .long = "force-remove",
            .description = "Remove the entry from the index even if the file still exists in the working tree.",
        } },
        .{ .option = .{
            .long = "chmod",
            .description = "Set (+x) or clear (-x) the executable bit on the index entry.",
            .require_value = true,
        } },
        .{ .option = .{
            .long = "refresh",
            .description = "Update the cached stat information for all tracked files.",
        } },
        .{ .option = .{
            .long = "cacheinfo",
            .description = "Insert an entry directly by mode, object ID, and path ('<mode>,<oid>,<path>').",
            .require_value = true,
        } },
        .{ .positional = .{
            .name = "file",
            .description = "File paths to operate on.",
        } },
    },
};

fn handler(ctx: Command.Context, args: Command.Arguments) !void {
    const add = args.parsed.get("add") != null;
    const remove = args.parsed.get("remove") != null;
    const force_remove = args.parsed.get("force-remove") != null;
    const cacheinfo_val = args.parsed.get("cacheinfo");
    const chmod_val = args.parsed.get("chmod");
    const refresh = args.parsed.get("refresh") != null;

    var repo = zit.Repository(Sha1).open(ctx.io, .git, null, ctx.env, ctx.allocator) catch |err| switch (err) {
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

    var index = try repo.loadIndex(ctx.io, ctx.allocator);
    defer index.deinit(ctx.allocator);

    if (refresh) {
        for (index.entries.items) |*entry| {
            const stat = std.Io.Dir.cwd().statFile(ctx.io, entry.path, .{}) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            entry.updateStat(stat);
        }
    }

    if (cacheinfo_val) |val| {
        const entry = parseCacheinfo(ctx.allocator, val) catch {
            try ctx.stderr.print("Flags --cacheinfo expects '<mode>,<oid>,<path>'\n", .{});
            return;
        };
        try index.upsert(ctx.allocator, entry);
    }

    for (args.positional.items) |path| {
        if (chmod_val) |val| {
            if (val.len == 0) {
                try ctx.stderr.print("Flags --chmod expects '+x' or '-x'\n", .{});
                return;
            }
            const executable: bool = switch (val[0]) {
                '+' => true,
                '-' => false,
                else => {
                    try ctx.stderr.print("Flags --chmod expects '+x' or '-x', got '{s}'\n", .{val});
                    return;
                },
            };
            var found = false;
            for (index.entries.items) |*entry| {
                if (std.mem.eql(u8, entry.path, path)) {
                    entry.setExecutable(executable) catch {
                        try ctx.stderr.print("Path '{s}' is not a regular file\n", .{path});
                        return;
                    };
                    found = true;
                    break;
                }
            }
            if (!found) {
                try ctx.stderr.print("Path '{s}' not in index\n", .{path});
                return;
            }
        }

        if (remove or force_remove) {
            if (remove and !force_remove) {
                const file_still_exists = blk: {
                    std.Io.Dir.cwd().access(ctx.io, path, .{}) catch |err| switch (err) {
                        error.FileNotFound => break :blk false,
                        else => return err,
                    };
                    break :blk true;
                };
                if (file_still_exists) {
                    try ctx.stderr.print(
                        "File '{s}' still present; use --force-remove to remove anyway\n",
                        .{path},
                    );
                    return;
                }
            }
            index.remove(ctx.allocator, path) catch {};
        }

        if (add) {
            var entry = zit.index.createEntry(ctx.io, ctx.allocator, Sha1, repo, path) catch |err| switch (err) {
                error.FileNotFound => {
                    try ctx.stderr.print("No such file at path '{s}'\n", .{path});
                    return;
                },
                error.NotARegularFile => {
                    try ctx.stderr.print("Path '{s}' is not a regular file\n", .{path});
                    return;
                },
                else => return err,
            };
            {
                errdefer entry.deinit(ctx.allocator);
                try index.upsert(ctx.allocator, entry);
            }
        }
    }

    try repo.saveIndex(ctx.io, &index, ctx.allocator);
}

fn parseCacheinfo(allocator: Allocator, value: []const u8) !zit.Repository(Sha1).Index.Entry {
    const first = std.mem.indexOfScalar(u8, value, ',') orelse return error.InvalidFormat;
    const mode_str = value[0..first];
    const rest = value[(first + 1)..];
    const second = std.mem.indexOfScalar(u8, rest, ',') orelse return error.InvalidFormat;
    const oid_str = rest[0..second];
    const path_str = rest[(second + 1)..];

    if (path_str.len == 0) {
        return error.InvalidFormat;
    }

    const file_mode = try zit.mode.FileMode.parse(mode_str);
    const obj_id = try zit.Repository(Sha1).Object.Id.fromHex(oid_str);

    return .{
        .ctime = 0,
        .mtime = 0,
        .device = 0,
        .inode = 0,
        .file_mode = file_mode,
        .user_id = 0,
        .group_id = 0,
        .file_size = 0,
        .hash = obj_id.bytes,
        .flags = .{ .name_length = @intCast(@min(path_str.len, std.math.maxInt(u12))) },
        .path = try allocator.dupeZ(u8, path_str),
    };
}
