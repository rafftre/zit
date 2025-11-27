// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for the storage of repositories and object databases.
//! Provides utility functions for opening a repository or creating a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.fs.cwd;

const hash = @import("helpers.zig").hash;
const object_store = @import("object_store.zig");
const repository = @import("repository.zig");

pub const ObjectStore = object_store.ObjectStore;
// pub const Repository = repository.Repository;

const FileObjectStore = @import("storage/FileObjectStore.zig");
const file_repository = @import("storage/file_repository.zig");
const FileRepository = file_repository.FileRepositorySha1;

pub const max_file_size: usize = 1024 * 1024 * 1024;
pub const small_file_size: usize = 32 * 1024;

pub const SetupOptions = struct {
    /// Whether the repository is bare or has a working tree.
    bare: bool = false,
    /// The name to use for the initial branch, if it is created.
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
        const Repository = repository.Repository(Hasher);

        /// Opens an existing Git repository.
        /// Search the repository on the file-system starting from `start_dir_name`,
        /// or from the current directory if not specified.
        /// Free with `close`.
        pub fn open(allocator: Allocator, start_dir_name: ?[]const u8) !*Self {
            const self = try allocator.create(Self);

            self.repo = .{ .file = .{} };
            self.store = .{ .file = .{} };

            try self.repo.file.init(allocator, start_dir_name, &self.store);
            errdefer self.repo.file.deinit(allocator);

            try self.store.file.init(allocator, self.repo.file.git_dir_path);
            errdefer self.store.file.deinit(allocator);

            try self.repo.open(allocator);

            return self;
        }

        /// Creates an empty Git repository or reinitializes an existing one.
        /// The repository will be created on the file-system
        /// in the directory `options.name` (or in the current directory when not specified)
        /// and with an in initial branch named `options.initial_branch` (or `main` when not specified).
        /// Free with `close`.
        pub fn setup(allocator: Allocator, options: SetupOptions) !*Self {
            const self = try allocator.create(Self);

            self.repo = .{ .file = .{} };
            self.store = .{ .file = .{} };

            const git_dir_path = try createPathForSetup(allocator, options);
            defer allocator.free(git_dir_path);

            try self.repo.file.init(allocator, git_dir_path, &self.store);
            errdefer self.repo.file.deinit(allocator);

            try self.store.file.init(allocator, self.repo.file.git_dir_path);
            errdefer self.store.file.deinit(allocator);

            try self.repo.setup(options.initial_branch);
            try self.store.setup();

            try self.repo.open(allocator);

            return self;
        }

        pub fn close(self: *const Self, allocator: Allocator) void {
            self.store.file.deinit(allocator);
            self.repo.file.deinit(allocator);

            allocator.destroy(self);
        }
    };
}

// Caller owns the returned memory.
fn createPathForSetup(allocator: Allocator, options: SetupOptions) ![]u8 {
    if (options.name) |n| {
        try cwd().makePath(n);
    }

    const start_path = try cwd().realpathAlloc(allocator, options.name orelse ".");
    defer allocator.free(start_path);

    const git_dir_path = try file_repository.resolveDestDirToCreate(allocator, start_path, options.bare);
    errdefer allocator.free(git_dir_path);

    try cwd().makePath(git_dir_path);

    return git_dir_path;
}

// /// Allocates and initializes a new repository that uses the file-system.
// /// It also allocates and initializes an object store of the same type.
// /// Returned memory is owned by the caller.
// fn createFileRepository(allocator: Allocator, dir_name: ?[]const u8) !*Repository {
//     const repo = try allocator.create(Repository);
//     errdefer allocator.destroy(repo);

//     const store = try allocator.create(ObjectStore);
//     errdefer allocator.destroy(store);

//     repo.file = .{};
//     store.file = .{};

//     try repo.file.init(allocator, dir_name, store);
//     errdefer repo.file.deinit(allocator);

//     try store.file.init(allocator, repo.file.git_dir_path);
//     errdefer store.file.deinit(allocator);

//     return repo;
// }

// /// Allocates and initializes a new object store that uses the file-system.
// /// Returned memory is owned by the caller.
// fn createFileObjectStore(allocator: Allocator, git_dir_path: []u8) !*ObjectStore {
//     const store = try allocator.create(ObjectStore);
//     errdefer allocator.destroy(store);

//     store.file = .{};
//     try store.file.init(allocator, git_dir_path);

//     return store;
// }

test {
    @import("std").testing.refAllDecls(@This());
}
