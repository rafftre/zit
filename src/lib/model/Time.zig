// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! The time for a signature.
//! Conforms to the object interface.

const Time = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

seconds_from_epoch: i64,
tz_offset_min: i16,

/// Initializes this struct.
pub fn init(props: anytype) Time {
    return std.mem.zeroInit(Time, props);
}

/// Frees referenced resources.
pub fn deinit(_: *const Time, _: Allocator) void {}

/// Deserializes a time from `data`.
/// Free with `deinit`.
pub fn deserialize(_: Allocator, data: []const u8) !Time {
    const seconds_from_epoch_end = std.mem.indexOf(u8, data, " ") orelse return error.InvalidFormat;
    const seconds_from_epoch = data[0..seconds_from_epoch_end];
    const tz_offset_min = data[(seconds_from_epoch_end + 1)..];

    return .{
        .seconds_from_epoch = try std.fmt.parseInt(i64, seconds_from_epoch, 10),
        .tz_offset_min = try parseTzOffset(tz_offset_min),
    };
}

// parse timezone offset in the format "+/-HHMM"
fn parseTzOffset(str: []const u8) !i16 {
    if (str.len < 5) {
        return error.InvalidFormat;
    }

    const sign: i16 = if (str[0] == '+') 1 else -1;
    const hours = try std.fmt.parseInt(i16, str[1..3], 10);
    const minutes = try std.fmt.parseInt(i16, str[3..5], 10);

    return sign * (hours * 60 + minutes);
}

/// Serializes the time content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Time, allocator: Allocator) ![]u8 {
    const tz_sign: u8 = if (self.tz_offset_min >= 0) '+' else '-';
    const tz_hours = @abs(self.tz_offset_min) / 60;
    const tz_minutes = @abs(self.tz_offset_min) % 60;

    return try std.fmt.allocPrint(
        allocator,
        "{d} {c}{d:0>2}{d:0>2}",
        .{
            self.seconds_from_epoch,
            tz_sign,
            tz_hours,
            tz_minutes,
        },
    );
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Time,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const tz_sign: u8 = if (self.tz_offset_min >= 0) '+' else '-';
    const tz_hours = @abs(self.tz_offset_min) / 60;
    const tz_minutes = @abs(self.tz_offset_min) % 60;

    try writer.print("{d} {c}{d:0>2}{d:0>2}", .{
        self.seconds_from_epoch,
        tz_sign,
        tz_hours,
        tz_minutes,
    });
}

/// Returns `true` if the two time are equal.
pub inline fn eql(a: *const Time, b: *const Time) bool {
    return a.seconds_from_epoch == b.seconds_from_epoch and a.tz_offset_min == b.tz_offset_min;
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const time = init(.{
        .seconds_from_epoch = 1640995200,
        .tz_offset_min = -120,
    });

    const serialized = try time.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(time.seconds_from_epoch, deserialized.seconds_from_epoch);
    try std.testing.expectEqual(time.tz_offset_min, deserialized.tz_offset_min);
}

test "format" {
    const allocator = std.testing.allocator;

    const test_ts = 1640995200;
    const test_offset = -120;
    const test_data = std.fmt.comptimePrint("{d} -0200", .{test_ts});

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const time = init(.{
        .seconds_from_epoch = test_ts,
        .tz_offset_min = test_offset,
    });
    try std.fmt.format(buf.writer(), "{any}", .{time});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql" {
    const ident = init(.{ .seconds_from_epoch = 1640995200, .tz_offset_min = -120 });
    const clone = init(.{ .seconds_from_epoch = 1640995200, .tz_offset_min = -120 });
    const other1 = init(.{ .seconds_from_epoch = 1640995199, .tz_offset_min = -120 });
    const other2 = init(.{ .seconds_from_epoch = 1640995200, .tz_offset_min = -119 });

    try std.testing.expect(ident.eql(&clone));
    try std.testing.expect(clone.eql(&ident));
    try std.testing.expect(!ident.eql(&other1));
    try std.testing.expect(!ident.eql(&other2));
}
