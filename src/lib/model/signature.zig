// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A person's identity.
pub const Identity = struct {
    name: []const u8,
    email: []const u8,

    /// Deserializes an identity.
    /// The returned slices borrow from `data`, for this reason `data` must outlive the identity.
    pub fn deserialize(data: []const u8) !Identity {
        const email_start = std.mem.indexOf(u8, data, "<") orelse return error.InvalidFormat;
        const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;

        return .{
            .name = std.mem.trim(u8, data[0..email_start], " "),
            .email = data[(email_start + 1)..email_end],
        };
    }

    /// Serializes the identity content.
    /// Caller owns the returned memory.
    pub fn serialize(self: *const Identity, allocator: Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s} <{s}>", .{ self.name, self.email });
    }

    /// Returns `true` if the two identities are equal.
    pub fn eql(a: *const Identity, b: *const Identity) bool {
        return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.email, b.email);
    }

    /// Formatting method for use with `std.io.Writer.print`.
    pub fn format(self: *const Identity, writer: *std.io.Writer) !void {
        try writer.print("{s} <{s}>", .{ self.name, self.email });
    }
};

test "identity serialization" {
    const allocator = std.testing.allocator;

    const ident: Identity = .{
        .name = "Mario Rossi",
        .email = "mrossi@example.com",
    };

    const serialized = try ident.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized: Identity = try .deserialize(serialized);

    try std.testing.expectEqualStrings(ident.name, deserialized.name);
    try std.testing.expectEqualStrings(ident.email, deserialized.email);
}

test "format identity" {
    const allocator = std.testing.allocator;

    const test_name = "Mario Rossi";
    const test_email = "mrossi@example.com";
    const test_data = std.fmt.comptimePrint("{s} <{s}>", .{ test_name, test_email });

    const ident: Identity = .{
        .name = test_name,
        .email = test_email,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{ident});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql identity" {
    const ident: Identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" };
    const clone: Identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" };
    const other1: Identity = .{ .name = "Mario Ross", .email = "mrossi@example.com" };
    const other2: Identity = .{ .name = "Mario Rossi", .email = "rossi@example.com" };

    try std.testing.expect(ident.eql(&clone));
    try std.testing.expect(clone.eql(&ident));
    try std.testing.expect(!ident.eql(&other1));
    try std.testing.expect(!ident.eql(&other2));
}

/// The time of a signature.
pub const Time = struct {
    seconds_from_epoch: i64,
    tz_offset_minutes: i16,

    /// Deserializes a time.
    pub fn deserialize(data: []const u8) !Time {
        const seconds_from_epoch_end = std.mem.indexOf(u8, data, " ") orelse return error.InvalidFormat;
        const seconds_from_epoch = data[0..seconds_from_epoch_end];
        const tz_offset_minutes = data[(seconds_from_epoch_end + 1)..];

        return .{
            .seconds_from_epoch = try std.fmt.parseInt(i64, seconds_from_epoch, 10),
            .tz_offset_minutes = try parseTzOffset(tz_offset_minutes),
        };
    }

    /// Serializes the time content.
    pub fn serialize(self: *const Time, allocator: Allocator) ![]u8 {
        const tz_sign: u8 = if (self.tz_offset_minutes >= 0) '+' else '-';
        const tz_hours = @abs(self.tz_offset_minutes) / 60;
        const tz_minutes = @abs(self.tz_offset_minutes) % 60;

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

    /// Returns `true` if the two time instances are equal.
    pub fn eql(a: *const Time, b: *const Time) bool {
        return a.seconds_from_epoch == b.seconds_from_epoch and a.tz_offset_minutes == b.tz_offset_minutes;
    }

    /// Formatting method for use with `std.io.Writer.print`.
    pub fn format(self: *const Time, writer: *std.io.Writer) !void {
        const tz_sign: u8 = if (self.tz_offset_minutes >= 0) '+' else '-';
        const tz_hours = @abs(self.tz_offset_minutes) / 60;
        const tz_minutes = @abs(self.tz_offset_minutes) % 60;

        try writer.print("{d} {c}{d:0>2}{d:0>2}", .{
            self.seconds_from_epoch,
            tz_sign,
            tz_hours,
            tz_minutes,
        });
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
};

test "time serialization" {
    const allocator = std.testing.allocator;

    const time: Time = .{
        .seconds_from_epoch = 1640995200,
        .tz_offset_minutes = -120,
    };

    const serialized = try time.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized: Time = try .deserialize(serialized);

    try std.testing.expectEqual(time.seconds_from_epoch, deserialized.seconds_from_epoch);
    try std.testing.expectEqual(time.tz_offset_minutes, deserialized.tz_offset_minutes);
}

test "format time" {
    const allocator = std.testing.allocator;

    const test_ts = 1640995200;
    const test_offset = -120;
    const test_data = std.fmt.comptimePrint("{d} -0200", .{test_ts});

    const time: Time = .{
        .seconds_from_epoch = test_ts,
        .tz_offset_minutes = test_offset,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{time});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql time" {
    const ident: Time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -120 };
    const clone: Time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -120 };
    const other1: Time = .{ .seconds_from_epoch = 1640995199, .tz_offset_minutes = -120 };
    const other2: Time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -119 };

    try std.testing.expect(ident.eql(&clone));
    try std.testing.expect(clone.eql(&ident));
    try std.testing.expect(!ident.eql(&other1));
    try std.testing.expect(!ident.eql(&other2));
}

