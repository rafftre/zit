// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! An annotated tag object.
//! It specifies
//! - an object (id and type),
//! - a name.
//! - the tagger information,
//! - a message.
//! Conforms to the object interface.

const Tag = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectId = @import("ObjectId.zig");
const ObjectType = @import("object_type.zig").ObjectType;
const Signature = @import("Signature.zig");
const hex_chars = ObjectId.hex_chars;

object_id: ObjectId,
object_type: ObjectType,
tagger: Signature,
name: []const u8,
message: []const u8,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) Tag {
    return std.mem.zeroInit(Tag, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Tag, allocator: Allocator) void {
    self.tagger.deinit(allocator);
    allocator.free(self.name);
    allocator.free(self.message);
}

/// Allocates a new tag.
pub inline fn alloc(allocator: Allocator, props: anytype) !*Tag {
    const self = try allocator.create(Tag);
    self.* = init(props);
    return self;
}

/// Deserializes a tag from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *Tag, allocator: Allocator, data: []const u8) !void {
    var object_id: ?ObjectId = null;
    var object_type: ?ObjectType = null;
    var tagger: ?Signature = null;
    var name: ?[]u8 = null;

    var msgbuf = std.ArrayList(u8).init(allocator);
    errdefer msgbuf.deinit();

    var in_message = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (in_message) {
            if (msgbuf.items.len > 0) {
                try msgbuf.append('\n');
            }
            try msgbuf.appendSlice(line);
        } else {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0) {
                in_message = true;
                continue;
            }

            const space_idx = std.mem.indexOf(u8, trimmed, " ");
            if (space_idx) |i| {
                const header = line[0..i];
                const value = line[(i + 1)..];

                if (std.mem.eql(u8, header, "object") == true) {
                    object_id = try ObjectId.parseHexString(value);
                } else if (std.mem.eql(u8, header, "type") == true) {
                    object_type = ObjectType.parse(value);
                } else if (std.mem.eql(u8, header, "tag") == true) {
                    name = try allocator.dupe(u8, value);
                    errdefer allocator.free(name.?);
                } else if (std.mem.eql(u8, header, "tagger") == true) {
                    tagger = Signature.init(.{});
                    try tagger.?.deserialize(allocator, value);
                    errdefer tagger.?.deinit(allocator);
                }
            }
        }
    }

    if (object_id == null or object_type == null or name == null or tagger == null) {
        return error.InvalidTagFormat;
    }

    self.object_id = object_id.?;
    self.object_type = object_type.?;
    self.tagger = tagger.?;
    self.name = name.?;
    self.message = try msgbuf.toOwnedSlice();
}

/// Serializes the tag content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Tag, allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.writer().print("{any}", .{self});

    return try result.toOwnedSlice();
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Tag,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print(
        \\object {any}
        \\type {s}
        \\tag {s}
        \\tagger {any}
        \\
        \\{s}
    , .{
        self.object_id,
        @tagName(self.object_type),
        self.name,
        self.tagger,
        self.message,
    });
}

test "allocation" {
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

    const tag = try alloc(allocator, .{
        .object_id = oid.*,
        .object_type = .commit,
        .tagger = tagger.*,
        .name = "test-tag",
        .message = "Test tag message",
    });
    defer allocator.destroy(tag);

    try std.testing.expect(tag.object_id.eql(oid));
    try std.testing.expect(tag.object_type == .commit);
    try std.testing.expectEqualStrings("Test Author", tag.tagger.identity.name);
    try std.testing.expectEqualStrings("test-tag", tag.name);
    try std.testing.expectEqualStrings("Test tag message", tag.message);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const oid = try ObjectId.parseHexString("1234567890abcdef1234567890abcdef12345678");

    const tagger = Signature.init(.{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });

    var tag = init(.{
        .object_id = oid,
        .object_type = .commit,
        .tagger = tagger,
        .name = "test-tag",
        .message = "Test tag message",
    });

    const serialized = try tag.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(tag.object_id.eql(&deserialized.object_id));
    try std.testing.expect(tag.object_type == deserialized.object_type);
    try std.testing.expect(tag.tagger.eql(&deserialized.tagger));
    try std.testing.expectEqualStrings(tag.name, deserialized.name);
    try std.testing.expectEqualStrings(tag.message, deserialized.message);
}

test "serialize and deserialize with allocation" {
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

    const tag = try alloc(allocator, .{
        .object_id = oid.*,
        .object_type = .commit,
        .tagger = tagger.*,
        .name = "test-tag",
        .message = "Test tag message",
    });
    defer allocator.destroy(tag);

    const serialized = try tag.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(Tag);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

    try std.testing.expect(tag.object_id.eql(&deserialized.object_id));
    try std.testing.expect(tag.object_type == deserialized.object_type);
    try std.testing.expect(tag.tagger.eql(&deserialized.tagger));
    try std.testing.expectEqualStrings(tag.name, deserialized.name);
    try std.testing.expectEqualStrings(tag.message, deserialized.message);
}

test "format" {
    const allocator = std.testing.allocator;

    const test_data =
        \\object 1234567890abcdef1234567890abcdef12345678
        \\type commit
        \\tag test-tag
        \\tagger Test Author <author@example.com> 1640995200 +0200
        \\
        \\Test tag message
    ;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const oid = try ObjectId.parseHexString("1234567890abcdef1234567890abcdef12345678");

    const tagger = Signature.init(.{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });

    const tag = init(.{
        .object_id = oid,
        .object_type = .commit,
        .tagger = tagger,
        .name = "test-tag",
        .message = "Test tag message",
    });
    try std.fmt.format(buf.writer(), "{any}", .{tag});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
