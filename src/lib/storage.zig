// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for the storage of repositories and object databases.
//! Provides utility functions for opening a repository or creating a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.fs.cwd;

const ObjectStore = @import("object_store.zig").ObjectStore;
const Repository = @import("repository.zig").RepositorySha1;

pub const FileObjectStore = @import("storage/FileObjectStore.zig");
pub const file_repository = @import("storage/file_repository.zig");
const FileRepository = file_repository.FileRepositorySha1;

pub const max_file_size: usize = 1024 * 1024 * 1024;
pub const small_file_size: usize = 32 * 1024;

/// Opens an existing Git repository.
/// Search the repository on the file-system starting from `start_dir_name`,
/// or from the current directory if not specified.
/// Free with `close`.
pub fn openGitRepository(allocator: Allocator, start_dir_name: ?[]const u8) !*Repository {
    const store = try allocator.create(ObjectStore);
    errdefer allocator.destroy(store);

    const repo = try allocator.create(Repository);
    errdefer allocator.destroy(repo);

    repo.file = .{};
    store.file = .{};

    try repo.file.init(allocator, start_dir_name, store);
    errdefer repo.file.deinit(allocator);

    try store.file.init(allocator, repo.file.git_dir_path);
    errdefer store.file.deinit(allocator);

    try repo.open(allocator);

    return repo;
}

pub fn closeGitRepository(allocator: Allocator, repo: *Repository) void {
    // TODO: switch on union

    const store = repo.objectStore();
    store.file.deinit(allocator);
    allocator.destroy(store);

    repo.file.deinit(allocator);
    allocator.destroy(repo);
}

pub const CreateOptions = struct {
    /// Whether the repository is bare or has a working tree.
    bare: bool = false,
    /// The name to use for the initial branch, if it is created.
    initial_branch: []const u8 = "main",
    /// The name of the repository.
    name: ?[]const u8 = null,
};

/// Creates an empty Git repository or reinitializes an existing one.
/// The repository will be created on the file-system
/// in the directory `options.name` (or in the current directory when not specified)
/// and with an in initial branch named `options.initial_branch` (or `main` when not specified).
/// Free with `close`.
pub fn createGitRepository(allocator: Allocator, options: CreateOptions) !*Repository {
    const store = try allocator.create(ObjectStore);
    errdefer allocator.destroy(store);

    const repo = try allocator.create(Repository);
    errdefer allocator.destroy(repo);

    repo.file = .{};
    store.file = .{};

    const git_dir_path = try createPathForSetup(allocator, options);
    defer allocator.free(git_dir_path);

    try repo.file.init(allocator, git_dir_path, store);
    errdefer repo.file.deinit(allocator);

    try store.file.init(allocator, repo.file.git_dir_path);
    errdefer store.file.deinit(allocator);

    try repo.setup(options.initial_branch);
    try store.setup();

    try repo.open(allocator);

    return repo;
}

// Caller owns the returned memory.
fn createPathForSetup(allocator: Allocator, options: CreateOptions) ![]u8 {
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

test {
    @import("std").testing.refAllDecls(@This());
}
