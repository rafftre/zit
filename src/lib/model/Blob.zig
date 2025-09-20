// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! A blob object.
//! It's a binary blob of data.
//! Conforms to the object interface.

const Blob = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("object.zig").Object;

content: []u8,

/// Returns an instance of the object interface.
pub inline fn interface(self: Blob) Object {
    return .{ .blob = self };
}

/// Initializes this struct.
pub fn init(props: anytype) Blob {
    return std.mem.zeroInit(Blob, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Blob, allocator: Allocator) void {
    allocator.free(self.content);
}

/// Deserializes a tree from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Blob {
    return .{ .content = try allocator.dupe(u8, data) };
}

/// Serializes the blob content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Blob, allocator: Allocator) ![]u8 {
    return try allocator.dupe(u8, self.content);
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Blob,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{s}", .{self.content});
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const original_data = "Hello, Git blob!";

    var blob = init(.{ .content = @constCast(original_data) });

    const serialized = try blob.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualSlices(u8, original_data, deserialized.content);
}

test "serialize and deserialize empty" {
    const allocator = std.testing.allocator;

    const empty_data = "";
    var blob = init(.{ .content = @constCast(empty_data) });

    const serialized = try blob.serialize(allocator);
    defer allocator.free(serialized);

    try std.testing.expectEqualSlices(u8, empty_data, serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualSlices(u8, empty_data, deserialized.content);
}

test "format" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const blob = init(.{ .content = @constCast(test_data) });
    try std.fmt.format(buf.writer(), "{any}", .{blob});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
