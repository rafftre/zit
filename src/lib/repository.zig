// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("model/util/hash.zig");

pub const SetupOptions = struct {
    /// Whether the repository is bare or has a working tree.
    bare: bool = false,
    /// The name to use for the initial branch, if it is created (defaults to `main`).
    initial_branch: []const u8 = "main",
};

pub const Kind = enum { git };

/// Returns an interface for a repository that uses the specified hasher function.
pub fn Repository(comptime Hasher: type) type {
    return union(Kind) {
        git: GitRepository,

        const Self = @This();

        pub const Index = @import("model/index.zig").Index(Hasher);
        pub const Object = @import("model/object.zig").Object(Hasher);
        pub const LooseObject = @import("model/object.zig").LooseObject(Hasher);
        pub const GitRepository = @import("git_repository.zig").GitRepository(Hasher);

        /// Opens an existing repository.
        /// If `start_path` is missing, the current directory will be used to start searching for the repository.
        pub fn open(io: Io, kind: Kind, start_path: ?[]const u8, env: *std.process.Environ.Map, allocator: Allocator) !Self {
            return switch (kind) {
                .git => .{ .git = try .open(io, start_path, env, allocator) },
            };
        }

        /// Sets up all the initial structures needed for a repository.
        /// This is supposed to be performed on first use of a new repository,
        /// but can be done again to recover corrupted structures.
        /// If `start_path` is missing, the current directory will be used to start searching for the repository.
        pub fn setup(
            io: Io,
            kind: Kind,
            start_path: ?[]const u8,
            options: SetupOptions,
            env: *std.process.Environ.Map,
            allocator: Allocator,
        ) !Self {
            return switch (kind) {
                .git => .{
                    .git = try .setup(
                        io,
                        start_path,
                        options.initial_branch,
                        options.bare,
                        env,
                        allocator,
                    ),
                },
            };
        }

        /// Calls `deinit` on the child object.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (self.*) {
                inline else => |*s| s.*.deinit(allocator),
            }
        }

        /// Returns the name of the repository.
        /// It can be a path, an URL or something else - the implementation determines that.
        pub fn name(self: *const Self) ?[]const u8 {
            switch (self.*) {
                inline else => |*s| return s.*.name(),
            }
        }

        /// Returns the path of the worktree, if available.
        pub fn worktree(self: *const Self) ?[]const u8 {
            switch (self.*) {
                inline else => |*s| return s.*.worktree(),
            }
        }

        /// Returns `true` if `relative_path` (relative to the worktree root) is
        /// inside the repository's internal directory (e.g. `.git/`).
        pub fn isInternalPath(self: *const Self, relative_path: []const u8) bool {
            switch (self.*) {
                inline else => |*s| return s.*.isInternalPath(relative_path),
            }
        }

        /// Loads in memory and returns the index.
        /// Caller owns the returned memory.
        pub fn loadIndex(self: *const Self, io: Io, allocator: Allocator) !Index {
            switch (self.*) {
                inline else => |*s| return s.*.loadIndex(io, allocator),
            }
        }

        /// Writes the index to the file in the repository.
        pub fn saveIndex(self: *const Self, io: Io, index: *const Index, allocator: Allocator) !void {
            switch (self.*) {
                inline else => |*s| try s.*.saveIndex(io, index, allocator),
            }
        }

        /// Reads an object from the store.
        pub fn readObject(
            self: *const Self,
            io: Io,
            writer: *std.Io.Writer,
            object_id: *const Object.Id,
            allocator: Allocator,
        ) !void {
            switch (self.*) {
                inline else => |*s| try s.*.readObject(io, writer, object_id, allocator),
            }
        }

        /// Writes an object to the store.
        /// A temporary file is first created and then moved to the destination.
        pub fn writeObject(
            self: *const Self,
            io: Io,
            reader: *std.Io.Reader,
            object_id: *const Object.Id,
            allocator: Allocator,
        ) !void {
            switch (self.*) {
                inline else => |*s| try s.*.writeObject(io, reader, object_id, allocator),
            }
        }
    };
}

test "git open via repository interface" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1Repository = Repository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try tmp.dir.createDir(io, ".git", .default_dir);

    const test_repo_path = try tmp.dir.realPathFileAlloc(io, ".git", allocator);
    defer allocator.free(test_repo_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Sha1Repository = try .open(io, .git, tmp_path, &env, allocator);
    defer repo.deinit(allocator);

    try std.testing.expectEqualStrings(test_repo_path, repo.name().?);

    const test_worktree_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(test_worktree_path);

    try std.testing.expectEqualStrings(test_worktree_path, repo.worktree().?);
}
