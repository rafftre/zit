// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! File-system utilities and support functions.

const std = @import("std");

/// File types.
pub const Type = enum(u4) {
    indeterminate = 0,
    directory = 0b100, //       4 (0o4 )
    regular_file = 0b1000, //   8 (0o10)
    symbolic_link = 0b1010, // 10 (0o12)
    gitlink = 0b1110, //       14 (0o16)

    /// Returns the type for the given integer.
    pub inline fn of(bits: u4) Type {
        return std.meta.intToEnum(Type, bits) catch .indeterminate;
    }

    /// Returns the type for the given string (representing an octal number).
    pub fn parse(octal: []const u8) !Type {
        const n = try std.fmt.parseInt(u4, octal, 8);
        return std.meta.intToEnum(Type, n) catch .indeterminate;
    }

    /// Formatting method for use with `std.fmt.format`.
    ///
    /// The supported formats are:
    /// - 'b' for binary output
    /// - 'o' for octal string
    /// - Any other value will result in a descriptive string ("tree", "blob", or "submodule").
    ///
    /// Options are ignored.
    pub fn format(
        self: Type,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (std.mem.eql(u8, fmt, "b")) {
            try writer.print("{b:0>4}", .{@intFromEnum(self)});
        } else if (std.mem.eql(u8, fmt, "o")) {
            try writer.print("{o:0>2}", .{@intFromEnum(self)});
        } else {
            //try writer.print("{s}", .{@tagName(self)});

            const label = switch (self) {
                .indeterminate => "",
                .directory => "tree",
                .gitlink => "submodule",
                else => "blob",
            };

            try writer.print("{s}", .{label});
        }
    }
};

test "type from integer" {
    try std.testing.expect(Type.of(4) == .directory);
    try std.testing.expect(Type.of(8) == .regular_file);
    try std.testing.expect(Type.of(10) == .symbolic_link);
    try std.testing.expect(Type.of(14) == .gitlink);
    try std.testing.expect(Type.of(0) == .indeterminate);
    try std.testing.expect(Type.of(1) == .indeterminate);
    try std.testing.expect(Type.of(15) == .indeterminate);
}

test "parse type string" {
    try std.testing.expect(try Type.parse("04") == .directory);
    try std.testing.expect(try Type.parse("10") == .regular_file);
    try std.testing.expect(try Type.parse("12") == .symbolic_link);
    try std.testing.expect(try Type.parse("16") == .gitlink);
    try std.testing.expect(try Type.parse("0") == .indeterminate);
    try std.testing.expect(try Type.parse("1") == .indeterminate);
    try std.testing.expect(try Type.parse("17") == .indeterminate);

    try std.testing.expectError(error.Overflow, Type.parse("20"));
    try std.testing.expectError(error.InvalidCharacter, Type.parse(""));
    try std.testing.expectError(error.InvalidCharacter, Type.parse("abcdef"));
}

