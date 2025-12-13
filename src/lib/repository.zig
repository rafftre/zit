// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const index = @import("index.zig");
const GitRepository = @import("storage/git_repository.zig").GitRepository;

/// Returns an interface for a repository that uses the specified hasher function.
pub fn Repository(comptime Hasher: type) type {
    return union(enum) {
        git: Git,

        const Self = @This();

        pub const Index = index.Index(Hasher);
        pub const Git = GitRepository(Hasher);

        /// Sets up all the initial structures needed for a repository.
        /// This is supposed to be performed on first use of a new repository,
        /// but can be done again to recover corrupted structures.
        pub fn setup(self: *Self, initial_branch_name: []const u8) !void {
            switch (self.*) {
                inline else => |*s| try s.*.setup(initial_branch_name),
            }
        }

        /// Opens an existing repository and sets up the default worktree.
        pub fn open(self: *Self, allocator: Allocator) !void {
            switch (self.*) {
                inline else => |*s| try s.*.open(allocator),
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
                inline else => |*s| return s.*.loadIndex(allocator),
            }
        }
    };
}
