// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Functions for retrieving files based on tracking status.

const std = @import("std");
const Allocator = std.mem.Allocator;

const IndexSha1 = @import("index.zig").IndexSha1;
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

/// Retrieves the list of all tracked files (cached in the index).
/// Caller owns the returned memory.
pub fn listCached(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    for (index.entries.items) |entry| {
        try appendTrackedFile(allocator, &res, entry);
    }

    return res;
}

/// Retrieves the list of all files with an unstaged modification (including deletion).
/// Caller owns the returned memory.
pub fn listModified(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const worktree = repository.worktree();
    if (worktree == null) {
        return error.MissingWorktree;
    }

    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    for (index.entries.items) |entry| {
        const stat = std.fs.cwd().statFile(entry.path) catch |err| switch (err) {
            error.FileNotFound => {
                try appendTrackedFile(allocator, &res, entry);
                continue;
            },
            error.NotDir => continue,
            else => return err,
        };

        if (entry.isChanged(stat)) {
            try appendTrackedFile(allocator, &res, entry);
        }
    }

    return res;
}

/// Retrieves the list of all files with an unstaged deletion.
/// Caller owns the returned memory.
pub fn listDeleted(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const worktree = repository.worktree();
    if (worktree == null) {
        return error.MissingWorktree;
    }

    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    for (index.entries.items) |entry| {
        std.fs.cwd().access(entry.path, .{}) catch |err| switch (err) {
            error.FileNotFound => try appendTrackedFile(allocator, &res, entry),
            else => return err,
        };
    }

    return res;
}

/// Retrieves the list of unmerged files only, without including other tracked files.
/// Caller owns the returned memory.
pub fn listUnmerged(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    for (index.entries.items) |entry| {
        if (entry.isUnmerged()) {
            try appendTrackedFile(allocator, &res, entry);
        }
    }

    return res;
}

/// Retrieves the list of all untracked files (other than those cached in the index).
/// Caller owns the returned memory.
pub fn listOthers(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const worktree = repository.worktree();
    if (worktree == null) {
        return error.MissingWorktree;
    }

    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    var dir = try std.fs.cwd().openDir(worktree.?, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // FIXME: remove use of ".git" path (move to repository?)
        if (entry.kind == .file and !std.mem.startsWith(u8, entry.path, ".git") and !index.contains(entry.path)) {
            try appendUntrackedFile(allocator, &res, entry.path);
        }
    }

    std.mem.sort(File, res.items, {}, File.lessThan);

    return res;
}

/// Retrieves the list of all untracked files conflicting with tracked ones.
/// The files in the returned list need to be removed before
/// the tracked files can be written to the filesystem.
/// Caller owns the returned memory.
pub fn listKilled(allocator: Allocator, repository: anytype) !std.ArrayList(File) {
    const worktree = repository.worktree();
    if (worktree == null) {
        return error.MissingWorktree;
    }

    const index = try repository.loadIndex(allocator);
    defer index.deinit();

    var res = std.ArrayList(File).init(allocator);
    errdefer res.deinit();

    var dir = try std.fs.cwd().openDir(worktree.?, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        // FIXME: remove use of ".git" path (move to repository?)
        if (!std.mem.startsWith(u8, entry.path, ".git") and index.containsPrefix(entry.path, true)) {
            try appendUntrackedFile(allocator, &res, entry.path);
        }
    }

    std.mem.sort(File, res.items, {}, File.lessThan);

    return res;
}

inline fn appendTrackedFile(
    allocator: Allocator,
    list: *std.ArrayList(File),
    entry: IndexSha1.Entry,
) !void {
    const file = try list.addOne();

    file.path = try allocator.dupe(u8, entry.path);

    file.object_id = ObjectId.init(.{});
    @memcpy(&file.object_id.?.bytes, &entry.hash);

    file.mode = entry.file_mode;
    file.merge_stage = entry.flags.stage;
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
