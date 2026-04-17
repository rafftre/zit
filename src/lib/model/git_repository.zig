// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const flate = std.compress.flate;
const cwd = std.fs.cwd;
const path = std.fs.path;
const Allocator = std.mem.Allocator;

const env = @import("util/env.zig");
const hash = @import("util/hash.zig");
const newflate = @import("newflate/newflate.zig");

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

/// Returns a repository implementation that uses the file-system
/// with the Git rules and uses the specified hasher function.
pub fn GitRepository(comptime Hasher: type) type {
    return struct {
        git_dir_path: []u8 = undefined,
        objects_dir_path: []u8 = undefined,
        work_dir_path: ?[]u8 = null,

        const Self = @This();
        const Index = @import("index.zig").Index(Hasher);

        pub const Object = @import("object.zig").Object(Hasher);
        pub const LooseObject = @import("object.zig").LooseObject(Hasher);

        /// Opens a Git repository searching an existing .git directory.
        /// Search the path of the .git directory from from `start_path` or the current directory.
        /// Use `deinit` to free up used resources.
        pub fn open(allocator: Allocator, start_path: ?[]const u8) !Self {
            const git_dir_path = try env.getEnv(allocator, env.GIT_DIR) orelse
                try searchGitDirPath(allocator, start_path);
            errdefer allocator.free(git_dir_path);

            const objects_dir_path = try env.getEnv(allocator, env.GIT_OBJECT_DIR) orelse
                try path.join(allocator, &.{ git_dir_path, objects_dir_name });
            errdefer allocator.free(objects_dir_path);

            var res: Self = .{
                .git_dir_path = git_dir_path,
                .objects_dir_path = objects_dir_path,
            };
            std.log.debug("Using Git dir {s}", .{res.git_dir_path});

            // opens the directory to assert that exists
            var git_dir = try cwd().openDir(res.git_dir_path, .{});
            defer git_dir.close();

            if (std.mem.endsWith(u8, res.git_dir_path, default_git_dir_name)) {
                res.work_dir_path = try git_dir.realpathAlloc(allocator, "..");
            }

            return res;
        }

        /// Initializes a Git repository creating the directory tree on the file system.
        /// The path of the .git directory is resolved from `start_path` or from the current directory.
        /// If `bare`, the destination path will be used to host the repository directly
        /// instead of using the .git directory.
        /// Use `deinit` to free up used resources.
        pub fn setup(
            allocator: Allocator,
            start_path: ?[]const u8,
            initial_branch_name: []const u8,
            bare: bool,
        ) !Self {
            const git_dir_path = try resolveGitDirPathToCreate(allocator, start_path, bare);
            errdefer allocator.free(git_dir_path);

            const objects_dir_path = try env.getEnv(allocator, env.GIT_OBJECT_DIR) orelse
                try path.join(allocator, &.{ git_dir_path, objects_dir_name });
            errdefer allocator.free(objects_dir_path);

            var res: Self = .{
                .git_dir_path = git_dir_path,
                .objects_dir_path = objects_dir_path,
            };
            std.log.debug("Initializing Git dir {s}", .{res.git_dir_path});

            var git_dir = try cwd().openDir(res.git_dir_path, .{});
            defer git_dir.close();

            var objects_dir = try cwd().makeOpenPath(res.objects_dir_path, .{});
            defer objects_dir.close();

            try objects_dir.makePath(info_dir_name);
            try objects_dir.makePath(pack_dir_name);

            var refs_dir = try git_dir.makeOpenPath(refs_dir_name, .{});
            defer refs_dir.close();

            try refs_dir.makePath(heads_dir_name);
            try refs_dir.makePath(tags_dir_name);

            git_dir.access(head_file_name, .{}) catch |err| switch (err) {
                error.FileNotFound => try initHead(git_dir, initial_branch_name),
                else => return err,
            };

            if (std.mem.endsWith(u8, res.git_dir_path, default_git_dir_name)) {
                res.work_dir_path = try git_dir.realpathAlloc(allocator, "..");
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
        pub fn loadIndex(self: *const Self, allocator: Allocator) !Index {
            const index_path = try path.join(allocator, &.{ self.git_dir_path, index_file_name });
            defer allocator.free(index_path);

            // TODO: handle error.FileNotFound when index file does not exists (create it?)
            const index_content = try cwd().readFileAlloc(allocator, index_path, std.math.maxInt(usize));
            defer allocator.free(index_content);

            return Index.parse(allocator, index_content);
        }

        /// Reads an object from the store.
        /// Deinitialize with `deinit`.
        pub fn readObject(
            self: *const Self,
            allocator: Allocator,
            writer: *std.Io.Writer,
            object_id: *const Object.Id,
        ) !void {
            var obj_name: [Hasher.hash_size * 2]u8 = undefined;
            try hash.toHex(@constCast(&object_id.bytes), &obj_name);

            const file_path = try path.join(allocator, &.{ self.objects_dir_path, obj_name[0..2], obj_name[2..] });
            defer allocator.free(file_path);

            var file = try cwd().openFile(file_path, .{});
            defer file.close();

            _ = try decompressInto(&file, writer);
        }

        /// Writes an object to the store.
        /// A temporary file is first created and then moved to the destination.
        pub fn writeObject(
            self: *const Self,
            allocator: Allocator,
            reader: *std.Io.Reader,
            object_id: *const Object.Id,
        ) !void {
            var obj_name: [Hasher.hash_size * 2]u8 = undefined;
            try hash.toHex(@constCast(&object_id.bytes), &obj_name);

            const dir_path = try path.join(allocator, &.{ self.objects_dir_path, obj_name[0..2] });
            defer allocator.free(dir_path);

            var dest_dir = try cwd().makeOpenPath(dir_path, .{});
            defer dest_dir.close();

            if (dest_dir.access(obj_name[2..], .{})) {
                return; // object already exists, skip
            } else |err| switch (err) {
                error.FileNotFound => {}, // proceed to write
                else => return err,
            }

            const temp_file_name = try generatePrefixedString(allocator, "tmp_obj_", 6);
            defer allocator.free(temp_file_name);
            std.log.debug("Using temporary file {s}", .{temp_file_name});

            var tmp_file = try dest_dir.createFile(temp_file_name, .{ .exclusive = true });
            defer tmp_file.close();

            _ = try compressFrom(&tmp_file, reader);

            dest_dir.rename(temp_file_name, obj_name[2..]) catch |err| switch (err) {
                error.PathAlreadyExists => return,
                else => return err,
            };
        }
    };
}

// Resolves the destination path of the .git directory to create a new repository.
// The resolution starts from `start_path` or from the current directory when not specified.
// The directory at `start_path` will be created if not exists.
// When `bare` is true uses the destination path as the .git directory.
// Caller owns the returned memory.
fn resolveGitDirPathToCreate(allocator: Allocator, start_path: ?[]const u8, bare: bool) ![]u8 {
    if (start_path) |n| {
        try cwd().makePath(n);
    }

    const start_dir_path = try cwd().realpathAlloc(allocator, start_path orelse ".");
    if (bare) {
        return start_dir_path;
    }
    defer allocator.free(start_dir_path);

    const git_dir_path = try env.getEnv(allocator, env.GIT_DIR);
    if (git_dir_path) |p| {
        defer allocator.free(p);
        return try std.fs.realpathAlloc(allocator, p);
    }

    const dest_path = try path.join(allocator, &.{ start_dir_path, default_git_dir_name });
    defer allocator.free(dest_path);

    try cwd().makePath(dest_path);

    return try std.fs.realpathAlloc(allocator, dest_path);
}

// Search the path of the .git directory from the current one or from `start_path` if it has a value.
// Walks up the directory tree until it gets to ~ or /, looking for a .git directory at every step.
// Caller owns the returned memory.
fn searchGitDirPath(allocator: Allocator, start_path: ?[]const u8) ![]u8 {
    var curr_dir = try cwd().openDir(start_path orelse ".", .{});
    errdefer curr_dir.close();

    const root_path = try curr_dir.realpathAlloc(allocator, "/");
    defer allocator.free(root_path);

    const home_path = try env.getHomeDir(allocator);
    defer allocator.free(home_path);

    var curr_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (true) {
        const current_path = try curr_dir.realpath(".", &curr_buf);
        std.log.debug("Searching {s} in {s}", .{ default_git_dir_name, current_path });

        var git_dir = curr_dir.openDir(default_git_dir_name, .{}) catch {
            if (std.mem.eql(u8, home_path, current_path)) {
                std.log.debug("Reached user home, halting {s} search", .{default_git_dir_name});
                return error.GitDirNotFound;
            }

            if (std.mem.eql(u8, root_path, current_path)) {
                std.log.debug("Reached file-system root, halting {s} search", .{default_git_dir_name});
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
    const head_file = try git_dir.createFile(head_file_name, .{ .exclusive = true });
    defer head_file.close();

    var write_buf: [256]u8 = undefined;
    var file_writer = head_file.writer(&write_buf);
    const writer = &file_writer.interface;

    try writer.print("ref: {s}/{s}/{s}\n", .{ refs_dir_name, heads_dir_name, branch_name });
    try writer.flush();

    std.log.debug("Using initial branch name {s}", .{branch_name});
}

test "git repository setup" {
    const allocator = std.testing.allocator;
    const Sha1GitRepository = GitRepository(hash.Sha1);

    // init a test repository in a tmp dir

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    var repo: Sha1GitRepository = try .setup(allocator, test_dir_path, "test", false);
    defer repo.deinit(allocator);

    // check head file

    const head_file = try tmp.dir.openFile(default_git_dir_name ++ "/" ++ head_file_name, .{});
    defer head_file.close();

    var read_buf: [256]u8 = undefined;
    var head_r = head_file.reader(&read_buf);

    const head_content = try head_r.interface.allocRemaining(allocator, .unlimited);
    defer allocator.free(head_content);

    try std.testing.expect(std.mem.eql(u8, head_content, "ref: refs/heads/test\n"));

    // check objects dir

    var objects_dir = try tmp.dir.openDir(default_git_dir_name ++ "/" ++ objects_dir_name, .{});
    defer objects_dir.close();

    // re-run

    try objects_dir.deleteDir(info_dir_name);
    try tmp.dir.deleteDir(default_git_dir_name ++ "/" ++ refs_dir_name ++ "/" ++ heads_dir_name);
    try tmp.dir.deleteFile(default_git_dir_name ++ "/" ++ head_file_name);

    var repo2: Sha1GitRepository = try .setup(allocator, test_dir_path, "test", false);
    defer repo2.deinit(allocator);

    try tmp.dir.access(default_git_dir_name ++ "/" ++ objects_dir_name ++ "/" ++ info_dir_name, .{});
    try tmp.dir.access(default_git_dir_name ++ "/" ++ refs_dir_name ++ "/" ++ heads_dir_name, .{});
    try tmp.dir.access(default_git_dir_name ++ "/" ++ head_file_name, .{});
}

/// Reads and decompresses the contents of `file` into `writer`.
/// Returns the total number of bytes written.
fn decompressInto(file: *std.fs.File, writer: *std.Io.Writer) !usize {
    var file_buf: [4 * 1024]u8 = undefined;
    var file_r = file.readerStreaming(&file_buf);
    var inflate: flate.Decompress = .init(&file_r.interface, .zlib, &.{});

    return try inflate.reader.streamRemaining(writer);
}

/// Compresses and writes the content retrieved from `reader` to `file`.
/// Returns the total number of bytes written.
fn compressFrom(file: *std.fs.File, reader: *std.Io.Reader) !usize {
    var file_buf: [4 * 1024]u8 = undefined;
    var file_w = file.writerStreaming(&file_buf);
    const out = &file_w.interface;

    var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var deflate: newflate.Compress = try .init(out, &flate_buf, .zlib, .default);
    const writer = &deflate.writer;

    const written = try reader.streamRemaining(writer);
    try writer.flush();
    try deflate.finish();

    try out.flush();

    return written;
}

/// Generates a random string with the specified length after `prefix`.
/// Caller owns the returned memory.
fn generatePrefixedString(allocator: Allocator, prefix: []const u8, length: usize) ![]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz" ++ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++ "0123456789";
    const seed: u64 = @intCast(std.time.milliTimestamp());

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
    const Sha1GitRepository = GitRepository(hash.Sha1);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    var repo: Sha1GitRepository = try .setup(allocator, test_dir_path, "test", false);
    defer repo.deinit(allocator);

    const encoded_obj = "blob 14\x00sample content";
    const obj_name = "0d6f364b742a718be66b1b25e954015b6a98e310";

    const object_id: Sha1GitRepository.Object.Id = try .fromHex(obj_name);

    var obj_r: std.Io.Reader = .fixed(encoded_obj);
    try repo.writeObject(allocator, &obj_r, &object_id);

    var obj_bytes: std.Io.Writer.Allocating = .init(allocator);
    defer obj_bytes.deinit();

    try repo.readObject(allocator, &obj_bytes.writer, &object_id);
    try std.testing.expectEqualSlices(u8, encoded_obj, obj_bytes.written());
}
