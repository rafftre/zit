// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Functions for retrieving files based on tracking status.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("model/util/fs.zig");
const hash = @import("model/util/hash.zig");
const Repository = @import("repository.zig").Repository;

/// Information about a file in the index or in the working directory.
pub fn File(comptime Hasher: type) type {
    return struct {
        /// Path in the filesystem.
        path: []const u8,
        /// Object ID (only included for tracked files)
        object_id: ?Repository(Hasher).Object.Id = null,
        /// File mode (only included for tracked files)
        mode: ?fs.FileMode = null,
        /// Stage info (only included for tracked files)
        merge_stage: ?Repository(Hasher).Index.MergeStage = null,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.path);
        }

        /// Comparison function for use with `std.mem.sort`.
        /// Sort files in ascending order on the path field.
        pub fn lessThan(_: void, lhs: Self, rhs: Self) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    };
}

/// Options for `list`.
pub const ListOptions = struct {
    /// Reads cached (tracked) files.
    cached: bool = false,
    /// Reads others (untracked) files.
    others: bool = false,
    /// Reads (unstaged) deleted files.
    deleted: bool = false,
    /// Reads (unstaged) modified files.
    modified: bool = false,
    /// Reads unmerged files.
    unmerged: bool = false,
    /// Reads untracked files conflicting with tracked ones.
    killed: bool = false,
    /// Adds stage information to tracked files.
    stage_info: bool = false,

    /// Validites the combination of options.
    fn check(self: *ListOptions) void {
        // forces stage info when unmerged files are requested
        if (self.unmerged) {
            self.stage_info = true;
        }

        // defaults to cached if no option is set
        if (!self.cached and !self.others and !self.stage_info and
            !self.deleted and !self.modified and !self.unmerged and !self.killed)
        {
            self.cached = true;
        }
    }
};

/// Retrieves a list of files in the index and in the working directory.
/// The returned list is a combination of files built according to the specified options.
/// For this reason, a file may be reported multiple times.
/// Defaults to cached files if no option is set.
/// Forces stage info when unmerged files are requested.
/// Caller owns the returned memory.
pub fn list(
    allocator: Allocator,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for reading the index.
    repository: Repository(Hasher),
    opts: *ListOptions,
) !std.ArrayList(File(Hasher)) {
    opts.check();

    var index = try repository.loadIndex(allocator);
    defer index.deinit(allocator);

    var res: std.ArrayList(File(Hasher)) = .empty;
    errdefer res.deinit(allocator);

    if (opts.others or opts.killed) {
        const worktree = repository.worktree();
        if (worktree == null) {
            return error.MissingWorktree;
        }

        var dir = try std.fs.cwd().openDir(worktree.?, .{ .iterate = true });
        defer dir.close();

        if (opts.others) {
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (entry.kind == .file and !repository.isInternalPath(entry.path) and !index.contains(entry.path)) {
                    try appendUntrackedFile(allocator, Hasher, &res, entry.path);
                }
            }
        }

        if (opts.killed) {
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next()) |entry| {
                if (!repository.isInternalPath(entry.path) and index.containsPrefix(entry.path, true)) {
                    try appendUntrackedFile(allocator, Hasher, &res, entry.path);
                }
            }
        }

        std.mem.sort(File(Hasher), res.items, {}, File(Hasher).lessThan);
    }

    if (opts.cached or opts.stage_info or opts.deleted or opts.modified) {
        for (index.entries.items) |entry| {
            if (opts.deleted) {
                std.fs.cwd().access(entry.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => try appendTrackedFile(allocator, Hasher, &res, entry, false),
                    else => return err,
                };
            } else if (opts.modified) {
                const stat = std.fs.cwd().statFile(entry.path) catch |err| switch (err) {
                    error.FileNotFound => {
                        try appendTrackedFile(allocator, Hasher, &res, entry, false);
                        continue;
                    },
                    error.NotDir => continue,
                    else => return err,
                };

                if (entry.isChanged(stat)) {
                    try appendTrackedFile(allocator, Hasher, &res, entry, false);
                }
            } else if ((opts.cached or opts.stage_info) and (!opts.unmerged or entry.isUnmerged())) {
                try appendTrackedFile(allocator, Hasher, &res, entry, opts.stage_info);
            }
        }
    }

    return res;
}

fn appendTrackedFile(
    allocator: Allocator,
    comptime Hasher: type,
    target: *std.ArrayList(File(Hasher)),
    entry: Repository(Hasher).Index.Entry,
    stage_info: bool,
) !void {
    var file = try target.addOne(allocator);
    file.* = .{
        .path = try allocator.dupe(u8, entry.path),
    };

    if (stage_info) {
        var oid: Repository(Hasher).Object.Id = .{};
        @memcpy(&oid.bytes, &entry.hash);

        file.object_id = oid;
        file.mode = entry.file_mode;
        file.merge_stage = entry.flags.stage;
    }
}

fn appendUntrackedFile(
    allocator: Allocator,
    comptime Hasher: type,
    target: *std.ArrayList(File(Hasher)),
    path: []const u8,
) !void {
    const file = try target.addOne(allocator);
    file.* = .{
        .path = try allocator.dupe(u8, path),
    };
}

test "list files" {
    const allocator = std.testing.allocator;
    const test_hasher = hash.Sha1;

    var env: std.process.EnvMap = .init(allocator);
    defer env.deinit();

    var repo: Repository(test_hasher) = try .open(allocator, .git, null, env);
    defer repo.deinit(allocator);

    var opts: ListOptions = .{
        .cached = true,
        .others = true,
    };

    var file_list = try list(allocator, test_hasher, repo, &opts);
    defer {
        for (file_list.items) |*f| {
            f.deinit(allocator);
        }
        file_list.deinit(allocator);
    }

    try std.testing.expect(file_list.items.len > 0);
}
