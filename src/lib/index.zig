// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Functions for retrieving files based on tracking status and
//! for creating and populating index entries from the working tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("model/util/hash.zig");
const object = @import("object.zig");
const FileMode = @import("model/util/mode.zig").FileMode;
const Repository = @import("repository.zig").Repository;

/// Information about a file in the index or in the working directory.
pub fn File(comptime Hasher: type) type {
    return struct {
        /// Path in the filesystem.
        path: []const u8,
        /// Object ID (only included for tracked files)
        object_id: ?Repository(Hasher).Object.Id = null,
        /// File mode (only included for tracked files)
        mode: ?FileMode = null,
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
///
/// Because there is no support for standard Git exclusions,
/// when requesting untracked files through `others` option,
/// this function will return all files in the working directory that
/// are not tracked, including those that would be ignored.
pub fn list(
    io: Io,
    allocator: Allocator,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for reading the index.
    repository: Repository(Hasher),
    opts: *ListOptions,
) !std.ArrayList(File(Hasher)) {
    opts.check();

    var index = try repository.loadIndex(io, allocator);
    defer index.deinit(allocator);

    var res: std.ArrayList(File(Hasher)) = .empty;
    errdefer res.deinit(allocator);

    if (opts.others or opts.killed) {
        const worktree = repository.worktree();
        if (worktree == null) {
            return error.MissingWorktree;
        }

        var dir = try std.Io.Dir.cwd().openDir(io, worktree.?, .{ .iterate = true });
        defer dir.close(io);

        if (opts.others) {
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
                if (entry.kind == .file and !repository.isInternalPath(entry.path) and !index.contains(entry.path)) {
                    try appendUntrackedFile(allocator, Hasher, &res, entry.path);
                }
            }
        }

        if (opts.killed) {
            var walker = try dir.walk(allocator);
            defer walker.deinit();

            while (try walker.next(io)) |entry| {
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
                std.Io.Dir.cwd().access(io, entry.path, .{}) catch |err| switch (err) {
                    error.FileNotFound => try appendTrackedFile(allocator, Hasher, &res, entry, false),
                    else => return err,
                };
            } else if (opts.modified) {
                const stat = std.Io.Dir.cwd().statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
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
    const io = std.testing.io;
    const test_hasher = hash.Sha1;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Repository(test_hasher) = .{ .git = try .setup(io, tmp_path, "test", false, &env, allocator) };
    defer repo.deinit(allocator);

    var index: Repository(test_hasher).Index = .init();
    defer index.deinit(allocator);
    try repo.saveIndex(io, &index, allocator);

    var opts: ListOptions = .{ .cached = true };
    var file_list = try list(io, allocator, test_hasher, repo, &opts);
    defer {
        for (file_list.items) |*f| f.deinit(allocator);
        file_list.deinit(allocator);
    }

    try std.testing.expectEqual(0, file_list.items.len);
}

/// Creates an index entry for the file at `file_path`.
/// `file_path` is resolved from the current working directory.
/// Stats the file, writes the object to the database, and returns the entry.
/// Returns `error.NotARegularFile` if the path does not point to a regular file.
/// Caller owns the returned memory.
pub fn createEntry(
    io: Io,
    allocator: Allocator,
    comptime Hasher: type,
    repository: Repository(Hasher),
    file_path: []const u8,
) !Repository(Hasher).Index.Entry {
    const stat = try std.Io.Dir.cwd().statFile(io, file_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;

    const file_mode = fileModeFromStat(stat);

    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    var file_buf: [4 * 1024]u8 = undefined;
    var file_r = file.readerStreaming(io, &file_buf);
    const reader = &file_r.interface;

    const object_id = try object.create(io, allocator, reader, Hasher, repository, .blob, false);

    const maxU12 = std.math.maxInt(u12);
    return .{
        .ctime = @intCast(stat.ctime.nanoseconds),
        .mtime = @intCast(stat.mtime.nanoseconds),
        .device = 0,
        .inode = @truncate(stat.inode),
        .file_mode = file_mode,
        .user_id = 0,
        .group_id = 0,
        .file_size = @intCast(stat.size),
        .hash = object_id.bytes,
        .flags = .{ .name_length = @intCast(@min(file_path.len, maxU12)) },
        .path = try allocator.dupeZ(u8, file_path),
    };
}

fn fileModeFromStat(stat: std.Io.File.Stat) FileMode {
    const P = @TypeOf(stat.permissions);
    const is_executable = if (P.has_executable_bit) stat.permissions.toMode() & 0o111 != 0 else false;

    return .{
        .type = .regular_file,
        .permissions = if (is_executable)
            .{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .execute = true },
                .others = .{ .read = true, .execute = true },
            }
        else
            .{
                .user = .{ .read = true, .write = true },
                .group = .{ .read = true },
                .others = .{ .read = true },
            },
    };
}

test "createEntry populates entry from a regular file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_hasher = hash.Sha1;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Repository(test_hasher) = .{ .git = try .setup(io, tmp_path, "main", false, &env, allocator) };
    defer repo.deinit(allocator);

    // Write a file in the worktree using its absolute path
    const worktree = repo.worktree().?;
    const file_content = "Hello, Zig!\n";

    const full_path = try std.fs.path.join(allocator, &.{ worktree, "hello.txt" });
    defer allocator.free(full_path);

    const f = try std.Io.Dir.cwd().createFile(io, full_path, .{});
    var write_buf: [256]u8 = undefined;
    var w = f.writer(io, &write_buf);
    try w.interface.writeAll(file_content);
    try w.interface.flush();
    f.close(io);

    // createEntry uses cwd(), pass the absolute path so it resolves correctly
    var entry = try createEntry(io, allocator, test_hasher, repo, full_path);
    defer entry.deinit(allocator);

    try std.testing.expectEqual(file_content.len, entry.file_size);
    try std.testing.expectEqual(.regular_file, entry.file_mode.type);
    try std.testing.expectEqualStrings(full_path, entry.path);

    // Verify the object was written to the storage with the correct content
    const obj_id: Repository(test_hasher).Object.Id = .{ .bytes = entry.hash };
    var blob = try object.read(io, allocator, test_hasher, repo, &obj_id, .blob);
    defer blob.deinit(allocator);
    try std.testing.expectEqualStrings(file_content, blob.content);
}

test "createEntry returns error for a directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const test_hasher = hash.Sha1;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Repository(test_hasher) = .{ .git = try .setup(io, tmp_path, "main", false, &env, allocator) };
    defer repo.deinit(allocator);

    // Pass the worktree directory itself
    const worktree = repo.worktree().?;
    try std.testing.expectError(
        error.NotARegularFile,
        createEntry(io, allocator, test_hasher, repo, worktree),
    );
}
