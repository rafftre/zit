// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Functions for retrieving files based on tracking status.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MergeStage = @import("index.zig").MergeStage;
const ObjectId = @import("model.zig").ObjectId;
const FileMode = @import("helpers.zig").file.Mode;

/// Information about a file in the index or in the working directory.
pub const File = struct {
    /// Path in the filesystem.
    path: []const u8,
    /// Object ID (only included for tracked files)
    object_id: ?ObjectId = null,
    /// File mode (only included for tracked files)
    mode: ?FileMode = null,
    /// Stage info (only included for tracked files)
    merge_stage: ?MergeStage = null,

    /// Comparison function for use with `std.mem.sort`.
    /// Sort files in ascending order on the path field.
    fn lessThan(_: void, lhs: File, rhs: File) bool {
        return std.mem.order(u8, lhs.path, rhs.path) == .lt;
    }
};

/// Options for `listFiles`.
pub const ListFilesOptions = struct {
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
    fn check(self: *ListFilesOptions) void {
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
pub fn listFiles(allocator: Allocator, repository: anytype, opts: *ListFilesOptions) !std.ArrayList(File) {
    opts.check();

    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    if (opts.others or opts.killed) {
        const worktree = repository.worktree();
        if (worktree == null) {
            return error.MissingWorktree;
        }

        var dir = try std.fs.cwd().openDir(worktree.?, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        if (opts.others) {
            while (try walker.next()) |entry| {
                // FIXME: remove use of ".git" path (move to repository?)
                if (entry.kind == .file and !std.mem.startsWith(u8, entry.path, ".git") and !index.contains(entry.path)) {
                    try appendUntrackedFile(allocator, &res, entry.path);
                }
            }
        }

        if (opts.killed) {
            while (try walker.next()) |entry| {
                // FIXME: remove use of ".git" path (move to repository?)
                if (!std.mem.startsWith(u8, entry.path, ".git") and index.containsPrefix(entry.path, true)) {
                    try appendUntrackedFile(allocator, &res, entry.path);
                }
            }
        }

        std.mem.sort(File, res.items, {}, File.lessThan);
    }

    if (opts.cached or opts.stage_info or opts.deleted or opts.modified) {
        for (index.entries.items) |entry| {
            if (opts.deleted) {
                std.fs.cwd().access(entry.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => try appendTrackedFile(allocator, &res, entry, false),
                    else => return err,
                };
            } else if (opts.modified) {
                const stat = std.fs.cwd().statFile(entry.path) catch |err| switch (err) {
                    error.FileNotFound => {
                        try appendTrackedFile(allocator, &res, entry, false);
                        continue;
                    },
                    error.NotDir => continue,
                    else => return err,
                };

                if (entry.isChanged(stat)) {
                    try appendTrackedFile(allocator, &res, entry, false);
                }
            } else if ((opts.cached or opts.stage_info) and (!opts.unmerged or entry.isUnmerged())) {
                try appendTrackedFile(allocator, &res, entry, opts.stage_info);
            }
        }
    }

    return res;
}

inline fn appendTrackedFile(
    allocator: Allocator,
    list: *std.ArrayList(File),
    entry: anytype,
    stage_info: bool,
) !void {
    const file = try list.addOne();

    file.path = try allocator.dupe(u8, entry.path);

    if (stage_info) {
        file.object_id = ObjectId.init(.{});
        @memcpy(&file.object_id.?.bytes, &entry.hash);

        file.mode = entry.file_mode;
        file.merge_stage = entry.flags.stage;
    }
}

inline fn appendUntrackedFile(
    allocator: Allocator,
    list: *std.ArrayList(File),
    path: []const u8,
) !void {
    const file = try list.addOne();

    file.path = try allocator.dupe(u8, path);
    file.object_id = null;
    file.mode = null;
    file.merge_stage = null;
}
