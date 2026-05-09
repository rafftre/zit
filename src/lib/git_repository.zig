// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const builtin = @import("builtin");
const flate = std.compress.flate;
const cwd = std.Io.Dir.cwd;
const path = std.fs.path;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const hash = @import("model/util/hash.zig");

pub const small_file_size: usize = 32 * 1024;

const default_git_dir_name = ".git";
const objects_dir_name = "objects";
const info_dir_name = "info";
const pack_dir_name = "pack";
const refs_dir_name = "refs";
const heads_dir_name = "heads";
const tags_dir_name = "tags";
const index_file_name = "index";
const head_file_name = "HEAD";

const GIT_DIR_ENV = "GIT_DIR";
const GIT_OBJECT_DIR_ENV = "GIT_OBJECT_DIRECTORY";

/// Returns a repository implementation that uses the file-system
/// with the Git rules and uses the specified hasher function.
pub fn GitRepository(comptime Hasher: type) type {
    return struct {
        git_dir_path: []u8 = undefined,
        objects_dir_path: []u8 = undefined,
        work_dir_path: ?[]u8 = null,

        const Self = @This();
        const Index = @import("model/index.zig").Index(Hasher);

        pub const Object = @import("model/object.zig").Object(Hasher);
        pub const LooseObject = @import("model/object.zig").LooseObject(Hasher);

        /// Opens a Git repository searching an existing .git directory.
        /// Search the path of the .git directory from from `start_path` or the current directory.
        /// Use `deinit` to free up used resources.
        pub fn open(io: Io, start_path: ?[]const u8, env: *std.process.Environ.Map, allocator: Allocator) !Self {
            const git_dir_path = if (env.get(GIT_DIR_ENV)) |p|
                try allocator.dupe(u8, p)
            else
                try searchGitDirPath(io, start_path, env, allocator);
            errdefer allocator.free(git_dir_path);

            const objects_dir_path = if (env.get(GIT_OBJECT_DIR_ENV)) |p|
                try allocator.dupe(u8, p)
            else
                try path.join(allocator, &.{ git_dir_path, objects_dir_name });
            errdefer allocator.free(objects_dir_path);

            var res: Self = .{
                .git_dir_path = git_dir_path,
                .objects_dir_path = objects_dir_path,
            };
            std.log.debug("Using Git dir {s}", .{res.git_dir_path});

            // opens the directory to assert that exists
            var git_dir = try cwd().openDir(io, res.git_dir_path, .{});
            defer git_dir.close(io);

            if (std.mem.endsWith(u8, res.git_dir_path, default_git_dir_name)) {
                res.work_dir_path = try realPathFileAlloc(git_dir, io, "..", allocator);
            }

            return res;
        }

        /// Initializes a Git repository creating the directory tree on the file system.
        /// The path of the .git directory is resolved from `start_path` or from the current directory.
        /// If `bare`, the destination path will be used to host the repository directly
        /// instead of using the .git directory.
        /// Use `deinit` to free up used resources.
        pub fn setup(
            io: Io,
            start_path: ?[]const u8,
            initial_branch_name: []const u8,
            bare: bool,
            env: *std.process.Environ.Map,
            allocator: Allocator,
        ) !Self {
            const git_dir_path = try resolveGitDirPathToCreate(io, start_path, bare, env, allocator);
            errdefer allocator.free(git_dir_path);

            const objects_dir_path = if (env.get(GIT_OBJECT_DIR_ENV)) |p|
                try allocator.dupe(u8, p)
            else
                try path.join(allocator, &.{ git_dir_path, objects_dir_name });
            errdefer allocator.free(objects_dir_path);

            var res: Self = .{
                .git_dir_path = git_dir_path,
                .objects_dir_path = objects_dir_path,
            };
            std.log.debug("Initializing Git dir {s}", .{res.git_dir_path});

            var git_dir = try cwd().openDir(io, res.git_dir_path, .{});
            defer git_dir.close(io);

            var objects_dir = try cwd().createDirPathOpen(io, res.objects_dir_path, .{});
            defer objects_dir.close(io);

            try objects_dir.createDirPath(io, info_dir_name);
            try objects_dir.createDirPath(io, pack_dir_name);

            var refs_dir = try git_dir.createDirPathOpen(io, refs_dir_name, .{});
            defer refs_dir.close(io);

            try refs_dir.createDirPath(io, heads_dir_name);
            try refs_dir.createDirPath(io, tags_dir_name);

            git_dir.access(io, head_file_name, .{}) catch |err| switch (err) {
                error.FileNotFound => try initHead(io, git_dir, initial_branch_name),
                else => return err,
            };

            if (std.mem.endsWith(u8, res.git_dir_path, default_git_dir_name)) {
                res.work_dir_path = try realPathFileAlloc(git_dir, io, "..", allocator);
            }

            return res;
        }

        /// Frees up used resources.
        pub fn deinit(self: *const Self, allocator: Allocator) void {
            allocator.free(self.git_dir_path);
            allocator.free(self.objects_dir_path);
            if (self.work_dir_path) |p| {
                allocator.free(p);
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

        /// Returns `true` if `relative_path` (relative to the worktree root) is
        /// inside the repository's internal directory (e.g. `.git/`).
        /// Always returns `false` when the git dir is outside the worktree.
        pub fn isInternalPath(self: *const Self, relative_path: []const u8) bool {
            const wt = self.work_dir_path orelse return false;
            if (self.git_dir_path.len > wt.len + 1 and
                std.mem.startsWith(u8, self.git_dir_path, wt) and
                self.git_dir_path[wt.len] == std.fs.path.sep)
            {
                const rel = self.git_dir_path[(wt.len + 1)..];
                return std.mem.startsWith(u8, relative_path, rel);
            }
            return false;
        }

        /// Loads in memory and returns the index.
        /// Caller owns the returned memory.
        pub fn loadIndex(self: *const Self, io: Io, allocator: Allocator) !Index {
            const index_path = try path.join(allocator, &.{ self.git_dir_path, index_file_name });
            defer allocator.free(index_path);

            // TODO: handle error.FileNotFound when index file does not exists (create it?)
            const index_content = try cwd().readFileAlloc(io, index_path, allocator, .unlimited);
            defer allocator.free(index_content);

            return Index.parse(allocator, index_content);
        }

        /// Writes the index to the file in the repository.
        pub fn saveIndex(self: *const Self, io: Io, index: *const Index, allocator: Allocator) !void {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try index.writeTo(allocator, &buf);

            const index_path = try path.join(allocator, &.{ self.git_dir_path, index_file_name });
            defer allocator.free(index_path);

            const file = try cwd().createFile(io, index_path, .{});
            defer file.close(io);

            var file_buf: [4 * 1024]u8 = undefined;
            var file_w = file.writerStreaming(io, &file_buf);
            try file_w.interface.writeAll(buf.items);
            try file_w.interface.flush();
        }

        /// Reads an object from the store.
        /// Deinitialize with `deinit`.
        pub fn readObject(
            self: *const Self,
            io: Io,
            writer: *std.Io.Writer,
            object_id: *const Object.Id,
            allocator: Allocator,
        ) !void {
            var obj_name: [Hasher.hash_size * 2]u8 = undefined;
            try hash.toHex(@constCast(&object_id.bytes), &obj_name);

            const file_path = try path.join(allocator, &.{ self.objects_dir_path, obj_name[0..2], obj_name[2..] });
            defer allocator.free(file_path);

            var file = try cwd().openFile(io, file_path, .{});
            defer file.close(io);

            _ = try decompressInto(io, &file, writer);
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
            var obj_name: [Hasher.hash_size * 2]u8 = undefined;
            try hash.toHex(@constCast(&object_id.bytes), &obj_name);

            const dir_path = try path.join(allocator, &.{ self.objects_dir_path, obj_name[0..2] });
            defer allocator.free(dir_path);

            var dest_dir = try cwd().createDirPathOpen(io, dir_path, .{});
            defer dest_dir.close(io);

            if (dest_dir.access(io, obj_name[2..], .{})) {
                return; // object already exists, skip
            } else |err| switch (err) {
                error.FileNotFound => {}, // proceed to write
                else => return err,
            }

            const temp_file_name = try generatePrefixedString(io, "tmp_obj_", 6, allocator);
            defer allocator.free(temp_file_name);
            std.log.debug("Using temporary file {s}", .{temp_file_name});

            var tmp_file = try dest_dir.createFile(io, temp_file_name, .{ .exclusive = true });
            defer tmp_file.close(io);

            _ = try compressFrom(io, &tmp_file, reader);

            // re-check
            if (dest_dir.access(io, obj_name[2..], .{})) {
                return; // object already exists, skip
            } else |err| switch (err) {
                error.FileNotFound => {}, // proceed to write
                else => return err,
            }

            try std.Io.Dir.rename(dest_dir, temp_file_name, dest_dir, obj_name[2..], io);
        }
    };
}

// Resolves the destination path of the .git directory to create a new repository.
// The resolution starts from `start_path` or from the current directory when not specified.
// The directory at `start_path` will be created if not exists.
// When `bare` is true uses the destination path as the .git directory.
// Caller owns the returned memory.
fn resolveGitDirPathToCreate(
    io: Io,
    start_path: ?[]const u8,
    bare: bool,
    env: *std.process.Environ.Map,
    allocator: Allocator,
) ![]u8 {
    if (start_path) |n| {
        try cwd().createDirPath(io, n);
    }

    const start_dir_path = try realPathFileAlloc(cwd(), io, start_path orelse ".", allocator);
    if (bare) {
        return start_dir_path;
    }
    defer allocator.free(start_dir_path);

    if (env.get(GIT_DIR_ENV)) |p| {
        return realPathFileAlloc(cwd(), io, p, allocator);
    }

    const dest_path = try path.join(allocator, &.{ start_dir_path, default_git_dir_name });
    defer allocator.free(dest_path);

    try cwd().createDirPath(io, dest_path);

    return realPathFileAlloc(cwd(), io, dest_path, allocator);
}

// Search the path of the .git directory from the current one or from `start_path` if it has a value.
// Walks up the directory tree until it gets to ~ or /, looking for a .git directory at every step.
// Caller owns the returned memory.
fn searchGitDirPath(io: Io, start_path: ?[]const u8, env: *std.process.Environ.Map, allocator: Allocator) ![]u8 {
    var curr_dir = try cwd().openDir(io, start_path orelse ".", .{});
    errdefer curr_dir.close(io);

    const root_path = try realPathFileAlloc(curr_dir, io, "/", allocator);
    defer allocator.free(root_path);

    var curr_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const curr_path_size = try curr_dir.realPathFile(io, ".", &curr_buf);
        std.log.debug("Searching {s} in {s}", .{ default_git_dir_name, curr_buf[0..curr_path_size] });

        var git_dir = curr_dir.openDir(io, default_git_dir_name, .{}) catch {
            const home_env_name = getHomeEnvKey();
            if (env.get(home_env_name)) |home_path| {
                if (std.mem.eql(u8, home_path, curr_buf[0..curr_path_size])) {
                    std.log.debug("Reached user home, halting {s} search", .{default_git_dir_name});
                    return error.GitDirNotFound;
                }
            }

            if (std.mem.eql(u8, root_path, curr_buf[0..curr_path_size])) {
                std.log.debug("Reached file-system root, halting {s} search", .{default_git_dir_name});
                return error.GitDirNotFound;
            }

            const parent = try curr_dir.openDir(io, "..", .{});
            curr_dir.close(io);
            curr_dir = parent;
            continue;
        };
        defer git_dir.close(io);

        return realPathFileAlloc(git_dir, io, ".", allocator);
    }

    return error.GitDirNotFound;
}

/// Returns the environment variable for the user home directory based on the OS.
fn getHomeEnvKey() []const u8 {
    if (builtin.os.tag == .windows) {
        // Note: in some versions of Windows HOME variable may be defined,
        // but it contains something as "/c/Users/name" and this may cause a
        // failure while comparing its content to paths retrived from opened
        // directories (that are in the form "C:\Users\name")
        return "USERPROFILE";
    }
    return "HOME";
}

// Creates and opens the HEAD file pointing to the specified branch
fn initHead(io: Io, git_dir: std.Io.Dir, branch_name: []const u8) !void {
    const head_file = try git_dir.createFile(io, head_file_name, .{ .exclusive = true });
    defer head_file.close(io);

    var write_buf: [256]u8 = undefined;
    var file_writer = head_file.writer(io, &write_buf);
    const writer = &file_writer.interface;

    try writer.print("ref: {s}/{s}/{s}\n", .{ refs_dir_name, heads_dir_name, branch_name });
    try writer.flush();

    std.log.debug("Using initial branch name {s}", .{branch_name});
}

test "setup git repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    // init a test repository in a tmp dir

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try realPathFileAlloc(tmp.dir, io, ".", allocator);
    defer allocator.free(test_dir_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Sha1GitRepository = try .setup(io, test_dir_path, "test", false, &env, allocator);
    defer repo.deinit(allocator);

    // check head file

    const head_file = try tmp.dir.openFile(io, default_git_dir_name ++ "/" ++ head_file_name, .{});
    defer head_file.close(io);

    var read_buf: [256]u8 = undefined;
    var head_r = head_file.reader(io, &read_buf);

    const head_content = try head_r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(head_content);

    try std.testing.expect(std.mem.eql(u8, head_content, "ref: refs/heads/test\n"));

    // check objects dir

    var objects_dir = try tmp.dir.openDir(io, default_git_dir_name ++ "/" ++ objects_dir_name, .{});
    defer objects_dir.close(io);

    // re-run

    try objects_dir.deleteDir(io, info_dir_name);
    try tmp.dir.deleteDir(io, default_git_dir_name ++ "/" ++ refs_dir_name ++ "/" ++ heads_dir_name);
    try tmp.dir.deleteFile(io, default_git_dir_name ++ "/" ++ head_file_name);

    var repo2: Sha1GitRepository = try .setup(io, test_dir_path, "test", false, &env, allocator);
    defer repo2.deinit(allocator);

    try tmp.dir.access(io, default_git_dir_name ++ "/" ++ objects_dir_name ++ "/" ++ info_dir_name, .{});
    try tmp.dir.access(io, default_git_dir_name ++ "/" ++ refs_dir_name ++ "/" ++ heads_dir_name, .{});
    try tmp.dir.access(io, default_git_dir_name ++ "/" ++ head_file_name, .{});
}

test "setup git repository using GIT_DIR env" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "project", .default_dir);
    const project_path = try realPathFileAlloc(tmp.dir, io, "project", allocator);
    defer allocator.free(project_path);

    try tmp.dir.createDir(io, "custom_git", .default_dir);
    const custom_git_path = try realPathFileAlloc(tmp.dir, io, "custom_git", allocator);
    defer allocator.free(custom_git_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put(GIT_DIR_ENV, custom_git_path);

    var repo: Sha1GitRepository = try .setup(io, project_path, "main", false, &env, allocator);
    defer repo.deinit(allocator);

    try std.testing.expectEqualSlices(u8, custom_git_path, repo.git_dir_path);

    var custom_git_dir = try tmp.dir.openDir(io, "custom_git", .{});
    defer custom_git_dir.close(io);
    try custom_git_dir.access(io, head_file_name, .{});
}

