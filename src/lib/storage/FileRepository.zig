// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! A repository implementation that uses the file-system with the Git rules.

const FileRepository = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.fs.cwd;

const index = @import("../index.zig");

const env = @import("env.zig");
const ObjectStore = @import("../ObjectStore.zig");
const Repository = @import("../Repository.zig");

const max_file_size = @import("../storage.zig").max_file_size;
const default_git_dir = ".git";
const index_file_name = "index";

/// Returns an instance of the repository interface.
pub fn interface(self: *FileRepository, objects: ObjectStore) Repository {
    return .{
        .ptr = self,
        .objects = objects,
        .openFn = open,
        .closeFn = destroy,
        .nameFn = name,
        .worktreeFn = worktree,
        .readIndexFn = readIndex,
    };
}

git_dir_path: []u8,
work_dir_path: ?[]u8 = null,

/// Creates a repository.
/// Use `destroy` to free up used resources.
pub fn create(allocator: Allocator, dir_name: ?[]const u8) !*FileRepository {
    const git_dir_path = try env.get(allocator, env.GIT_DIR) orelse try searchGitDirPath(allocator, dir_name);
    errdefer allocator.free(git_dir_path);

    std.log.debug("Using Git dir {s}", .{git_dir_path});
    const res = try allocator.create(FileRepository);
    res.git_dir_path = git_dir_path;
    return res;
}

/// Frees up used resources.
pub fn destroy(ptr: *anyopaque, allocator: Allocator) void {
    const self: *FileRepository = @ptrCast(@alignCast(ptr));
    allocator.free(self.git_dir_path);
    if (self.work_dir_path) |p| {
        allocator.free(p);
    }
    allocator.destroy(self);
}

/// Opens an existing repository.
/// Sets up the default worktree.
/// Use `destroy` to free up used resources.
pub fn open(ptr: *anyopaque, allocator: Allocator) !void {
    const self: *FileRepository = @ptrCast(@alignCast(ptr));

    // opens the directory to assert that exists
    var git_dir = try cwd().openDir(self.git_dir_path, .{});
    defer git_dir.close();

    if (std.mem.endsWith(u8, self.git_dir_path, default_git_dir)) {
        self.work_dir_path = try git_dir.realpathAlloc(allocator, "..");
    }
}

/// Returns the path of the repository.
pub fn name(ptr: *anyopaque) ?[]const u8 {
    const self: *FileRepository = @ptrCast(@alignCast(ptr));
    return self.git_dir_path;
}

/// Returns the path of the worktree, if available.
pub fn worktree(ptr: *anyopaque) ?[]const u8 {
    const self: *FileRepository = @ptrCast(@alignCast(ptr));
    return self.work_dir_path;
}

/// Returns the content of the index file.
/// Caller owns the returned memory.
pub fn readIndex(ptr: *anyopaque, allocator: Allocator) ![]u8 {
    const self: *FileRepository = @ptrCast(@alignCast(ptr));

    var paths = .{ self.git_dir_path, index_file_name };

    const file_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(file_path);

    const obj_file = try cwd().openFile(file_path, .{});
    defer obj_file.close();

    var stream = std.io.bufferedReader(obj_file.reader());
    const reader = stream.reader();

    return reader.readAllAlloc(allocator, max_file_size);
}

pub const SetupOptions = struct {
    /// Whether the repository is bare or has a working tree.
    bare: bool = false,
    /// The name to use for the initial branch, if it is created.
    initial_branch: []const u8 = "main",
    /// The name of the repository.
    /// It can be a path, an URL or something else.
    name: ?[]const u8 = null,
};

