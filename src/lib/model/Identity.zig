// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A person's identity.
//! Conforms to the object interface.

const Identity = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

name: []const u8,
email: []const u8,

/// Initializes this struct.
pub fn init(props: anytype) Identity {
    return std.mem.zeroInit(Identity, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Identity, allocator: Allocator) void {
    allocator.free(self.name);
    allocator.free(self.email);
}

/// Deserializes an identity from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Identity {
    const email_start = std.mem.indexOf(u8, data, "<") orelse return error.InvalidFormat;
    const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;
    const name = std.mem.trim(u8, data[0..email_start], " ");
    const email = data[(email_start + 1)..email_end];

    const name_dupe = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dupe);

    const email_dupe = try allocator.dupe(u8, email);
    errdefer allocator.free(email_dupe);

    return .{
        .name = name_dupe,
        .email = email_dupe,
    };
}

/// Serializes the identity content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Identity, allocator: Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ self.name, self.email });
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Identity,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{s} <{s}>", .{ self.name, self.email });
}

/// Returns `true` if the two identities are equal.
pub inline fn eql(a: *const Identity, b: *const Identity) bool {
    return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.email, b.email);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const ident = init(.{
        .name = "Mario Rossi",
        .email = "mrossi@example.com",
    });

    const serialized = try ident.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualStrings(ident.name, deserialized.name);
    try std.testing.expectEqualStrings(ident.email, deserialized.email);
}

test "format" {
    const allocator = std.testing.allocator;

    const test_name = "Mario Rossi";
    const test_email = "mrossi@example.com";
    const test_data = std.fmt.comptimePrint("{s} <{s}>", .{ test_name, test_email });

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const ident = init(.{
        .name = test_name,
        .email = test_email,
    });
    try std.fmt.format(buf.writer(), "{any}", .{ident});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql" {
    const ident = init(.{ .name = "Mario Rossi", .email = "mrossi@example.com" });
    const clone = init(.{ .name = "Mario Rossi", .email = "mrossi@example.com" });
    const other1 = init(.{ .name = "Mario Ross", .email = "mrossi@example.com" });
    const other2 = init(.{ .name = "Mario Rossi", .email = "rossi@example.com" });

    try std.testing.expect(ident.eql(&clone));
    try std.testing.expect(clone.eql(&ident));
    try std.testing.expect(!ident.eql(&other1));
    try std.testing.expect(!ident.eql(&other2));
}