test "setup git repository using GIT_OBJECT_DIRECTORY env" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try realPathFileAlloc(tmp.dir, io, ".", allocator);
    defer allocator.free(test_dir_path);

    try tmp.dir.createDir(io, "custom_objects", .default_dir);
    const custom_objects_path = try realPathFileAlloc(tmp.dir, io, "custom_objects", allocator);
    defer allocator.free(custom_objects_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put(GIT_OBJECT_DIR_ENV, custom_objects_path);

    var repo: Sha1GitRepository = try .setup(io, test_dir_path, "main", false, &env, allocator);
    defer repo.deinit(allocator);

    try std.testing.expectEqualSlices(u8, custom_objects_path, repo.objects_dir_path);
}

/// Reads and decompresses the contents of `file` into `writer`.
/// Returns the total number of bytes written.
fn decompressInto(io: Io, file: *std.Io.File, writer: *std.Io.Writer) !usize {
    var file_buf: [4 * 1024]u8 = undefined;
    var file_r = file.readerStreaming(io, &file_buf);
    var inflate: flate.Decompress = .init(&file_r.interface, .zlib, &.{});

    return inflate.reader.streamRemaining(writer);
}

/// Compresses and writes the content retrieved from `reader` to `file`.
/// Returns the total number of bytes written.
fn compressFrom(io: Io, file: *std.Io.File, reader: *std.Io.Reader) !usize {
    var file_buf: [4 * 1024]u8 = undefined;
    var file_w = file.writerStreaming(io, &file_buf);
    const out = &file_w.interface;

    var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var deflate: flate.Compress = try .init(out, &flate_buf, .zlib, .default);
    const writer = &deflate.writer;

    const written = try reader.streamRemaining(writer);
    try writer.flush();
    try deflate.finish();

    try out.flush();

    return written;
}

