// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! An object ID.
//! Identifies the object content.

const ObjectId = @This();

const std = @import("std");

const hash = @import("../helpers.zig").hash;
const hash_size = hash.Sha1.hash_size; // XXX: locked to SHA-1

bytes: [hash_size]u8 = [_]u8{0} ** hash_size,

/// Initializes this struct.
pub fn init(props: anytype) ObjectId {
    return std.mem.zeroInit(ObjectId, props);
}

/// Parses an object ID from an hexadecimal string.
pub inline fn parseHex(hex: []const u8) !ObjectId {
    var self = init(.{});
    try hash.parseHex(hex, &self.bytes);
    return self;
}

/// Formats this object ID as an hexadecimal string into `out`.
pub inline fn toHex(self: *const ObjectId, out: []u8) !void {
    try hash.toHex(self.bytes, out);
}

/// Formatting method for use with `std.fmt.format`.
/// Outputs an hexadecimal string.
/// Format and options are ignored.
pub inline fn format(
    self: ObjectId,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try hash.formatAsHex(@constCast(self.bytes[0..]), writer);
}

/// Returns `true` if the object IDs are equal.
pub inline fn eql(a: *const ObjectId, b: *const ObjectId) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

test "basic operations" {
    const allocator = std.testing.allocator;

    var empty_oid = init(.{});

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    var test_oid = init(.{ .bytes = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    } });

    const test_copy = try allocator.dupe(u8, &test_oid.bytes);
    defer allocator.free(test_copy);

    var test_copy_oid = init(.{ .bytes = test_copy[0..hash_size].* });

    try std.testing.expect(!empty_oid.eql(&test_oid));
    try std.testing.expect(test_oid.eql(&test_copy_oid));

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{test_oid});
    try std.testing.expectEqualSlices(u8, test_chars, buf.items);
}
