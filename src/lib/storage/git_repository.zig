// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;
const cwd = std.fs.cwd;

const env = @import("env.zig");
const Sha1 = @import("../helpers.zig").hash.Sha1;

const max_file_size = @import("../storage.zig").max_file_size;
const DEFAULT_GIT_DIR_NAME = ".git";
const REFS_HEADS_DIR_NAME = "refs/heads";
const REFS_TAGS_DIR_NAME = "refs/tags";
const INDEX_FILE_NAME = "index";
const HEAD_FILE_NAME = "HEAD";

/// Returns a repository implementation that uses the file-system
/// with the Git rules and uses the specified hasher function.
pub fn GitRepository(comptime Hasher: type) type {
    return struct {
        git_dir_path: []u8 = undefined,
        work_dir_path: ?[]u8 = null,

        const Self = @This();
        const Index = @import("../index.zig").Index(Hasher);

        /// Initializes this struct searching an existing .git directory.
        /// Search the path of the .git directory from from `dir_name` or the current directory.
        /// Use `deinit` to free up used resources.
        pub fn init(self: *Self, allocator: Allocator, dir_name: ?[]const u8) !void {
            const git_dir_path = try env.get(allocator, env.GIT_DIR) orelse try searchGitDirPath(allocator, dir_name);
            errdefer allocator.free(git_dir_path);

            std.log.debug("Using Git dir {s}", .{git_dir_path});
            self.git_dir_path = git_dir_path;
        }

        /// Initializes this struct initializing a .git directory.
        /// The path of the .git directory is resolved from `dir_name` or from the current directory.
        /// If `bare`, the destination path will be used to host the repository directly
        /// instead of using the .git directory.
        /// Use `deinit` to free up used resources.
        pub fn initForSetup(self: *Self, allocator: Allocator, dir_name: ?[]const u8, bare: bool) !void {
            const git_dir_path = try resolveGitDirPathToCreate(allocator, dir_name, bare);
            errdefer allocator.free(git_dir_path);

            std.log.debug("Using Git dir {s}", .{git_dir_path});
            self.git_dir_path = git_dir_path;
        }

        /// Frees up used resources.
        pub fn deinit(self: *const Self, allocator: Allocator) void {
            allocator.free(self.git_dir_path);
            if (self.work_dir_path) |p| {
                allocator.free(p);
            }
        }

        /// Creates the directory tree on the file system.
        pub fn setup(self: *const Self, initial_branch_name: []const u8) !void {
            var git_dir = try cwd().openDir(self.git_dir_path, .{});
            defer git_dir.close();

            try git_dir.makePath(REFS_HEADS_DIR_NAME);
            try git_dir.makePath(REFS_TAGS_DIR_NAME);

            git_dir.access(HEAD_FILE_NAME, .{}) catch |err| switch (err) {
                error.FileNotFound => try initHead(git_dir, initial_branch_name),
                else => return err,
            };
        }

        /// Opens an existing repository and sets up the default worktree.
        pub fn open(self: *Self, allocator: Allocator) !void {
            // opens the directory to assert that exists
            var git_dir = try cwd().openDir(self.git_dir_path, .{});
            defer git_dir.close();

            if (std.mem.endsWith(u8, self.git_dir_path, DEFAULT_GIT_DIR_NAME)) {
                self.work_dir_path = try git_dir.realpathAlloc(allocator, "..");
            }
        }

        /// Returns the path of the repository.
        pub fn name(self: *const Self) ?[]const u8 {
            return self.git_dir_path;
        }

        /// Returns the path of the worktree, if available.
        pub fn worktree(self: *const Self) ?[]const u8 {
            return self.work_dir_path;
        }

        /// Loads in memory and returns the index.
        /// Caller owns the returned memory.
        pub fn loadIndex(self: *const Self, allocator: Allocator) !Index {
            const index_content = try self.readIndex(allocator);
            defer allocator.free(index_content);

            return Index.parse(allocator, index_content);
        }

        /// Returns the raw content of the index file.
        /// Caller owns the returned memory.
        fn readIndex(self: *const Self, allocator: Allocator) ![]u8 {
            var paths = .{ self.git_dir_path, INDEX_FILE_NAME };

            const file_path = try std.fs.path.join(allocator, &paths);
            defer allocator.free(file_path);

            const obj_file = try cwd().openFile(file_path, .{});
            defer obj_file.close();

            var stream = std.io.bufferedReader(obj_file.reader());
            const reader = stream.reader();

            return reader.readAllAlloc(allocator, max_file_size);
        }
    };
}

