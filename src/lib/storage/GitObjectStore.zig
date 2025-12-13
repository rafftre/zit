// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! An object store implementation that uses the file-system with the Git rules.

const Self = @This();

const std = @import("std");
const zlib = std.compress.zlib;
const Allocator = std.mem.Allocator;
const Dir = std.fs.Dir;
const cwd = std.fs.cwd;

const env = @import("env.zig");

const max_file_size = @import("../storage.zig").max_file_size;
const DEFAULT_OBJECT_DIR_NAME = "objects";
const INFO_DIR_NAME = "info";
const PACK_DIR_NAME = "pack";

objects_dir_path: []u8 = undefined,

/// Initializes this struct.
/// Use `deinit` to free up used resources.
pub fn init(self: *Self, allocator: Allocator, git_dir_path: []u8) !void {
    const objects_dir_path = try env.get(allocator, env.GIT_OBJECT_DIR) orelse
        try std.fs.path.join(allocator, &.{ git_dir_path, DEFAULT_OBJECT_DIR_NAME });
    errdefer allocator.free(objects_dir_path);

    std.log.debug("Using objects dir {s}", .{objects_dir_path});
    self.objects_dir_path = objects_dir_path;
}

/// Frees up used resources.
pub fn deinit(self: *const Self, allocator: Allocator) void {
    allocator.free(self.objects_dir_path);
}

/// Creates the directory tree on the file system.
pub fn setup(self: *const Self) !void {
    var objects_dir = try cwd().makeOpenPath(self.objects_dir_path, .{});
    defer objects_dir.close();

    try objects_dir.makePath(INFO_DIR_NAME);
    try objects_dir.makePath(PACK_DIR_NAME);
}

/// Returns the raw content of an object in the store.
/// Caller owns the returned memory.
pub fn read(self: *const Self, allocator: Allocator, name: []const u8) ![]u8 {
    const file_path = try self.looseObjectFilePath(allocator, name);
    defer allocator.free(file_path);

    const obj_file = try cwd().openFile(file_path, .{});
    defer obj_file.close();

    var stream = std.io.bufferedReader(obj_file.reader());
    var dcp = zlib.decompressor(stream.reader());
    const reader = dcp.reader();

    return reader.readAllAlloc(allocator, max_file_size);
}

/// Write the raw content of an object to the store.
pub fn write(self: *const Self, allocator: Allocator, name: []const u8, bytes: []u8) !void {
    const dir_path = try self.looseObjectDirPath(allocator, name);
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

inline fn looseObjectDirPath(self: *const Self, allocator: Allocator, name: []const u8) ![]u8 {
    var paths = .{ self.objects_dir_path, name[0..2] };
    return try std.fs.path.join(allocator, &paths);
}

inline fn looseObjectFilePath(self: *const Self, allocator: Allocator, name: []const u8) ![]u8 {
    var paths = .{ self.objects_dir_path, name[0..2], name[2..] };
    return try std.fs.path.join(allocator, &paths);
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

fn initTestStore(allocator: Allocator) !struct { tmp: std.testing.TmpDir, store: Self } {
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    var store: Self = .{};
    try store.init(allocator, test_dir_path);

    return .{
        .tmp = tmp,
        .store = store,
    };
}

test "store setup" {
    const allocator = std.testing.allocator;

    var ts = try initTestStore(allocator);
    defer {
        ts.store.deinit(allocator);
        ts.tmp.cleanup();
    }

    const test_dir = ts.tmp.dir;
    const store = ts.store;

    try store.setup();

    var objects_dir = try test_dir.openDir(DEFAULT_OBJECT_DIR_NAME, .{});
    defer objects_dir.close();

    // re-run
    try store.setup();

    try objects_dir.deleteDir(INFO_DIR_NAME);
    try store.setup();

    var sub_dir = try objects_dir.openDir(INFO_DIR_NAME, .{});
    defer sub_dir.close();
}

test "write and read loose object" {
    const allocator = std.testing.allocator;

    var ts = try initTestStore(allocator);
    defer {
        ts.store.deinit(allocator);
        ts.tmp.cleanup();
    }

    const store = ts.store;

    const obj_name = "r3test";
    const obj_data = "sample content";

    try store.write(allocator, obj_name, @constCast(obj_data));

    const read_data = try store.read(allocator, obj_name);
    defer allocator.free(read_data);

    try std.testing.expect(std.mem.eql(u8, read_data, obj_data));
}
