// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Logic for the ls-files command.

const std = @import("std");
const Allocator = std.mem.Allocator;

const IndexSha1 = @import("index.zig").IndexSha1;
const MergeStage = @import("index.zig").MergeStage;
const ObjectId = @import("model.zig").ObjectId;
const FileMode = @import("helpers.zig").file.Mode;

/// An item of the list retured by `readFiles`.
pub const File = struct {
    path: []const u8,
    object_id: ?ObjectId = null,
    mode: ?FileMode = null,
    merge_stage: ?MergeStage = null,

    /// Comparison function for use with `std.mem.sort`.
    /// Sort files in ascending order on the path field.
    fn lessThan(_: void, lhs: File, rhs: File) bool {
        return std.mem.order(u8, lhs.path, rhs.path) == .lt;
    }
};

/// Options for `readFiles`.
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
    add_stage_info: bool = false,

    /// Validites the combination of options.
    fn check(self: *ListFilesOptions, repository: anytype) void {
        if (self.modified or self.others or self.deleted or self.killed) {
            if (repository.worktree() == null) {
                // TODO: setup a work tree
            }
        }

        // forces stage information when unmerged files are requested
        if (self.unmerged) {
            self.add_stage_info = true;
        }

        // default to cached when other flags are missing
        if (!(self.cached or self.others or self.add_stage_info or self.deleted or self.modified or self.unmerged or self.killed)) {
            self.cached = true;
        }
    }
};

/// Retrieves a list of files in the index and working directory.
/// The returned list is a combination of files built according to the specified options.
/// For this reason, a file may be reported multiple times.
/// Caller owns the returned memory.
pub fn listFiles(allocator: Allocator, repository: anytype, opts: *ListFilesOptions) !std.ArrayList(File) {
    opts.check(repository);

    const index_content = try repository.readIndex(allocator);
    defer allocator.free(index_content);

    const index = try IndexSha1.parse(allocator, index_content);
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
                    _ = try appendUntrackedFile(allocator, &res, entry.path);
                }
            }
        }

        if (opts.killed) {
            while (try walker.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.path, ".git") and index.containsPrefix(entry.path, true)) {
                    _ = try appendUntrackedFile(allocator, &res, entry.path);
                }
            }
        }

        std.mem.sort(File, res.items, {}, File.lessThan);
    }

    if (!opts.cached and !opts.add_stage_info and !opts.deleted and !opts.modified) {
        return res;
    }

    for (index.entries.items) |entry| {
        if (opts.deleted or opts.modified) {
            const stat = std.fs.cwd().statFile(entry.path) catch |err| switch (err) {
                error.FileNotFound => {
                    _ = try appendTrackedFile(allocator, &res, entry, false);
                    continue;
                },
                error.NotDir => continue,
                else => return err,
            };
            if (opts.modified and entry.isChanged(stat)) {
                _ = try appendTrackedFile(allocator, &res, entry, false);
            }
        } else if ((opts.cached or opts.add_stage_info) and (!opts.unmerged or entry.isUnmerged())) {
            _ = try appendTrackedFile(allocator, &res, entry, opts.add_stage_info);
        }
    }

    return res;
}

inline fn appendTrackedFile(
    allocator: Allocator,
    list: *std.ArrayList(File),
    entry: IndexSha1.Entry,
    add_stage_info: bool,
) !*File {
    const file = try list.addOne();

    file.path = try allocator.dupe(u8, entry.path);

    if (add_stage_info) {
        file.object_id = ObjectId.init(.{});
        @memcpy(&file.object_id.?.bytes, &entry.hash);

        file.mode = entry.file_mode;
        file.merge_stage = entry.flags.stage;
    }

    return file;
}

inline fn appendUntrackedFile(
    allocator: Allocator,
    list: *std.ArrayList(File),
    path: []const u8,
) !*File {
    const file = try list.addOne();

    file.path = try allocator.dupe(u8, path);
    file.object_id = null;
    file.mode = null;
    file.merge_stage = null;

    return file;
}
