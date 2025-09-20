// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! A tree object.
//! It's a list of entries, sorted by name before serialization.
//! Conforms to the object interface.

const Tree = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("object.zig").Object;
const ObjectId = @import("ObjectId.zig");

pub const Entry = @import("TreeEntry.zig");

entries: std.ArrayList(Entry) = undefined,

/// Returns an instance of the object interface.
pub inline fn interface(self: Tree) Object {
    return .{ .tree = self };
}

/// Initializes this struct.
pub fn init(props: anytype) Tree {
    return std.mem.zeroInit(Tree, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Tree, _: Allocator) void {
    deinitEntries(self.entries);
}

inline fn deinitEntries(entries: std.ArrayList(Entry)) void {
    for (entries.items) |*entry| {
        entry.deinit(entries.allocator);
    }
    entries.deinit();
}

/// Adds a new entry to the tree.
pub fn addEntry(self: *Tree, entry_props: anytype) !void {
    const entry = try self.entries.addOne();
    entry.* = Entry.init(entry_props);
}

/// Deserializes a tree from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Tree {
    var entries = std.ArrayList(Entry).init(allocator);
    errdefer deinitEntries(entries);

    var offset: usize = 0;
    while (offset < data.len) {
        const space_pos = std.mem.indexOf(u8, data[offset..], " ") orelse break;
        const null_pos = std.mem.indexOf(u8, data[(offset + space_pos + 1)..], "\x00") orelse break;
        const entry_end = offset + space_pos + 1 + null_pos + 1 + 20;

        if (entry_end > data.len) break;

        const entry = try entries.addOne();
        entry.* = try Entry.deserialize(allocator, data[offset..entry_end]);

        offset = entry_end;
    }

    return .{ .entries = entries };
}

/// Serializes the tree content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Tree, allocator: Allocator) ![]u8 {
    std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);

    var total_size: usize = 0;
    var serialized_entries = try allocator.alloc([]u8, self.entries.items.len);
    defer {
        for (serialized_entries) |entry_data| {
            allocator.free(entry_data);
        }
        allocator.free(serialized_entries);
    }

    for (self.entries.items, 0..) |*entry, i| {
        serialized_entries[i] = try entry.serialize(allocator);
        total_size += serialized_entries[i].len;
    }

    const result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;
    for (serialized_entries) |entry_data| {
        @memcpy(result[offset..(offset + entry_data.len)], entry_data);
        offset += entry_data.len;
    }

    return result;
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Tree,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);

    for (self.entries.items) |*entry| {
        try writer.print("{any}\n", .{entry});
    }
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    var tree = init(.{ .entries = std.ArrayList(Entry).init(allocator) });
    defer tree.entries.deinit();

    var obj_id1 = try ObjectId.parseHex("1234567890123456789012345678901234567890");
    var obj_id2 = try ObjectId.parseHex("abcdefabcdefabcdefabcdefabcdefabcdefabcd");

    try tree.addEntry(.{
        .name = @constCast("file1.txt"),
        .object_id = obj_id1,
    });
    try tree.addEntry(.{
        .mode = .tree,
        .name = @constCast("subdir"),
        .object_id = obj_id2,
    });

    const serialized = try tree.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    const first_item = deserialized.entries.items[0];
    try std.testing.expect(deserialized.entries.items.len == 2);
    try std.testing.expect(first_item.mode == .blob);
    try std.testing.expectEqualStrings(first_item.name, "file1.txt");
    try std.testing.expect(first_item.object_id.eql(&obj_id1));

    const second_item = deserialized.entries.items[1];
    try std.testing.expect(second_item.mode == .tree);
    try std.testing.expect(std.mem.eql(u8, second_item.name, "subdir"));
    try std.testing.expect(second_item.object_id.eql(&obj_id2));
}

test "format" {
    const allocator = std.testing.allocator;

    const test_data =
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 README
        \\100755 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo.bar
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo.bar.baz
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 lib-a
        \\040000 tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 lib
        \\
    ;
    const empty_file_hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var tree = init(.{ .entries = std.ArrayList(Entry).init(allocator) });
    defer tree.entries.deinit();

    try tree.addEntry(.{
        .name = @constCast("foo.bar.baz"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("foo.bar"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    try tree.addEntry(.{
        .mode = .executable,
        .name = @constCast("foo"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    try tree.addEntry(.{
        .mode = .tree,
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("lib-a"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("README"),
        .object_id = try ObjectId.parseHex(empty_file_hash),
    });

    try std.fmt.format(buf.writer(), "{any}", .{tree});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