/// Creates the directory tree and initializes a repository.
/// Use `destroy` to free up used resources.
pub fn setup(allocator: Allocator, options: SetupOptions) !*FileRepository {
    if (options.name) |n| {
        try cwd().makePath(n);
    }

    const run_path = try cwd().realpathAlloc(allocator, options.name orelse ".");
    defer allocator.free(run_path);

    var dest_dir = try resolveCreateDestDir(allocator, run_path, options);
    defer dest_dir.close();

    try dest_dir.makePath("refs/heads");
    try dest_dir.makePath("refs/tags");

    var head = dest_dir.openFile("HEAD", .{}) catch |err| switch (err) {
        error.FileNotFound => try initHead(dest_dir, options.initial_branch),
        else => return err,
    };
    defer head.close();

    const git_dir_path = try dest_dir.realpathAlloc(allocator, ".");

    std.log.debug("Using Git dir {s}", .{git_dir_path});
    const res = try allocator.create(FileRepository);
    res.git_dir_path = git_dir_path;
    return res;
}

// Search the path of the .git directory from the current one
// or from `start_dir` if it has a value.
// Walks up the directory tree until it gets to ~ or /,
// looking for a .git directory at every step.
// Caller owns the returned memory.
fn searchGitDirPath(allocator: Allocator, start_dir: ?[]const u8) ![]u8 {
    var curr_dir = try cwd().openDir(start_dir orelse ".", .{});
    errdefer curr_dir.close();

    const root_path = try curr_dir.realpathAlloc(allocator, "/");
    defer allocator.free(root_path);

    const home_path = try getHomeDir(allocator);
    defer allocator.free(home_path);

    var curr_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const current_path = try curr_dir.realpath(".", &curr_buf);
        std.log.debug("Searching {s} in {s}", .{ default_git_dir, current_path });

        var git_dir = curr_dir.openDir(default_git_dir, .{}) catch {
            if (std.mem.eql(u8, home_path, current_path)) {
                std.log.debug("Reached user home, halting {s} search", .{default_git_dir});
                return error.GitDirNotFound;
            }

            if (std.mem.eql(u8, root_path, current_path)) {
                std.log.debug("Reached file-system root, halting {s} search", .{default_git_dir});
                return error.GitDirNotFound;
            }

            const parent = try curr_dir.openDir("..", .{});
            curr_dir.close();
            curr_dir = parent;
            continue;
        };
        defer git_dir.close();

        return git_dir.realpathAlloc(allocator, ".");
    }

    return error.GitDirNotFound;
}

// Resolves the destination directory to create a new repository.
// `run_path` is the directory from which to execute the command.
fn resolveCreateDestDir(allocator: Allocator, run_path: []u8, options: SetupOptions) !std.fs.Dir {
    if (options.bare) {
        return try cwd().openDir(run_path, .{});
    }

    const git_dir_path = try env.get(allocator, env.GIT_DIR);
    if (git_dir_path) |path| {
        defer allocator.free(path);
        return try cwd().openDir(path, .{});
    }

    const dest_path = try std.fs.path.join(allocator, &.{ run_path, default_git_dir });
    defer allocator.free(dest_path);

    try cwd().makePath(dest_path);
    return try cwd().openDir(dest_path, .{});
}

// Creates and opens the HEAD file pointing to the specified branch
fn initHead(git_dir: std.fs.Dir, branch_name: []const u8) !std.fs.File {
    var head = try git_dir.createFile("HEAD", .{ .exclusive = true });

    const head_writer = head.writer();
    try head_writer.print("ref: refs/heads/{s}\n", .{branch_name});

    std.log.debug("Using initial branch name {s}", .{branch_name});
    return head;
}

// Returns the user home directory based on the environment variables
fn getHomeDir(allocator: Allocator) ![]u8 {
    const home_env = comptime blk: {
        const os_tag = @import("builtin").os.tag;
        break :blk switch (os_tag) {
            // Note: in some versions of Windows HOME variable may be defined,
            // but it contains something as "/c/Users/name" and this may cause a
            // failure while comparing its content to paths retrived from opened
            // directories (that are in the form "C:\Users\name")
            .windows => env.HOME_WIN,
            else => env.HOME,
        };
    };

    return try env.get(allocator, home_env) orelse allocator.dupe(u8, "");
}
