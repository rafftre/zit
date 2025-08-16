// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

const Blob = @import("Blob.zig");
const Commit = @import("Commit.zig");
const ObjectType = @import("object_type.zig").ObjectType;
const Tag = @import("Tag.zig");
const Tree = @import("Tree.zig");

/// The interface for an object.
pub const Object = union(ObjectType) {
    blob: *Blob,
    commit: *Commit,
    tag: *Tag,
    tree: *Tree,

    /// Calls `deinit` on the child object and destroy it.
    pub fn destroy(self: *const Object, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*s| {
                s.*.deinit(allocator);
                allocator.destroy(s.*);
            },
        }
    }

    /// Deserializes an object from `data`.
    pub fn deserialize(self: *Object, allocator: Allocator, data: []const u8) !void {
        switch (self.*) {
            inline else => |*s| try s.*.deserialize(allocator, data),
        }
    }

    /// Serializes the object content.
    pub fn serialize(self: *const Object, allocator: Allocator) ![]u8 {
        switch (self.*) {
            inline else => |*s| return s.*.serialize(allocator),
        }
    }

    /// Formatting method for use with `std.fmt.format`.
    /// Format and options are ignored.
    pub fn format(
        self: Object,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (self) {
            inline else => |s| return s.format(fmt, options, writer),
        }
    }

    /// Deserializes from `data` an object of `obj_type`.
    /// Free with `deinit`.
    pub fn deserializeByType(allocator: Allocator, obj_type: ObjectType, data: []u8) !Object {
        var obj: Object = switch (obj_type) {
            .blob => .{ .blob = try Blob.alloc(allocator, .{}) },
            .commit => .{ .commit = try Commit.alloc(allocator, .{}) },
            .tag => .{ .tag = try Tag.alloc(allocator, .{}) },
            .tree => .{ .tree = try Tree.alloc(allocator, .{}) },
        };

        try obj.deserialize(allocator, data);

        return obj;
    }
};

test "object interface operations" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    var obj: Object = .{ .blob = try Blob.alloc(allocator, .{ .content = @constCast(test_data) }) };
    defer allocator.destroy(obj.blob);

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized: Object = .{ .blob = try Blob.alloc(allocator, .{}) };
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.destroy(allocator);

    try std.testing.expectEqual(ObjectType.of(obj), ObjectType.of(deserialized));
    try std.testing.expectEqualSlices(u8, test_data, deserialized.blob.content);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "deserialize blob by type" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    const blob = try Blob.alloc(allocator, .{ .content = @constCast("Hello, Git blob!") });
    defer allocator.destroy(blob);

    var obj: Object = .{ .blob = blob };

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserializeByType(allocator, ObjectType.of(obj), serialized);
    defer deserialized.destroy(allocator);

    try std.testing.expectEqualSlices(u8, test_data, deserialized.blob.content);
}

test "deserialize tree by type" {
    const ObjectId = @import("ObjectId.zig");
    const TreeEntry = @import("TreeEntry.zig");
    const allocator = std.testing.allocator;

    var tree = try Tree.alloc(allocator, .{
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

    var obj: Object = .{ .tree = tree };

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserializeByType(allocator, ObjectType.of(obj), serialized);
    defer deserialized.destroy(allocator);

    try std.testing.expect(deserialized.tree.entries.items.len == 1);
    try std.testing.expect(deserialized.tree.entries.items[0].mode == .blob);
    try std.testing.expect(std.mem.eql(u8, deserialized.tree.entries.items[0].name, "README.md"));
}

test "deserialize commit by type" {
    const ObjectId = @import("ObjectId.zig");
    const Signature = @import("Signature.zig");
    const allocator = std.testing.allocator;

    const tree_id = try ObjectId.parseHexStringAlloc(allocator, "1234567890abcdef1234567890abcdef12345678");
    defer allocator.destroy(tree_id);

    const author = try Signature.alloc(allocator, .{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });
    defer allocator.destroy(author);

    const committer = try Signature.alloc(allocator, .{
        .identity = .{
            .name = "Test Committer",
            .email = "committer@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995300,
            .tz_offset_min = 120,
        },
    });
    defer allocator.destroy(committer);

    const commit = try Commit.alloc(allocator, .{
        .tree = tree_id.*,
        .parents = std.ArrayList(ObjectId).init(allocator),
        .author = author.*,
        .committer = committer.*,
        .message = "Test commit message",
    });
    defer {
        commit.parents.deinit();
        allocator.destroy(commit);
    }

    try commit.addParent("fedcba0987654321fedcba0987654321fedcba09");
    try commit.addParent("ba0987654321fedcba0987654321fedcba09fedc");

    var obj: Object = .{ .commit = commit };

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserializeByType(allocator, ObjectType.of(obj), serialized);
    defer deserialized.destroy(allocator);

    try std.testing.expect(commit.tree.eql(&deserialized.commit.tree));
    try std.testing.expectEqual(2, deserialized.commit.parents.items.len);
    try std.testing.expect(commit.author.eql(&deserialized.commit.author));
    try std.testing.expect(commit.committer.eql(&deserialized.commit.committer));
    try std.testing.expectEqualStrings(commit.message, deserialized.commit.message);
}

test "deserialize tag by type" {
    const ObjectId = @import("ObjectId.zig");
    const Signature = @import("Signature.zig");
    const allocator = std.testing.allocator;

    const oid = try ObjectId.parseHexStringAlloc(allocator, "1234567890abcdef1234567890abcdef12345678");
    defer allocator.destroy(oid);

    const tagger = try Signature.alloc(allocator, .{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });
    defer allocator.destroy(tagger);

    const tag = try Tag.alloc(allocator, .{
        .object_id = oid.*,
        .object_type = .commit,
        .tagger = tagger.*,
        .name = "test-tag",
        .message = "Test tag message",
    });
    defer allocator.destroy(tag);

    var obj: Object = .{ .tag = tag };

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserializeByType(allocator, ObjectType.of(obj), serialized);
    defer deserialized.destroy(allocator);

    try std.testing.expect(tag.object_id.eql(&deserialized.tag.object_id));
    try std.testing.expect(tag.object_type == deserialized.tag.object_type);
    try std.testing.expect(tag.tagger.eql(&deserialized.tag.tagger));
    try std.testing.expectEqualStrings(tag.name, deserialized.tag.name);
    try std.testing.expectEqualStrings(tag.message, deserialized.tag.message);
}