// Resolves the destination path of the .git directory to create a new repository.
// The resolution starts from `name` or from the current directory when not specified.
// The directory `name` will be created if not exists.
// When `bare` is true uses the destination path as the .git directory.
// Caller owns the returned memory.
fn resolveGitDirPathToCreate(allocator: Allocator, name: ?[]const u8, bare: bool) ![]u8 {
    if (name) |n| {
        try cwd().makePath(n);
    }

    const start_path = try cwd().realpathAlloc(allocator, name orelse ".");
    if (bare) {
        return start_path;
    }
    defer allocator.free(start_path);

    const git_dir_path = try env.get(allocator, env.GIT_DIR);
    if (git_dir_path) |path| {
        defer allocator.free(path);
        return try std.fs.realpathAlloc(allocator, path);
    }

    const dest_path = try std.fs.path.join(allocator, &.{ start_path, DEFAULT_GIT_DIR_NAME });
    defer allocator.free(dest_path);

    try cwd().makePath(dest_path);

    return try std.fs.realpathAlloc(allocator, dest_path);
}

// Search the path of the .git directory from the current one
// or from `start_path` if it has a value.
// Walks up the directory tree until it gets to ~ or /,
// looking for a .git directory at every step.
// Caller owns the returned memory.
fn searchGitDirPath(allocator: Allocator, start_path: ?[]const u8) ![]u8 {
    var curr_dir = try cwd().openDir(start_path orelse ".", .{});
    errdefer curr_dir.close();

    const root_path = try curr_dir.realpathAlloc(allocator, "/");
    defer allocator.free(root_path);

    const home_path = try getHomeDir(allocator);
    defer allocator.free(home_path);

    var curr_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const current_path = try curr_dir.realpath(".", &curr_buf);
        std.log.debug("Searching {s} in {s}", .{ DEFAULT_GIT_DIR_NAME, current_path });

        var git_dir = curr_dir.openDir(DEFAULT_GIT_DIR_NAME, .{}) catch {
            if (std.mem.eql(u8, home_path, current_path)) {
                std.log.debug("Reached user home, halting {s} search", .{DEFAULT_GIT_DIR_NAME});
                return error.GitDirNotFound;
            }

            if (std.mem.eql(u8, root_path, current_path)) {
                std.log.debug("Reached file-system root, halting {s} search", .{DEFAULT_GIT_DIR_NAME});
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

// Creates and opens the HEAD file pointing to the specified branch
fn initHead(git_dir: std.fs.Dir, branch_name: []const u8) !void {
    const head = try git_dir.createFile(HEAD_FILE_NAME, .{ .exclusive = true });
    defer head.close();

    const head_writer = head.writer();
    try head_writer.print("ref: refs/heads/{s}\n", .{branch_name});

    std.log.debug("Using initial branch name {s}", .{branch_name});
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

const Sha1GitRepository = GitRepository(Sha1);

test "repository setup" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    const git_dir_path = try resolveGitDirPathToCreate(allocator, test_dir_path, false);
    defer allocator.free(git_dir_path);

    var repo: Sha1GitRepository = .{};

    try repo.init(allocator, test_dir_path);
    defer repo.deinit(allocator);

    try repo.setup("test");

    const head_file_name = DEFAULT_GIT_DIR_NAME ++ "/" ++ HEAD_FILE_NAME;

    const head_file = try tmp.dir.openFile(head_file_name, .{});
    defer head_file.close();

    var stream = std.io.bufferedReader(head_file.reader());
    const reader = stream.reader();

    const head_content = try reader.readAllAlloc(allocator, max_file_size);
    defer allocator.free(head_content);

    try std.testing.expect(std.mem.eql(u8, head_content, "ref: refs/heads/test\n"));

    // TODO: test re-run
}
