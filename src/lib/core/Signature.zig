// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A signature.
//! It's a combination of identity and timestamp.
//! Conforms to the object interface.

const Signature = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Identity = @import("Identity.zig");
const Time = @import("Time.zig");

identity: Identity,
time: Time,

/// Initializes this struct.
/// No allocations are made.
pub fn init(props: anytype) Signature {
    return std.mem.zeroInit(Signature, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Signature, allocator: Allocator) void {
    self.identity.deinit(allocator);
}

/// Allocates a new signature.
pub inline fn alloc(allocator: Allocator, props: anytype) !*Signature {
    const self = try allocator.create(Signature);
    self.* = init(props);
    return self;
}

/// Deserializes an signature from `data`.
/// Free with `deinit`.
pub fn deserialize(self: *Signature, allocator: Allocator, data: []const u8) !void {
    const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;

    var ident = Identity.init(.{});
    try ident.deserialize(allocator, data[0..(email_end + 1)]);

    var time = Time.init(.{});
    try time.deserialize(allocator, data[(email_end + 2)..]);

    self.identity = ident;
    self.time = time;
}

/// Serializes the signature content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Signature, allocator: Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{any} {any}", .{ self.identity, self.time });
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Signature,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("{any} {any}", .{ self.identity, self.time });
}

/// Returns `true` if the two signatures are equal.
pub inline fn eql(a: *const Signature, b: *const Signature) bool {
    return a.identity.eql(&b.identity) and a.time.eql(&b.time);
}

test "allocation" {
    const allocator = std.testing.allocator;

    const sign = try alloc(allocator, .{
        .identity = .{
            .name = "Mario Rossi",
            .email = "mrossi@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = -120,
        },
    });
    defer allocator.destroy(sign);

    try std.testing.expectEqualStrings("Mario Rossi", sign.identity.name);
    try std.testing.expectEqualStrings("mrossi@example.com", sign.identity.email);
    try std.testing.expectEqual(@as(i64, 1640995200), sign.time.seconds_from_epoch);
    try std.testing.expectEqual(@as(i16, -120), sign.time.tz_offset_min);
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const sign = init(.{
        .identity = .{
            .name = "Mario Rossi",
            .email = "mrossi@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = -120,
        },
    });

    const serialized = try sign.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = init(.{});
    try deserialized.deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(sign.identity.eql(&deserialized.identity));
    try std.testing.expect(sign.time.eql(&deserialized.time));
}

test "serialize and deserialize with allocation" {
    const allocator = std.testing.allocator;

    const sign = try alloc(allocator, .{
        .identity = .{
            .name = "Mario Rossi",
            .email = "mrossi@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = -120,
        },
    });
    defer allocator.destroy(sign);

    const serialized = try sign.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try allocator.create(Signature);
    try deserialized.deserialize(allocator, serialized);
    defer {
        deserialized.deinit(allocator);
        allocator.destroy(deserialized);
    }

    try std.testing.expect(sign.identity.eql(&deserialized.identity));
    try std.testing.expect(sign.time.eql(&deserialized.time));
}

test "format" {
    const allocator = std.testing.allocator;

    const test_name = "Mario Rossi";
    const test_email = "mrossi@example.com";
    const test_ts = 1640995200;
    const test_offset = -120;
    const test_data = std.fmt.comptimePrint("{s} <{s}> {d} -0200", .{ test_name, test_email, test_ts });

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const sign = init(.{
        .identity = .{
            .name = test_name,
            .email = test_email,
        },
        .time = .{
            .seconds_from_epoch = test_ts,
            .tz_offset_min = test_offset,
        },
    });
    try std.fmt.format(buf.writer(), "{any}", .{sign});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql" {
    const sign = init(.{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_min = -120 },
    });
    const clone = init(.{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_min = -120 },
    });
    const other1 = init(.{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995199, .tz_offset_min = -120 },
    });
    const other2 = init(.{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_min = -119 },
    });

    try std.testing.expect(sign.eql(&clone));
    try std.testing.expect(clone.eql(&sign));
    try std.testing.expect(!sign.eql(&other1));
    try std.testing.expect(!sign.eql(&other2));
}
