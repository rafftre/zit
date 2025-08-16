// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! An object store implementation that uses the file-system with the Git rules.

const GitObjectStore = @This();

const std = @import("std");
const zlib = std.compress.zlib;
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const cwd = std.fs.cwd;

pub const max_file_size: usize = 1024 * 1024 * 1024;
const default_object_dir = "objects";

const env = @import("env.zig");
const ObjectStore = @import("core/ObjectStore.zig");

/// Returns an instance of the object store interface.
pub fn objectStore(self: *GitObjectStore) ObjectStore {
    return .{
        .ptr = self,
        .openFn = open,
        .closeFn = deinit,
        .readFn = read,
        .writeFn = write,
    };
}

objects_dir_path: []u8,

/// Initializes an object store.
pub fn init(allocator: Allocator, git_dir_path: []u8) !GitObjectStore {
    const objects_dir_path = try env.get(allocator, env.GIT_OBJECT_DIR) orelse
        try std.fs.path.join(allocator, &.{ git_dir_path, default_object_dir });
    errdefer allocator.free(objects_dir_path);

    std.log.debug("Using objects dir {s}", .{objects_dir_path});
    return .{ .objects_dir_path = objects_dir_path };
}

/// Frees up used resources.
pub fn deinit(ptr: *anyopaque, allocator: Allocator) void {
    const self: *GitObjectStore = @ptrCast(@alignCast(ptr));
    allocator.free(self.objects_dir_path);
}

/// Opens an existing store.
/// Use `deinit` to free up used resources.
pub fn open(ptr: *anyopaque) !void {
    const self: *GitObjectStore = @ptrCast(@alignCast(ptr));

    // opens the directory to assert that exists
    var objects_dir = try cwd().openDir(self.objects_dir_path, .{});
    defer objects_dir.close();
}

/// Returns the raw content of an object in the store.
/// Caller owns the returned memory.
pub fn read(ptr: *anyopaque, allocator: Allocator, name: []const u8) ![]u8 {
    const self: *GitObjectStore = @ptrCast(@alignCast(ptr));

    var paths = .{ self.objects_dir_path, name[0..2], name[2..] };

    const file_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(file_path);

    const obj_file = try cwd().openFile(file_path, .{});
    defer obj_file.close();

    var stream = std.io.bufferedReader(obj_file.reader());
    var dcp = zlib.decompressor(stream.reader());
    const reader = dcp.reader();

    return reader.readAllAlloc(allocator, max_file_size);
}

/// Write the raw content of an object to the store.
pub fn write(ptr: *anyopaque, allocator: Allocator, name: []const u8, bytes: []u8) !void {
    const self: *GitObjectStore = @ptrCast(@alignCast(ptr));

    var paths = .{ self.objects_dir_path, name[0..2] };

    const dir_path = try std.fs.path.join(allocator, &paths);
    defer allocator.free(dir_path);

    var dest_dir = try cwd().makeOpenPath(dir_path, .{});
    defer dest_dir.close();

    if (dest_dir.openFile(name[2..], .{ .mode = .read_write })) |existing| {
        // file already exists
        existing.close();
        return;
    } else |err| switch (err) {
        error.PathAlreadyExists => return,
        else => {},
    }

    const temp_file_name = try createTempFile(allocator, dest_dir, bytes);
    defer allocator.free(temp_file_name);

    dest_dir.rename(temp_file_name, name[2..]) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
}

/// Creates the directory tree and initializes an object store.
pub fn setup(allocator: Allocator, git_dir_path: []u8) !GitObjectStore {
    const self = try init(allocator, git_dir_path);

    var objects_dir = try cwd().makeOpenPath(self.objects_dir_path, .{});
    defer objects_dir.close();

    try objects_dir.makePath("info");
    try objects_dir.makePath("pack");

    return self;
}

/// Writes `bytes` in a temporary file at `dest_dir`.
/// Caller owns the returned memory.
fn createTempFile(allocator: Allocator, dest_dir: Dir, bytes: []u8) ![]const u8 {
    const file_name = try generatePrefixedString(allocator, "tmp_obj_", 6);
    std.log.debug("Using temporary file {s}", .{file_name});

    var new_file = try dest_dir.createFile(file_name, .{ .exclusive = true });
    defer new_file.close();

    var stream = std.io.bufferedWriter(new_file.writer());
    var cp = try zlib.compressor(stream.writer(), .{});
    const writer = cp.writer();

    _ = try writer.write(bytes);
    try cp.finish();

    try stream.flush();

    return file_name;
}

/// Generates a random string with the specified length after `prefix`.
/// Caller owns the returned memory.
fn generatePrefixedString(allocator: Allocator, prefix: []const u8, length: usize) ![]const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz" ++ "ABCDEFGHIJKLMNOPQRSTUVWXYZ" ++ "0123456789";
    const seed: u64 = @intCast(std.time.milliTimestamp());

    const result = try allocator.alloc(u8, prefix.len + length);
    _ = try std.fmt.bufPrint(result, "{s}", .{prefix});

    var prng = std.Random.DefaultPrng.init(seed);
    var rand = prng.random();

    for (0..length) |i| {
        const char_index = rand.uintLessThan(u8, chars.len);
        result[prefix.len + i] = chars[char_index];
    }

    return result;
}
