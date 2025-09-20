// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

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
pub fn init(props: anytype) Signature {
    return std.mem.zeroInit(Signature, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Signature, allocator: Allocator) void {
    self.identity.deinit(allocator);
}

/// Deserializes a signature from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Signature {
    const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;

    const ident = try Identity.deserialize(allocator, data[0..(email_end + 1)]);
    errdefer ident.deinit(allocator);

    const time = try Time.deserialize(allocator, data[(email_end + 2)..]);
    errdefer time.deinit(allocator);

    return .{
        .identity = ident,
        .time = time,
    };
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

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

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
