// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

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
        pub const GitRepository = @import("model/git_repository.zig").GitRepository(Hasher);

        /// Opens an existing repository.
        /// If `start_path` is missing, the current directory will be used to start searching for the repository.
        pub fn open(allocator: Allocator, kind: Kind, start_path: ?[]const u8) !Self {
            return switch (kind) {
                .git => .{ .git = try .open(allocator, start_path) },
            };
        }

        /// Sets up all the initial structures needed for a repository.
        /// This is supposed to be performed on first use of a new repository,
        /// but can be done again to recover corrupted structures.
        /// If `start_path` is missing, the current directory will be used to start searching for the repository.
        pub fn setup(allocator: Allocator, kind: Kind, start_path: ?[]const u8, options: SetupOptions) !Self {
            return switch (kind) {
                .git => .{
                    .git = try .setup(allocator, start_path, options.initial_branch, options.bare),
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

        /// Loads in memory and returns the index.
        /// Caller owns the returned memory.
        pub fn loadIndex(self: *const Self, allocator: Allocator) !Index {
            switch (self.*) {
                inline else => |*s| return try s.*.loadIndex(allocator),
            }
        }

        /// Reads an object from the store.
        /// Deinitialize with `deinit`.
        pub fn readObject(
            self: *const Self,
            allocator: Allocator,
            writer: *std.Io.Writer,
            object_id: *Object.Id,
        ) !void {
            switch (self.*) {
                inline else => |*s| try s.*.readObject(allocator, writer, object_id),
            }
        }

        /// Writes an object to the store.
        /// A temporary file is first created and then moved to the destination.
        pub fn writeObject(
            self: *const Self,
            allocator: Allocator,
            reader: *std.Io.Reader,
            object_id: *Object.Id,
        ) !void {
            switch (self.*) {
                inline else => |*s| try s.*.writeObject(allocator, reader, object_id),
            }
        }
    };
}

test "git open via repository interface" {
    const allocator = std.testing.allocator;
    const Sha1Repository = Repository(hash.Sha1);

    var repo: Sha1Repository = try .open(allocator, .git, null);
    defer repo.deinit(allocator);

    const test_repo_path = try std.fs.cwd().realpathAlloc(allocator, ".git");
    defer allocator.free(test_repo_path);

    try std.testing.expectEqualStrings(test_repo_path, repo.name().?);

    const test_worktree_path = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(test_worktree_path);

    try std.testing.expectEqualStrings(test_worktree_path, repo.worktree().?);
}