test "format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{Type.indeterminate});
    try std.testing.expectEqualSlices(u8, "", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{Type.directory});
    try std.testing.expectEqualSlices(u8, "tree", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{Type.regular_file});
    try std.testing.expectEqualSlices(u8, "blob", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{Type.symbolic_link});
    try std.testing.expectEqualSlices(u8, "blob", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{Type.gitlink});
    try std.testing.expectEqualSlices(u8, "submodule", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{b}", .{Type.directory});
    try std.testing.expectEqualSlices(u8, "0100", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{o}", .{Type.directory});
    try std.testing.expectEqualSlices(u8, "04", buf.items);
}

/// Rights to access files and directories for read (r), write (w), and execute (x) operations.
pub const AccessRights = packed struct(u3) {
    // Note: field order is the reverse of the bit layout: rwx
    execute: bool = false,
    write: bool = false,
    read: bool = false,

    /// Returns the rights for the given value.
    pub fn of(bits: u3) AccessRights {
        return @bitCast(bits);
    }

    /// Returns the rights for the given string (representing a Unix format, e.g. "rwx", "r-x", "r--", etc.)
    /// Accepts malformed strings with a maximum length of 3 characters as:
    /// - Combinations of "r", "w", and "x" without dashes.
    /// - Strings containing generic characters other than "r", "w", and "x", which are ignored.
    pub fn parse(s: []const u8) !AccessRights {
        if (s.len > 3) {
            return error.InvalidFormat;
        }

        var res: AccessRights = .{};

        if (std.mem.indexOfPos(u8, s, 0, "r")) |ri| {
            res.read = ri >= 0;
        }
        if (std.mem.indexOfPos(u8, s, 0, "w")) |wi| {
            res.write = wi >= 0;
        }
        if (std.mem.indexOfPos(u8, s, 0, "x")) |xi| {
            res.execute = xi >= 0;
        }

        return res;
    }

    /// Returns `true` if the access rights are equal.
    pub inline fn eql(a: *const AccessRights, b: *const AccessRights) bool {
        return a.read == b.read and a.write == b.write and a.execute == b.execute;
    }
};

test "access rights from integer" {
    const test_cases = [_]struct { u3, AccessRights }{
        .{ 0, AccessRights{} },
        .{ 1, AccessRights{ .execute = true } },
        .{ 2, AccessRights{ .write = true } },
        .{ 4, AccessRights{ .read = true } },
        .{ 3, AccessRights{ .write = true, .execute = true } },
        .{ 5, AccessRights{ .read = true, .execute = true } },
        .{ 6, AccessRights{ .read = true, .write = true } },
        .{ 7, AccessRights{ .read = true, .write = true, .execute = true } },
    };

    for (test_cases) |c| {
        const bits, const expected = c;
        const perm = AccessRights.of(bits);

        try std.testing.expect(AccessRights.eql(&perm, &expected));
    }
}

test "parse access rights string" {
    const test_cases = [_]struct { []const u8, AccessRights }{
        // Unix format
        .{ "---", AccessRights{} },
        .{ "--x", AccessRights{ .execute = true } },
        .{ "-w-", AccessRights{ .write = true } },
        .{ "r--", AccessRights{ .read = true } },
        .{ "-wx", AccessRights{ .write = true, .execute = true } },
        .{ "r-x", AccessRights{ .read = true, .execute = true } },
        .{ "rw-", AccessRights{ .read = true, .write = true } },
        .{ "rwx", AccessRights{ .read = true, .write = true, .execute = true } },
        // char-only combinations
        .{ "", AccessRights{} },
        .{ "x", AccessRights{ .execute = true } },
        .{ "w", AccessRights{ .write = true } },
        .{ "r", AccessRights{ .read = true } },
        .{ "wx", AccessRights{ .write = true, .execute = true } },
        .{ "rx", AccessRights{ .read = true, .execute = true } },
        .{ "rw", AccessRights{ .read = true, .write = true } },
        // malformed 3-chars strings
        .{ "foo", AccessRights{} },
        .{ "wri", AccessRights{ .read = true, .write = true } },
    };

    for (test_cases) |c| {
        const s, const expected = c;
        const perm = try AccessRights.parse(s);

        try std.testing.expect(AccessRights.eql(&perm, &expected));
    }

    // errors
    try std.testing.expectError(error.InvalidFormat, AccessRights.parse("ping"));
}

/// Permissions to access files and directories for user (u), group (g), and other (o) classes,
/// each with specific rights for read, write, and execute operations.
pub const Permissions = packed struct(u9) {
    // Note: field order is the reverse of the bit layout: ugo
    others: AccessRights = .{},
    group: AccessRights = .{},
    user: AccessRights = .{},

    /// Returns the permissions for the given value.
    pub fn of(bits: u9) Permissions {
        return @bitCast(bits);
    }

    /// Returns `true` if the permissions are equal.
    pub inline fn eql(a: *const Permissions, b: *const Permissions) bool {
        const a_bits: u9 = @bitCast(a.*);
        const b_bits: u9 = @bitCast(b.*);
        return a_bits == b_bits;
    }

    /// Returns the permissions for the given string (representing a Unix format, e.g. "rwxrwxrwx", "rwxr-xr--", etc.)
    pub fn parse(s: []const u8) !Permissions {
        if (s.len != 9) {
            return error.InvalidFormat;
        }

        return .{
            .user = try AccessRights.parse(s[0..3]),
            .group = try AccessRights.parse(s[3..6]),
            .others = try AccessRights.parse(s[6..9]),
        };
    }
};

test "permissions from integer" {
    const test_cases = [_]struct { u9, Permissions }{
        .{ 0, Permissions{} },
        .{ 0o7, Permissions{ .others = .{ .read = true, .write = true, .execute = true } } },
        .{ 0o70, Permissions{ .group = .{ .read = true, .write = true, .execute = true } } },
        .{ 0o700, Permissions{ .user = .{ .read = true, .write = true, .execute = true } } },
        .{ 0o77, Permissions{
            .group = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
        .{ 0o707, Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
        .{ 0o770, Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .group = .{ .read = true, .write = true, .execute = true },
        } },
        .{ 0o777, Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .group = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
    };

    for (test_cases) |c| {
        const bits, const expected = c;
        const perm = Permissions.of(bits);
        //std.debug.print("{} -> {}\n", .{ bits, perm });

        try std.testing.expect(Permissions.eql(&perm, &expected));
    }
}

test "parse permissions string" {
    const test_cases = [_]struct { []const u8, Permissions }{
        // Unix format
        .{ "---------", Permissions{} },
        .{ "------rwx", Permissions{ .others = .{ .read = true, .write = true, .execute = true } } },
        .{ "---rwx---", Permissions{ .group = .{ .read = true, .write = true, .execute = true } } },
        .{ "rwx------", Permissions{ .user = .{ .read = true, .write = true, .execute = true } } },
        .{ "---rwxrwx", Permissions{
            .group = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
        .{ "rwx---rwx", Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
        .{ "rwxrwx---", Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .group = .{ .read = true, .write = true, .execute = true },
        } },
        .{ "rwxrwxrwx", Permissions{
            .user = .{ .read = true, .write = true, .execute = true },
            .group = .{ .read = true, .write = true, .execute = true },
            .others = .{ .read = true, .write = true, .execute = true },
        } },
    };

    for (test_cases) |c| {
        const s, const expected = c;
        const perm = try Permissions.parse(s);

        try std.testing.expect(Permissions.eql(&perm, &expected));
    }

    // errors
    try std.testing.expectError(error.InvalidFormat, Permissions.parse(""));
    try std.testing.expectError(error.InvalidFormat, Permissions.parse("ping"));
    try std.testing.expectError(error.InvalidFormat, Permissions.parse("drwxrwxrwx"));
}