/// Generates a random string with the specified length after `prefix`.
/// Caller owns the returned memory.
fn generatePrefixedString(io: Io, prefix: []const u8, length: usize, allocator: Allocator) ![]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz" ++ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++ "0123456789";

    const seed: u64 = @intCast(std.Io.Timestamp.now(io, .real).toMilliseconds());

    const result = try allocator.alloc(u8, prefix.len + length);
    errdefer allocator.free(result);

    _ = try std.fmt.bufPrint(result, "{s}", .{prefix});

    var prng: std.Random.DefaultPrng = .init(seed);
    var rand = prng.random();

    for (0..length) |i| {
        const char_index = rand.uintLessThan(u8, chars.len);
        result[prefix.len + i] = chars[char_index];
    }

    return result;
}

test "write and read from a git repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try realPathFileAlloc(tmp.dir, io, ".", allocator);
    defer allocator.free(test_dir_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();

    var repo: Sha1GitRepository = try .setup(io, test_dir_path, "test", false, &env, allocator);
    defer repo.deinit(allocator);

    const encoded_obj = "blob 14\x00sample content";
    const obj_name = "0d6f364b742a718be66b1b25e954015b6a98e310";

    const object_id: Sha1GitRepository.Object.Id = try .fromHex(obj_name);

    var obj_r: std.Io.Reader = .fixed(encoded_obj);
    try repo.writeObject(io, &obj_r, &object_id, allocator);

    var obj_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer obj_bytes.deinit();

    try repo.readObject(io, &obj_bytes.writer, &object_id, allocator);
    try std.testing.expectEqualSlices(u8, encoded_obj, obj_bytes.written());
}

