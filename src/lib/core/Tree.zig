// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A tree object.
//! It's a list of entries, sorted by name before serialization.
//! Conforms to the object interface.

const Tree = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectId = @import("ObjectId.zig");

pub const TreeEntry = @import("TreeEntry.zig");

entries: std.ArrayList(TreeEntry) = undefined,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) Tree {
    return std.mem.zeroInit(Tree, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Tree, allocator: Allocator) void {
    for (self.entries.items) |*entry| {
        entry.deinit(allocator);
    }
    self.entries.deinit();
}

/// Allocates a new tree.
pub fn alloc(allocator: Allocator, props: anytype) !*Tree {
    const self = try allocator.create(Tree);
    self.* = init(props);
    return self;
}

/// Adds a new entry to the tree.
pub fn addEntry(self: *Tree, entry_props: anytype) !void {
    const entry = try self.entries.addOne();
    entry.* = TreeEntry.init(entry_props);
}

/// Deserializes a tree from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *Tree, allocator: Allocator, data: []const u8) !void {
    self.entries = std.ArrayList(TreeEntry).init(allocator);

    var offset: usize = 0;
    while (offset < data.len) {
        const space_pos = std.mem.indexOf(u8, data[offset..], " ") orelse break;
        const null_pos = std.mem.indexOf(u8, data[(offset + space_pos + 1)..], "\x00") orelse break;
        const entry_end = offset + space_pos + 1 + null_pos + 1 + 20;

        if (entry_end > data.len) break;

        var entry = try self.entries.addOne();
        try entry.deserialize(allocator, data[offset..entry_end]);

        offset = entry_end;
    }
}

/// Serializes the tree content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Tree, allocator: Allocator) ![]u8 {
    std.mem.sort(TreeEntry, self.entries.items, {}, TreeEntry.lessThan);

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
    std.mem.sort(TreeEntry, self.entries.items, {}, TreeEntry.lessThan);

    for (self.entries.items) |*entry| {
        try writer.print("{any}\n", .{entry});
    }
}

test "allocation" {
    const allocator = std.testing.allocator;

    var tree = try alloc(allocator, .{
        .entries = std.ArrayList(TreeEntry).init(allocator),
    });
    defer {
        tree.entries.deinit();
        allocator.destroy(tree);
    }

    const oid = try ObjectId.parseHexStringAlloc(allocator, "0123456789abcdef0123456789abcdef01234567");
    defer allocator.destroy(oid);

    try tree.addEntry(.{
        .name = @constCast("README.md"),
        .object_id = oid.*,
    });

    try std.testing.expect(tree.entries.items.len == 1);
    try std.testing.expect(tree.entries.items[0].mode == .blob);
    try std.testing.expect(std.mem.eql(u8, tree.entries.items[0].name, "README.md"));
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    var tree = init(.{ .entries = std.ArrayList(TreeEntry).init(allocator) });
    defer tree.entries.deinit();

    var obj_id1 =
        try ObjectId.parseHexString("1234567890123456789012345678901234567890");
    var obj_id2 =
        try ObjectId.parseHexString("abcdefabcdefabcdefabcdefabcdefabcdefabcd");

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

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
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

test "serialize and deserialize with allocation" {
    const allocator = std.testing.allocator;

    var tree = try alloc(allocator, .{
        .entries = std.ArrayList(TreeEntry).init(allocator),
    });
    defer {
        tree.entries.deinit();
        allocator.destroy(tree);
    }

    const obj_id1 = try ObjectId.parseHexStringAlloc(allocator, "1234567890123456789012345678901234567890");
    defer allocator.destroy(obj_id1);

    const obj_id2 = try ObjectId.parseHexStringAlloc(allocator, "abcdefabcdefabcdefabcdefabcdefabcdefabcd");
    defer allocator.destroy(obj_id2);

    try tree.addEntry(.{
        .name = @constCast("file1.txt"),
        .object_id = obj_id1.*,
    });
    try tree.addEntry(.{
        .mode = .tree,
        .name = @constCast("subdir"),
        .object_id = obj_id2.*,
    });

    const serialized = try tree.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(Tree);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

    const first_item = deserialized.entries.items[0];
    try std.testing.expect(deserialized.entries.items.len == 2);
    try std.testing.expect(first_item.mode == .blob);
    try std.testing.expectEqualStrings(first_item.name, "file1.txt");
    try std.testing.expect(first_item.object_id.eql(obj_id1));

    const second_item = deserialized.entries.items[1];
    try std.testing.expect(second_item.mode == .tree);
    try std.testing.expect(std.mem.eql(u8, second_item.name, "subdir"));
    try std.testing.expect(second_item.object_id.eql(obj_id2));
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

    var tree = init(.{ .entries = std.ArrayList(TreeEntry).init(allocator) });
    defer tree.entries.deinit();

    try tree.addEntry(.{
        .name = @constCast("foo.bar.baz"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("foo.bar"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    try tree.addEntry(.{
        .mode = .executable,
        .name = @constCast("foo"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    try tree.addEntry(.{
        .mode = .tree,
        .name = @constCast("lib"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("lib-a"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });
    try tree.addEntry(.{
        .name = @constCast("README"),
        .object_id = try ObjectId.parseHexString(empty_file_hash),
    });

    try std.fmt.format(buf.writer(), "{any}", .{tree});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
