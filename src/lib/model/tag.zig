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
/// - the tagger identity,
/// - a name,
/// - a text message.
/// Conforms to the object interface.
/// All string fields (tagger identity, name, message) borrow from the LooseObject used during deserialization.
pub fn Tag(comptime Hasher: type) type {
    return struct {
        object_id: ObjectId,
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

        /// No-op.
        pub fn deinit(_: *Self, _: Allocator) void {}

        /// Deserializes a tag.
        /// All string fields in the returned tag borrow from `obj.content`,
        /// for this reason `obj` must outlive the tag.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(obj: *const LooseObject(Hasher)) !Self {
            const body_sep = std.mem.indexOf(u8, obj.content, "\n\n") orelse return error.InvalidTagFormat;
            const headers_part = obj.content[0..body_sep];
            const message: []const u8 = obj.content[(body_sep + 2)..];

            var object_id: ?ObjectId = null;
            var object_type: ?ObjectType = null;
            var tagger: ?Signature = null;
            var name: ?[]const u8 = null;

            var it = std.mem.splitScalar(u8, headers_part, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;

                const space_idx = std.mem.indexOf(u8, trimmed, " ");
                if (space_idx) |i| {
                    const header = trimmed[0..i];
                    const value = trimmed[(i + 1)..];

                    if (std.mem.eql(u8, header, "object")) {
                        object_id = try .fromHex(value);
                    } else if (std.mem.eql(u8, header, "type")) {
                        object_type = .parse(value);
                    } else if (std.mem.eql(u8, header, "tag")) {
                        name = value;
                    } else if (std.mem.eql(u8, header, "tagger")) {
                        tagger = try Signature.deserialize(value);
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
                .message = message,
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

        /// Formatting method for use with `std.Io.Writer.print`.
        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.print(
                \\object {f}
                \\type {s}
                \\tag {s}
                \\tagger {f}
                \\
                \\{s}
            , .{
                &self.object_id,
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

    const tag: TestTag = .{
        .object_id = try .fromHex("1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{
                .name = "Test Author",
                .email = "author@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .name = "test-tag",
        .message = "Test tag message",
    };

    var serialized = try tag.serialize(allocator);
    defer serialized.deinit(allocator);

    const deserialized: TestTag = try .deserialize(&serialized);

    try std.testing.expect(tag.object_id.eql(&deserialized.object_id));
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

    const tag: TestTag = .{
        .object_id = try .fromHex("1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{
                .name = "Test Author",
                .email = "author@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .name = "test-tag",
        .message = "Test tag message",
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{tag});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
