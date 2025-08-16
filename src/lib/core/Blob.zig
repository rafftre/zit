// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A blob object.
//! It's a binary blob of data.
//! Conforms to the object interface.

const Blob = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

content: []u8,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) Blob {
    return std.mem.zeroInit(Blob, props);
}

/// Frees referenced resources.
pub fn deinit(blob: *const Blob, allocator: Allocator) void {
    allocator.free(blob.content);
}

/// Allocates a new blob.
pub fn alloc(allocator: Allocator, props: anytype) !*Blob {
    const self = try allocator.create(Blob);
    self.* = init(props);
    return self;
}

/// Deserializes a tree from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *Blob, allocator: Allocator, data: []const u8) !void {
    self.content = try allocator.dupe(u8, data);
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

test "allocation" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    const blob1 = try alloc(allocator, .{ .content = @constCast(test_data) });
    defer allocator.destroy(blob1);

    const blob2 = try alloc(allocator, .{ .content = @constCast(test_data) });
    defer allocator.destroy(blob2);

    try std.testing.expect(&blob1 != &blob2);
    try std.testing.expectEqualSlices(u8, blob1.content, blob2.content);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const original_data = "Hello, Git blob!";

    var blob = init(.{ .content = @constCast(original_data) });

    const serialized = try blob.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
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

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualSlices(u8, empty_data, deserialized.content);
}

test "serialize and deserialize with allocation" {
    const allocator = std.testing.allocator;

    const original_data = "Hello, Git blob!";

    const blob = try alloc(allocator, .{ .content = @constCast(original_data) });
    defer allocator.destroy(blob);

    const serialized = try blob.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(Blob);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

    try std.testing.expectEqualSlices(u8, original_data, deserialized.content);
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