/// A signature.
/// It's a combination of an identity with a time.
pub const Signature = struct {
    identity: Identity,
    time: Time,

    /// Deserializes a signature.
    /// The string fields in the returned signature borrow from `data`,
    /// for this reason `data` must outlive the signature.
    pub fn deserialize(data: []const u8) !Signature {
        const email_end = std.mem.indexOf(u8, data, ">") orelse return error.InvalidFormat;

        return .{
            .identity = try .deserialize(data[0..(email_end + 1)]),
            .time = try .deserialize(data[(email_end + 2)..]),
        };
    }

    /// Serializes the signature content.
    pub fn serialize(self: *const Signature, allocator: Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{f} {f}", .{ self.identity, self.time });
    }

    /// Returns `true` if the two signatures are equal.
    pub fn eql(a: *const Signature, b: *const Signature) bool {
        return a.identity.eql(&b.identity) and a.time.eql(&b.time);
    }

    /// Formatting method for use with `std.io.Writer.print`.
    pub fn format(self: *const Signature, writer: *std.io.Writer) !void {
        try writer.print("{f} {f}", .{ self.identity, self.time });
    }
};

test "signature serialization" {
    const allocator = std.testing.allocator;

    const sign: Signature = .{
        .identity = .{
            .name = "Mario Rossi",
            .email = "mrossi@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_minutes = -120,
        },
    };

    const serialized = try sign.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized: Signature = try .deserialize(serialized);

    try std.testing.expectEqualStrings(sign.identity.name, deserialized.identity.name);
    try std.testing.expectEqualStrings(sign.identity.email, deserialized.identity.email);
    try std.testing.expectEqual(sign.time.seconds_from_epoch, deserialized.time.seconds_from_epoch);
    try std.testing.expectEqual(sign.time.tz_offset_minutes, deserialized.time.tz_offset_minutes);
}

test "format signature" {
    const allocator = std.testing.allocator;

    const test_name = "Mario Rossi";
    const test_email = "mrossi@example.com";
    const test_ts = 1640995200;
    const test_offset = -120;
    const test_data = std.fmt.comptimePrint("{s} <{s}> {d} -0200", .{ test_name, test_email, test_ts });

    const sign: Signature = .{
        .identity = .{
            .name = test_name,
            .email = test_email,
        },
        .time = .{
            .seconds_from_epoch = test_ts,
            .tz_offset_minutes = test_offset,
        },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{sign});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "eql signature" {
    const sign: Signature = .{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -120 },
    };
    const clone: Signature = .{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -120 },
    };
    const other1: Signature = .{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995199, .tz_offset_minutes = -120 },
    };
    const other2: Signature = .{
        .identity = .{ .name = "Mario Rossi", .email = "mrossi@example.com" },
        .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = -119 },
    };

    try std.testing.expect(sign.eql(&clone));
    try std.testing.expect(clone.eql(&sign));
    try std.testing.expect(!sign.eql(&other1));
    try std.testing.expect(!sign.eql(&other2));
}
