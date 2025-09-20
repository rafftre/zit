// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const Blob = @import("Blob.zig");
const Commit = @import("Commit.zig");
const Tag = @import("Tag.zig");
const Tree = @import("Tree.zig");

/// The tag for an Object.
pub const Type = enum(u3) {
    blob,
    commit,
    tag,
    tree,

    /// Returns the tag of an object.
    pub fn of(obj: Object) Type {
        switch (obj) {
            .blob => return Type.blob,
            .commit => return Type.commit,
            .tag => return Type.tag,
            .tree => return Type.tree,
        }
    }

    /// Parses a tag from a string.
    pub fn parse(type_str: ?[]const u8) ?Type {
        if (type_str) |s| {
            return std.meta.stringToEnum(Type, s);
        }
        return null;
    }
};

/// The interface for an object.
pub const Object = union(Type) {
    blob: Blob,
    commit: Commit,
    tag: Tag,
    tree: Tree,

    /// Calls `deinit` on the child object.
    pub fn deinit(self: *const Object, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*s| s.*.deinit(allocator),
        }
    }

    /// Deserializes an object from `data`.
    /// Free with `deinit`.
    pub fn deserialize(allocator: Allocator, obj_type: Type, data: []const u8) !Object {
        return switch (obj_type) {
            .blob => .{ .blob = try Blob.deserialize(allocator, data) },
            .commit => .{ .commit = try Commit.deserialize(allocator, data) },
            .tag => .{ .tag = try Tag.deserialize(allocator, data) },
            .tree => .{ .tree = try Tree.deserialize(allocator, data) },
        };
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
};

test "blob with object interface" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    var obj = Blob.init(.{ .content = @constCast(test_data) }).interface();

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserialize(allocator, .blob, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(Type.of(obj), Type.of(deserialized));
    try std.testing.expectEqualSlices(u8, test_data, deserialized.blob.content);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "tree with object interface" {
    const ObjectId = @import("ObjectId.zig");
    const TreeEntry = @import("TreeEntry.zig");
    const allocator = std.testing.allocator;

    const test_data =
        \\100644 blob 0123456789abcdef0123456789abcdef01234567 README.md
        \\
    ;

    var obj = Tree.init(.{ .entries = std.ArrayList(TreeEntry).init(allocator) }).interface();
    defer obj.tree.entries.deinit();

    try obj.tree.addEntry(.{
        .name = @constCast("README.md"),
        .object_id = try ObjectId.parseHex("0123456789abcdef0123456789abcdef01234567"),
    });

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserialize(allocator, .tree, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(deserialized.tree.entries.items.len == 1);
    try std.testing.expect(deserialized.tree.entries.items[0].mode == .blob);
    try std.testing.expect(std.mem.eql(u8, deserialized.tree.entries.items[0].name, "README.md"));

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "commit with object interface" {
    const ObjectId = @import("ObjectId.zig");
    const allocator = std.testing.allocator;

    const test_data =
        \\tree 1234567890abcdef1234567890abcdef12345678
        \\parent fedcba0987654321fedcba0987654321fedcba09
        \\parent ba0987654321fedcba0987654321fedcba09fedc
        \\author Test Author <author@example.com> 1640995200 +0200
        \\committer Test Committer <committer@example.com> 1640995300 +0200
        \\
        \\Test commit message
    ;

    var commit = Commit.init(.{
        .tree = try ObjectId.parseHex("1234567890abcdef1234567890abcdef12345678"),
        .parents = std.ArrayList(ObjectId).init(allocator),
        .author = .{
            .identity = .{ .name = "Test Author", .email = "author@example.com" },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_min = 120 },
        },
        .committer = .{
            .identity = .{ .name = "Test Committer", .email = "committer@example.com" },
            .time = .{ .seconds_from_epoch = 1640995300, .tz_offset_min = 120 },
        },
        .message = "Test commit message",
    });
    defer commit.parents.deinit();

    try commit.addParent("fedcba0987654321fedcba0987654321fedcba09");
    try commit.addParent("ba0987654321fedcba0987654321fedcba09fedc");

    var obj = commit.interface();

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserialize(allocator, .commit, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(commit.tree.eql(&deserialized.commit.tree));
    try std.testing.expectEqual(2, deserialized.commit.parents.items.len);
    try std.testing.expect(commit.author.eql(&deserialized.commit.author));
    try std.testing.expect(commit.committer.eql(&deserialized.commit.committer));
    try std.testing.expectEqualStrings(commit.message, deserialized.commit.message);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "tag with object interface" {
    const ObjectId = @import("ObjectId.zig");
    const allocator = std.testing.allocator;

    const test_data =
        \\object 1234567890abcdef1234567890abcdef12345678
        \\type commit
        \\tag test-tag
        \\tagger Test Author <author@example.com> 1640995200 +0200
        \\
        \\Test tag message
    ;

    const tag = Tag.init(.{
        .object_id = try ObjectId.parseHex("1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{ .name = "Test Author", .email = "author@example.com" },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_min = 120 },
        },
        .name = "test-tag",
        .message = "Test tag message",
    });

    var obj = tag.interface();

    const serialized = try obj.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try Object.deserialize(allocator, .tag, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(tag.object_id.eql(&deserialized.tag.object_id));
    try std.testing.expect(tag.object_type == deserialized.tag.object_type);
    try std.testing.expect(tag.tagger.eql(&deserialized.tag.tagger));
    try std.testing.expectEqualStrings(tag.name, deserialized.tag.name);
    try std.testing.expectEqualStrings(tag.message, deserialized.tag.message);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
