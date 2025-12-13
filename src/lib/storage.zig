// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for the storage of repositories and object databases.
//! Provides utility functions for opening a repository or creating a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.fs.cwd;

const hash = @import("helpers.zig").hash;

const git_repo = @import("storage/git_repository.zig");

pub const max_file_size: usize = 1024 * 1024 * 1024;
pub const small_file_size: usize = 32 * 1024;

pub const SetupOptions = struct {
    /// Whether the repository is bare or has a working tree.
    bare: bool = false,
    /// The name to use for the initial branch, if it is created (defaults to `main`).
    initial_branch: []const u8 = "main",
    /// The name of the repository.
    name: ?[]const u8 = null,
};

pub const GitRepositorySha1 = GitRepository(hash.Sha1);
pub const GitRepositorySha256 = GitRepository(hash.Sha256);

pub fn GitRepository(comptime Hasher: type) type {
    return struct {
        repo: Repository,
        store: ObjectStore,

        const Self = @This();

        pub const Repository = @import("repository.zig").Repository(Hasher);
        pub const ObjectStore = @import("object_store.zig").ObjectStore;

        /// Opens an existing Git repository.
        /// Search the repository on the file-system starting from `dir_name`,
        /// or from the current directory if not specified.
        /// Free with `close`.
        pub fn open(allocator: Allocator, dir_name: ?[]const u8) !*Self {
            const self = try allocator.create(Self);

            self.repo = .{ .git = .{} };
            self.store = .{ .git = .{} };

            try self.repo.git.init(allocator, dir_name);
            errdefer self.repo.git.deinit(allocator);

            try self.store.git.init(allocator, self.repo.git.git_dir_path);
            errdefer self.store.git.deinit(allocator);

            try self.repo.open(allocator);

            return self;
        }

        /// Creates an empty Git repository or reinitializes an existing one.
        /// The repository will be created on the file-system
        /// in the directory `options.name` (or in the current directory when not specified)
        /// and with an in initial branch named as `options.initial_branch` (or `main` when not specified).
        /// Free with `close`.
        pub fn setup(allocator: Allocator, options: SetupOptions) !*Self {
            const self = try allocator.create(Self);

            self.repo = .{ .git = .{} };
            self.store = .{ .git = .{} };

            try self.repo.git.initForSetup(allocator, options.name, options.bare);
            errdefer self.repo.git.deinit(allocator);

            try self.store.git.init(allocator, self.repo.git.git_dir_path);
            errdefer self.store.git.deinit(allocator);

            try self.repo.setup(options.initial_branch);
            try self.store.setup();

            try self.repo.open(allocator);

            return self;
        }

        /// Close the Git repository and frees referenced resources.
        pub fn close(self: *const Self, allocator: Allocator) void {
            self.store.git.deinit(allocator);
            self.repo.git.deinit(allocator);

            allocator.destroy(self);
        }
    };
}

test {
    @import("std").testing.refAllDecls(@This());
}
