// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A tree entry.
//! It's composed by a file mode, a file name, and an object ID.
//! Conforms to the object interface.

const TreeEntry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const FileMode = @import("file_mode.zig").FileMode;
const ObjectId = @import("ObjectId.zig");
const hash_size = ObjectId.hash_size;
const hex_chars = ObjectId.hex_chars;
const mode_chars = 6;

mode: FileMode = .blob,
name: []const u8,
object_id: ObjectId,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) TreeEntry {
    return std.mem.zeroInit(TreeEntry, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const TreeEntry, allocator: Allocator) void {
    allocator.free(self.name);
}

/// Allocates a new entry.
pub fn alloc(allocator: Allocator, props: anytype) !*TreeEntry {
    const self = try allocator.create(TreeEntry);
    self.* = init(props);
    return self;
}

/// Deserializes an entry from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *TreeEntry, allocator: Allocator, data: []const u8) !void {
    var offset: usize = 0;

    const mode_end = std.mem.indexOf(u8, data[offset..], " ") orelse return error.InvalidFormat;
    const mode = try FileMode.of(data[offset..(offset + mode_end)]);
    offset += mode_end + 1;

    const name_end = std.mem.indexOf(u8, data[offset..], "\x00") orelse return error.InvalidFormat;
    const name = try allocator.dupe(u8, data[offset..(offset + name_end)]);
    offset += name_end + 1;

    if (data.len < offset + hash_size) return error.InvalidFormat;
    const hash_bytes = data[offset..(offset + hash_size)];
    const object_id = ObjectId.init(.{
        .hash = @constCast(hash_bytes[0..hash_size]).*,
    });

    self.mode = mode;
    self.name = name;
    self.object_id = object_id;
}

/// Serializes the entry content.
/// Caller owns the returned memory.
pub fn serialize(self: *const TreeEntry, allocator: Allocator) ![]u8 {
    const total_len = mode_chars + 1 + self.name.len + 1 + hash_size;
    const result = try allocator.alloc(u8, total_len);

    _ = try std.fmt.bufPrint(result[0..mode_chars], "{o:0>6}", .{@intFromEnum(self.mode)});

    var offset: usize = mode_chars;

    result[offset] = ' ';
    offset += 1;

    @memcpy(result[offset..(offset + self.name.len)], self.name);
    offset += self.name.len;

    result[offset] = 0;
    offset += 1;

    @memcpy(result[offset..(offset + hash_size)], &self.object_id.hash);

    return result;
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: TreeEntry,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{o:0>6} {s} {any} {s}", .{
        @intFromEnum(self.mode),
        self.mode,
        self.object_id,
        self.name,
    });
}

/// Comparison function for use with `std.mem.sort`.
pub fn lessThan(_: void, lhs: TreeEntry, rhs: TreeEntry) bool {
    // Modified version of std.mem.order to take into consideration that
    // directory entries are ordered by adding a slash to the end.
    // See https://github.com/git/git/blob/6074a7d4ae6b658c18465f10bbbf144882d2d4b0/fsck.c#L497

    const n = @min(lhs.name.len, rhs.name.len);
    for (lhs.name[0..n], rhs.name[0..n]) |lhs_elem, rhs_elem| {
        switch (std.math.order(lhs_elem, rhs_elem)) {
            .eq => continue,
            .lt => return true, //return .lt,
            .gt => return false, //return .gt,
        }
    }

    if (lhs.mode == .tree and rhs.mode != .tree) {
        return rhs.name.len > n and std.math.order('/', rhs.name[n]) == .lt;
    } else if (lhs.mode != .tree and rhs.mode == .tree) {
        return lhs.name.len <= n or std.math.order(lhs.name[n], '/') == .lt;
    }

    return std.math.order(lhs.name.len, rhs.name.len) == .lt;
}

test "allocation" {
    const allocator = std.testing.allocator;

    const test_name = "script.sh";

    const oid = try ObjectId.parseHexStringAlloc(allocator, "fedcba0987654321fedcba0987654321fedcba09");
    defer allocator.destroy(oid);

    const entry1 = try alloc(allocator, .{
        .mode = .executable,
        .name = test_name,
        .object_id = oid.*,
    });
    defer allocator.destroy(entry1);

    const entry2 = try alloc(allocator, .{
        .mode = .executable,
        .name = test_name,
        .object_id = oid.*,
    });
    defer allocator.destroy(entry2);

    try std.testing.expect(&entry1 != &entry2);
    try std.testing.expect(entry1.mode == entry2.mode);
    try std.testing.expectEqualSlices(u8, entry1.name, entry2.name);
    try std.testing.expect(entry1.object_id.eql(&entry2.object_id));
    try std.testing.expect(&entry1.object_id != &entry2.object_id);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const test_name = "script.sh";

    const oid = try ObjectId.parseHexString("fedcba0987654321fedcba0987654321fedcba09");

    const entry = init(.{
        .mode = .executable,
        .name = @constCast(test_name),
        .object_id = oid,
    });

    const serialized = try entry.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(deserialized.mode == .executable);
    try std.testing.expectEqualSlices(u8, test_name, deserialized.name);
    try std.testing.expect(oid.eql(&deserialized.object_id));
}

test "serialize and deserialize with allocation" {
    const allocator = std.testing.allocator;

    const test_name = "script.sh";

    var oid = try ObjectId.parseHexStringAlloc(allocator, "fedcba0987654321fedcba0987654321fedcba09");
    defer allocator.destroy(oid);

    const entry = try alloc(allocator, .{
        .mode = .executable,
        .name = test_name,
        .object_id = oid.*,
    });
    defer allocator.destroy(entry);

    const serialized = try entry.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(TreeEntry);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

    try std.testing.expect(deserialized.mode == .executable);
    try std.testing.expectEqualSlices(u8, test_name, deserialized.name);
    try std.testing.expect(oid.eql(&deserialized.object_id));
}

test "format" {
    const allocator = std.testing.allocator;

    const test_hex = "fedcba0987654321fedcba0987654321fedcba09";
    const test_name = "script.sh";
    const test_data = "100755 blob " ++ test_hex ++ " " ++ test_name;

    const oid = try ObjectId.parseHexString(test_hex);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const entry = init(.{
        .mode = .executable,
        .name = @constCast(test_name),
        .object_id = oid,
    });
    try std.fmt.format(buf.writer(), "{any}", .{entry});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "sort" {
    const empty_file_hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    const readme = init(.{
        .name = @constCast("README"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    const aout_exe = init(.{
        .mode = .executable,
        .name = @constCast("a.out"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    const aout = init(.{
        .name = @constCast("a.out"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    const lib = init(.{
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    const lib_dir = init(.{
        .mode = .tree,
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    const liba = init(.{
        .name = @constCast("lib-a"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });

    // lexicographic order
    try std.testing.expectEqual(true, lessThan({}, readme, aout_exe));
    try std.testing.expectEqual(false, lessThan({}, aout_exe, readme));

    // same name
    try std.testing.expectEqual(false, lessThan({}, aout_exe, aout));
    try std.testing.expectEqual(false, lessThan({}, aout, aout_exe));

    // same name has different order when is file or dir
    try std.testing.expectEqual(true, lessThan({}, lib, liba));
    try std.testing.expectEqual(false, lessThan({}, lib_dir, liba));
    try std.testing.expectEqual(true, lessThan({}, liba, lib_dir));

    // same name compared between file and dir versions
    try std.testing.expectEqual(true, lessThan({}, lib, lib_dir));
    try std.testing.expectEqual(false, lessThan({}, lib_dir, lib));
}
