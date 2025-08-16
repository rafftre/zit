// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! An object ID.
//! Identifies the object content.

const ObjectId = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

pub const hash_size = Sha1.digest_length;
pub const hex_chars = Sha1.digest_length * 2;

hash: [hash_size]u8 = [_]u8{0} ** hash_size,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) ObjectId {
    return std.mem.zeroInit(ObjectId, props);
}

/// Allocates a new object ID.
pub fn alloc(allocator: Allocator, props: anytype) !*ObjectId {
    const self = try allocator.create(ObjectId);
    self.* = init(props);
    return self;
}

/// Parses an object ID from an hexadecimal string.
pub fn parseHexString(hex: []const u8) !ObjectId {
    var self = init(.{});
    try self.hexStringToHash(hex);
    return self;
}

/// Parses an hexadecimal string and allocates a new object ID.
pub fn parseHexStringAlloc(allocator: Allocator, hex: []const u8) !*ObjectId {
    const self = try allocator.create(ObjectId);
    try self.hexStringToHash(hex);
    return self;
}

fn hexStringToHash(self: *ObjectId, hex: []const u8) !void {
    if (hex.len != hex_chars) {
        return error.InvalidHexLength;
    }

    for (0..hash_size) |i| {
        const j = i * 2;
        const hex_pair = hex[j..(j + 2)];
        self.hash[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return error.InvalidHexCharacter;
    }
}

/// Formats as an hexadecimal string into `buf`.
pub fn toHexString(oid: *const ObjectId, buf: []u8) !void {
    if (buf.len < hex_chars) {
        return error.BufferTooSmall;
    }

    for (oid.hash, 0..) |byte, i| {
        const j = i * 2;
        _ = try std.fmt.bufPrint(buf[j..(j + 2)], "{x:0>2}", .{byte});
    }
}

/// Formats as an hexadecimal string.
/// Caller owns the returned memory.
pub fn toHexStringAlloc(oid: *const ObjectId, allocator: Allocator) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, hex_chars);
    errdefer buf.deinit();

    for (oid.hash) |byte| {
        try buf.writer().print("{x:0>2}", .{byte});
    }

    return try buf.toOwnedSlice();
}

/// Formatting method for use with `std.fmt.format`.
/// Outputs an hexadecimal string.
/// Format and options are ignored.
pub fn format(
    self: ObjectId,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    for (self.hash) |byte| {
        _ = try writer.print("{x:0>2}", .{byte});
    }
}

/// Returns `true` if the object IDs are equal.
pub inline fn eql(a: *const ObjectId, b: *const ObjectId) bool {
    return std.mem.eql(u8, &a.hash, &b.hash);
}

test "basic operations" {
    const allocator = std.testing.allocator;

    var empty_obj = init(.{});

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    var test_obj = init(.{ .hash = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    } });

    const test_copy = try allocator.dupe(u8, &test_obj.hash);
    defer allocator.free(test_copy);

    var test_copy_obj = init(.{ .hash = test_copy[0..hash_size].* });

    try std.testing.expect(!empty_obj.eql(&test_obj));
    try std.testing.expect(test_obj.eql(&test_copy_obj));

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{test_obj});
    try std.testing.expectEqualSlices(u8, test_chars, buf.items);
}

test "allocation" {
    const allocator = std.testing.allocator;

    const obj1 = try alloc(allocator, .{});
    defer allocator.destroy(obj1);

    const obj2 = try alloc(allocator, .{});
    defer allocator.destroy(obj2);

    try std.testing.expect(obj1.eql(obj2));
}

test "conversion to hex" {
    const allocator = std.testing.allocator;

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    const test_bytes = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    };

    var obj = init(.{ .hash = test_bytes });

    var buf: [hex_chars]u8 = undefined;

    try obj.toHexString(&buf);
    try std.testing.expectEqualStrings(test_chars, &buf);

    var parsed = try parseHexString(&buf);
    try std.testing.expect(obj.eql(&parsed));

    const hex_alloc = try obj.toHexStringAlloc(allocator);
    defer allocator.free(hex_alloc);
    try std.testing.expectEqualStrings(test_chars, hex_alloc);

    const parsed_alloc = try parseHexStringAlloc(allocator, hex_alloc);
    defer allocator.destroy(parsed_alloc);
    try std.testing.expect(obj.eql(parsed_alloc));
}

test "conversion errors" {
    var obj = init(.{});

    // invalid length
    try std.testing.expectError(error.InvalidHexLength, parseHexString("abc"));

    // invalid characters
    try std.testing.expectError(
        error.InvalidHexCharacter,
        parseHexString("gggggggggggggggggggggggggggggggggggggggg"),
    );

    // buffer too small
    var small_buffer: [10]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, obj.toHexString(&small_buffer));
}
