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
/// No allocations are made.
pub fn init(props: anytype) Identity {
    return std.mem.zeroInit(Identity, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Identity, allocator: Allocator) void {
    allocator.free(self.name);
    allocator.free(self.email);
}

/// Allocates a new identity.
pub inline fn alloc(allocator: Allocator, props: anytype) !*Identity {
    const self = try allocator.create(Identity);
    self.* = init(props);
    return self;
}

/// Deserializes an identity from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *Identity, allocator: Allocator, data: []const u8) !void {
    const email_start = std.mem.indexOf(u8, data, "<") orelse return error.InvalidFormat;
    const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;
    const name = std.mem.trim(u8, data[0..email_start], " ");
    const email = data[(email_start + 1)..email_end];

    self.name = try allocator.dupe(u8, name);
    self.email = try allocator.dupe(u8, email);
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

test "allocation" {
    const allocator = std.testing.allocator;

    const ident = try alloc(allocator, .{
        .name = "Mario Rossi",
        .email = "mrossi@example.com",
    });
    defer allocator.destroy(ident);

    try std.testing.expectEqualStrings("Mario Rossi", ident.name);
    try std.testing.expectEqualStrings("mrossi@example.com", ident.email);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const ident = init(.{
        .name = "Mario Rossi",
        .email = "mrossi@example.com",
    });

    const serialized = try ident.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualStrings(ident.name, deserialized.name);
    try std.testing.expectEqualStrings(ident.email, deserialized.email);
}

test "serialize and deserialize with allocation" {
    const allocator = std.testing.allocator;

    const ident = try alloc(allocator, .{ .name = "Mario Rossi", .email = "mrossi@example.com" });
    defer allocator.destroy(ident);

    const serialized = try ident.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(Identity);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

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
