// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! A tree entry.
//! It's composed by a file mode, a file name, and an object ID.
//! Conforms to the object interface.

const Entry = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectId = @import("ObjectId.zig");

const mode_len = 6;

/// File modes for tree entries.
pub const Mode = enum(u32) {
    tree = 0o40000,
    blob = 0o100644,
    executable = 0o100755,
    symlink = 0o120000,
    submodule = 0o160000,
    // 0o100664 is a deprecated mode supported by the first versions of Git.
    // This mode can still be found in old packfiles and should be treated as a regular file.

    /// Returns the mode for the given string (representing an octal number).
    pub fn parse(octal: []const u8) !Mode {
        const n = try std.fmt.parseInt(u32, octal, 8);
        if (n == 0o100664) {
            return .blob;
        }
        return try std.meta.intToEnum(Mode, n);
    }

    /// Formatting method for use with `std.fmt.format`.
    ///
    /// The supported formats are:
    /// - 'o' for octal string
    /// - Any other value will result in a descriptive string ("blob", "tree", or "submodule").
    ///
    /// Options are ignored.
    pub fn format(
        self: Mode,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (std.mem.eql(u8, fmt, "o")) {
            try writer.print(
                std.fmt.comptimePrint("{{o:0>{}}}", .{mode_len}),
                .{@intFromEnum(self)},
            );
        } else {
            const label = switch (self) {
                .tree => "tree",
                .submodule => "submodule",
                else => "blob",
            };

            try writer.print("{s}", .{label});
        }
    }
};

mode: Mode = .blob,
name: []const u8,
object_id: ObjectId,

/// Initializes this struct.
pub fn init(props: anytype) Entry {
    return std.mem.zeroInit(Entry, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Entry, allocator: Allocator) void {
    allocator.free(self.name);
}

/// Deserializes an entry from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Entry {
    var offset: usize = 0;

    const mode_end = std.mem.indexOf(u8, data[offset..], " ") orelse return error.InvalidFormat;
    const mode = try Mode.parse(data[offset..(offset + mode_end)]);
    offset += mode_end + 1;

    const name_end = std.mem.indexOf(u8, data[offset..], "\x00") orelse return error.InvalidFormat;
    const name = try allocator.dupe(u8, data[offset..(offset + name_end)]);
    errdefer allocator.free(name);
    offset += name_end + 1;

    var object_id = ObjectId.init(.{});
    const hash_size = object_id.bytes.len;

    if (data.len < offset + hash_size) return error.InvalidFormat;
    @memcpy(object_id.bytes[0..hash_size], data[offset..(offset + hash_size)]);

    return .{
        .mode = mode,
        .name = name,
        .object_id = object_id,
    };
}

/// Serializes the entry content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Entry, allocator: Allocator) ![]u8 {
    const hash_size = self.object_id.bytes.len;
    const total_len = mode_len + 1 + self.name.len + 1 + hash_size;
    const result = try allocator.alloc(u8, total_len);

    _ = try std.fmt.bufPrint(result[0..mode_len], "{o}", .{self.mode});

    var offset: usize = mode_len;

    result[offset] = ' ';
    offset += 1;

    @memcpy(result[offset..(offset + self.name.len)], self.name);
    offset += self.name.len;

    result[offset] = 0;
    offset += 1;

    @memcpy(result[offset..(offset + hash_size)], &self.object_id.bytes);

    return result;
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Entry,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{o} {any} {any} {s}", .{
        self.mode,
        self.mode,
        self.object_id,
        self.name,
    });
}

/// Comparison function for use with `std.mem.sort`.
pub fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
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

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const test_name = "script.sh";

    const oid = try ObjectId.parseHex("fedcba0987654321fedcba0987654321fedcba09");

    const entry = init(.{
        .mode = .executable,
        .name = @constCast(test_name),
        .object_id = oid,
    });

    const serialized = try entry.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(deserialized.mode == .executable);
    try std.testing.expectEqualSlices(u8, test_name, deserialized.name);
    try std.testing.expect(oid.eql(&deserialized.object_id));
}

test "format" {
    const allocator = std.testing.allocator;

    const test_hex = "fedcba0987654321fedcba0987654321fedcba09";
    const test_name = "script.sh";
    const test_data = "100755 blob " ++ test_hex ++ " " ++ test_name;

    const oid = try ObjectId.parseHex(test_hex);

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
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    const aout_exe = init(.{
        .mode = .executable,
        .name = @constCast("a.out"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    const aout = init(.{
        .name = @constCast("a.out"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    const lib = init(.{
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    const lib_dir = init(.{
        .mode = .tree,
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    const liba = init(.{
        .name = @constCast("lib-a"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
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
