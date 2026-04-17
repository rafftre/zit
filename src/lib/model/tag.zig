// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("util/hash.zig");
const Object = @import("object.zig").Object;
const ObjectType = @import("object.zig").Type;
const LooseObject = @import("object.zig").LooseObject;
const Signature = @import("signature.zig").Signature;

/// An annotated tag object, i.e. a record for tagging another object.
/// It contains
/// - the object ID,
/// - the object type name,
/// - the tagger signature,
/// - a name,
/// - a text message.
/// Conforms to the object interface.
/// An annotated tag object takes ownership of the referenced `object_id`.
pub fn Tag(comptime Hasher: type) type {
    return struct {
        object_id: *ObjectId,
        object_type: ObjectType,
        tagger: Signature,
        name: []const u8,
        message: []const u8,

        const Self = @This();
        const ObjectId = Object(Hasher).Id;

        /// Returns an instance of the object interface.
        pub fn interface(self: Self) Object(Hasher) {
            return .{ .tag = self };
        }

        /// Implements the method with the same name in the object interface.
        /// Note: this also frees the referenced `object_id`.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.object_id.deinit(allocator);
            self.tagger.deinit(allocator);
            allocator.free(self.name);
            allocator.free(self.message);
        }

        /// Deserializes a tag.
        /// Deinitialize with `deinit`.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(allocator: Allocator, obj: *LooseObject(Hasher)) !Self {
            var object_id: ?*ObjectId = null;
            var object_type: ?ObjectType = null;
            var tagger: ?Signature = null;
            var name: ?[]u8 = null;
            var msgbuf: std.ArrayList(u8) = .empty;
            errdefer {
                if (tagger) |*t| {
                    Signature.deinit(@constCast(t), allocator);
                }
                if (name) |*n| {
                    errdefer allocator.free(n);
                }
                msgbuf.deinit(allocator);
            }

            var in_message = false;

            var it = std.mem.splitScalar(u8, obj.content, '\n');
            while (it.next()) |line| {
                if (in_message) {
                    if (msgbuf.items.len > 0) {
                        try msgbuf.append(allocator, '\n');
                    }
                    try msgbuf.appendSlice(allocator, line);
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
                            object_id = try .fromHex(allocator, value);
                        } else if (std.mem.eql(u8, header, "type") == true) {
                            object_type = .parse(value);
                        } else if (std.mem.eql(u8, header, "tag") == true) {
                            name = try allocator.dupe(u8, value);
                        } else if (std.mem.eql(u8, header, "tagger") == true) {
                            tagger = try .deserialize(allocator, value);
                        }
                    }
                }
            }

            if (object_id == null or object_type == null or name == null or tagger == null) {
                return error.InvalidTagFormat;
            }

            return .{
                .object_id = object_id.?,
                .object_type = object_type.?,
                .tagger = tagger.?,
                .name = name.?,
                .message = try msgbuf.toOwnedSlice(allocator),
            };
        }

        /// Serializes the tag.
        /// Caller owns the returned memory.
        /// Implements the method with the same name in the object interface.
        pub fn serialize(self: *const Self, allocator: Allocator) !LooseObject(Hasher) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(allocator);

            try result.print(allocator, "{f}", .{self});

            return .{
                .object_type = .tag,
                .content = try result.toOwnedSlice(allocator),
            };
        }

        /// Formatting method for use with `std.io.Writer.print`.
        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            try writer.print(
                \\object {f}
                \\type {s}
                \\tag {s}
                \\tagger {f}
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
    };
}

test "tag serialization" {
    const allocator = std.testing.allocator;
    const TestTag = Tag(hash.Sha1);

    var tag: TestTag = .{
        .object_id = try .fromHex(allocator, "1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Author"),
                .email = try allocator.dupe(u8, "author@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .name = try allocator.dupe(u8, "test-tag"),
        .message = try allocator.dupe(u8, "Test tag message"),
    };
    defer tag.deinit(allocator);

    var serialized = try tag.serialize(allocator);
    defer serialized.deinit(allocator);

    var deserialized: TestTag = try .deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(tag.object_id.eql(deserialized.object_id));
    try std.testing.expectEqual(tag.object_type, deserialized.object_type);
    try std.testing.expect(tag.tagger.eql(&deserialized.tagger));
    try std.testing.expectEqualStrings(tag.name, deserialized.name);
    try std.testing.expectEqualStrings(tag.message, deserialized.message);
}

test "format tag" {
    const allocator = std.testing.allocator;
    const TestTag = Tag(hash.Sha1);

    const test_data =
        \\object 1234567890abcdef1234567890abcdef12345678
        \\type commit
        \\tag test-tag
        \\tagger Test Author <author@example.com> 1640995200 +0200
        \\
        \\Test tag message
    ;

    var tag: TestTag = .{
        .object_id = try .fromHex(allocator, "1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Author"),
                .email = try allocator.dupe(u8, "author@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .name = try allocator.dupe(u8, "test-tag"),
        .message = try allocator.dupe(u8, "Test tag message"),
    };
    defer tag.deinit(allocator);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{tag});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