test "open git repository using GIT_DIR env" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, default_git_dir_name, .default_dir);
    const git_dir_path = try realPathFileAlloc(tmp.dir, io, default_git_dir_name, allocator);
    defer allocator.free(git_dir_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put(GIT_DIR_ENV, git_dir_path);

    var repo: Sha1GitRepository = try .open(io, null, &env, allocator);
    defer repo.deinit(allocator);

    try std.testing.expectEqualSlices(u8, git_dir_path, repo.git_dir_path);
}

test "open git repository using GIT_OBJECT_DIRECTORY env" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, default_git_dir_name, .default_dir);
    const git_dir_path = try realPathFileAlloc(tmp.dir, io, default_git_dir_name, allocator);
    defer allocator.free(git_dir_path);

    try tmp.dir.createDir(io, "custom_objects", .default_dir);
    const objects_dir_path = try realPathFileAlloc(tmp.dir, io, "custom_objects", allocator);
    defer allocator.free(objects_dir_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put(GIT_DIR_ENV, git_dir_path);
    try env.put(GIT_OBJECT_DIR_ENV, objects_dir_path);

    var repo: Sha1GitRepository = try .open(io, null, &env, allocator);
    defer repo.deinit(allocator);

    try std.testing.expectEqualSlices(u8, objects_dir_path, repo.objects_dir_path);
}

test "open git repository search stops at HOME" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "home/project");

    const home_path = try realPathFileAlloc(tmp.dir, io, "home", allocator);
    defer allocator.free(home_path);

    const project_path = try realPathFileAlloc(tmp.dir, io, "home/project", allocator);
    defer allocator.free(project_path);

    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("HOME", home_path);

    try std.testing.expectError(error.GitDirNotFound, Sha1GitRepository.open(io, project_path, &env, allocator));
}

fn realPathFileAlloc(dir: std.Io.Dir, io: Io, sub_path: []const u8, allocator: Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPathFile(io, sub_path, &buffer);
    return allocator.dupe(u8, buffer[0..n]);
}
