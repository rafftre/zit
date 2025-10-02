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
    pub inline fn of(num: u4) Type {
        return std.meta.intToEnum(Type, num) catch .indeterminate;
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
    /// - Any other value will result in a descriptive string (the tag name).
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
            try writer.print("{s}", .{@tagName(self)});
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

test "format type" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const test_cases = [_]struct { Type, []const u8, []const u8 }{
        .{ Type.indeterminate, "{any}", "indeterminate" },
        .{ Type.directory, "{any}", "directory" },
        .{ Type.regular_file, "{any}", "regular_file" },
        .{ Type.symbolic_link, "{any}", "symbolic_link" },
        .{ Type.gitlink, "{any}", "gitlink" },
        .{ Type.indeterminate, "{b}", "0000" },
        .{ Type.directory, "{b}", "0100" },
        .{ Type.regular_file, "{b}", "1000" },
        .{ Type.symbolic_link, "{b}", "1010" },
        .{ Type.gitlink, "{b}", "1110" },
        .{ Type.indeterminate, "{o}", "00" },
        .{ Type.directory, "{o}", "04" },
        .{ Type.regular_file, "{o}", "10" },
        .{ Type.symbolic_link, "{o}", "12" },
        .{ Type.gitlink, "{o}", "16" },
    };

    inline for (test_cases) |c| {
        const val, const fmt, const expected = c;

        buf.clearRetainingCapacity();
        try std.fmt.format(buf.writer(), fmt, .{val});
        try std.testing.expectEqualSlices(u8, expected, buf.items);
    }
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

    /// Formatting method for use with `std.fmt.format`.
    ///
    /// The supported formats are:
    /// - 'b' for binary output
    /// - 'o' for octal string
    /// - Any other value will result in a string in the Unix format (i.e. "rwx").
    ///
    /// Options are ignored.
    pub fn format(
        self: AccessRights,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (std.mem.eql(u8, fmt, "b")) {
            const bits: u3 = @bitCast(self);
            try writer.print("{b:0>3}", .{bits});
        } else if (std.mem.eql(u8, fmt, "o")) {
            const bits: u3 = @bitCast(self);
            try writer.print("{o}", .{bits});
        } else {
            try writer.print("{s}{s}{s}", .{
                if (self.read) "r" else "-",
                if (self.write) "w" else "-",
                if (self.execute) "x" else "-",
            });
        }
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

    inline for (test_cases) |c| {
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

test "format access rights" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const test_cases = [_]struct { AccessRights, []const u8, []const u8 }{
        .{ AccessRights{}, "{any}", "---" },
        .{ AccessRights{ .execute = true }, "{any}", "--x" },
        .{ AccessRights{ .write = true }, "{any}", "-w-" },
        .{ AccessRights{ .read = true }, "{any}", "r--" },
        .{ AccessRights{ .write = true, .execute = true }, "{any}", "-wx" },
        .{ AccessRights{ .read = true, .execute = true }, "{any}", "r-x" },
        .{ AccessRights{ .read = true, .write = true }, "{any}", "rw-" },
        .{ AccessRights{ .read = true, .write = true, .execute = true }, "{any}", "rwx" },
        .{ AccessRights{}, "{b}", "000" },
        .{ AccessRights{ .execute = true }, "{b}", "001" },
        .{ AccessRights{ .write = true }, "{b}", "010" },
        .{ AccessRights{ .read = true }, "{b}", "100" },
        .{ AccessRights{ .write = true, .execute = true }, "{b}", "011" },
        .{ AccessRights{ .read = true, .execute = true }, "{b}", "101" },
        .{ AccessRights{ .read = true, .write = true }, "{b}", "110" },
        .{ AccessRights{ .read = true, .write = true, .execute = true }, "{b}", "111" },
        .{ AccessRights{}, "{o}", "0" },
        .{ AccessRights{ .execute = true }, "{o}", "1" },
        .{ AccessRights{ .write = true }, "{o}", "2" },
        .{ AccessRights{ .read = true }, "{o}", "4" },
        .{ AccessRights{ .write = true, .execute = true }, "{o}", "3" },
        .{ AccessRights{ .read = true, .execute = true }, "{o}", "5" },
        .{ AccessRights{ .read = true, .write = true }, "{o}", "6" },
        .{ AccessRights{ .read = true, .write = true, .execute = true }, "{o}", "7" },
    };

    inline for (test_cases) |c| {
        const val, const fmt, const expected = c;

        buf.clearRetainingCapacity();
        try std.fmt.format(buf.writer(), fmt, .{val});
        try std.testing.expectEqualSlices(u8, expected, buf.items);
    }
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

    /// Formatting method for use with `std.fmt.format`.
    ///
    /// The supported formats are:
    /// - 'b' for binary output
    /// - 'o' for octal string
    /// - Any other value will result in a string in the Unix format (i.e. "rwxrwxrwx").
    ///
    /// Options are ignored.
    pub fn format(
        self: Permissions,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (std.mem.eql(u8, fmt, "b")) {
            const bits: u9 = @bitCast(self);
            try writer.print("{b:0>9}", .{bits});
        } else if (std.mem.eql(u8, fmt, "o")) {
            const bits: u9 = @bitCast(self);
            try writer.print("{o:0>3}", .{bits});
        } else {
            try writer.print("{any}{any}{any}", .{ self.user, self.group, self.others });
        }
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

        try std.testing.expect(Permissions.eql(&perm, &expected));
    }
}

test "parse permissions string" {
    const test_cases = [_]struct { []const u8, Permissions }{
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

test "format permissions" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const test_cases = [_]struct { Permissions, []const u8, []const u8 }{
        .{ Permissions{}, "{any}", "---------" },
        .{ Permissions{ .others = .{ .read = true, .write = true, .execute = true } }, "{any}", "------rwx" },
        .{ Permissions{ .group = .{ .read = true, .write = true, .execute = true } }, "{any}", "---rwx---" },
        .{ Permissions{ .user = .{ .read = true, .write = true, .execute = true } }, "{any}", "rwx------" },
        .{
            Permissions{
                .group = .{ .read = true, .write = true, .execute = true },
                .others = .{ .read = true, .write = true, .execute = true },
            },
            "{any}",
            "---rwxrwx",
        },
        .{
            Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .others = .{ .read = true, .write = true, .execute = true },
            },
            "{any}",
            "rwx---rwx",
        },
        .{
            Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .write = true, .execute = true },
            },
            "{any}",
            "rwxrwx---",
        },
        .{
            Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .write = true, .execute = true },
                .others = .{ .read = true, .write = true, .execute = true },
            },
            "{any}",
            "rwxrwxrwx",
        },
    };

    inline for (test_cases) |c| {
        const val, const fmt, const expected = c;

        buf.clearRetainingCapacity();
        try std.fmt.format(buf.writer(), fmt, .{val});
        try std.testing.expectEqualSlices(u8, expected, buf.items);
    }
}

/// File mode.
/// It's a u16 integer composed by a sequence of:
/// - 4 bits file type,
/// - 3 null bits (0),
/// - 9 bits Unix permissions.
pub const Mode = packed struct(u16) {
    // Note: field order is the reverse of the bit layout
    permissions: Permissions = .{},
    nil: AccessRights = .{},
    type: Type = .indeterminate,

    /// Returns the mode for the given value.
    pub fn of(bits: u16) Mode {
        return @bitCast(bits);
    }

    /// Returns the integer value for this mode.
    pub fn toInt(self: Mode) u16 {
        return @bitCast(self);
    }

    /// Returns `true` if the modes are equal.
    pub inline fn eql(a: *const Mode, b: *const Mode) bool {
        const a_bits: u16 = @bitCast(a.*);
        const b_bits: u16 = @bitCast(b.*);
        return a_bits == b_bits;
    }

    /// Returns the mode for the given string (representing an octal number).
    pub fn parse(s: []const u8) !Mode {
        var type_str: []const u8 = undefined;
        var perm_str: []const u8 = undefined;

        if (s.len == 5) {
            type_str = s[0..1];
            perm_str = s[2..5];
        } else if (s.len == 6) {
            type_str = s[0..2];
            perm_str = s[3..6];
        } else {
            return error.InvalidFormat;
        }

        const perm_num = try std.fmt.parseInt(u9, perm_str, 8);

        return .{
            .type = try Type.parse(type_str),
            .permissions = Permissions.of(perm_num),
        };
    }

    /// Formatting method for use with `std.fmt.format`.
    /// Format and options are ignored.
    pub fn format(
        self: Mode,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{o}{o}{o}", .{ self.type, self.nil, self.permissions });
    }
};

test "mode from an to integer" {
    const test_cases = [_]struct { u16, Mode }{
        .{ 0, Mode{} },
        .{ 0o160764, Mode{
            .type = .gitlink,
            .permissions = Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .write = true },
                .others = .{ .read = true },
            },
        } },
    };

    for (test_cases) |c| {
        const bits, const expected = c;
        const mode = Mode.of(bits);
        const re = mode.toInt();

        try std.testing.expect(Mode.eql(&mode, &expected));
        try std.testing.expect(bits == re);
    }
}

test "parse mode string" {
    const test_cases = [_]struct { []const u8, Mode }{
        .{ "000000", Mode{} },
        .{ "40540", Mode{
            .type = .directory,
            .permissions = Permissions{
                .user = .{ .read = true, .execute = true },
                .group = .{ .read = true },
                .others = .{},
            },
        } },
        .{ "160764", Mode{
            .type = .gitlink,
            .permissions = Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .write = true },
                .others = .{ .read = true },
            },
        } },
    };

    for (test_cases) |c| {
        const s, const expected = c;
        const mode = try Mode.parse(s);

        try std.testing.expect(Mode.eql(&mode, &expected));
    }

    // errors
    try std.testing.expectError(error.InvalidFormat, Mode.parse(""));
    try std.testing.expectError(error.InvalidFormat, Mode.parse("0"));
    try std.testing.expectError(error.InvalidFormat, Mode.parse("0160764"));
}

test "format mode" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const test_cases = [_]struct { Mode, []const u8, []const u8 }{
        .{ Mode{}, "{any}", "000000" },
        .{ Mode{
            .type = .directory,
            .permissions = Permissions{
                .user = .{ .read = true, .execute = true },
                .group = .{ .read = true },
                .others = .{},
            },
        }, "{any}", "040540" },
        .{ Mode{
            .type = .gitlink,
            .permissions = Permissions{
                .user = .{ .read = true, .write = true, .execute = true },
                .group = .{ .read = true, .write = true },
                .others = .{ .read = true },
            },
        }, "{any}", "160764" },
    };

    inline for (test_cases) |c| {
        const val, const fmt, const expected = c;

        buf.clearRetainingCapacity();
        try std.fmt.format(buf.writer(), fmt, .{val});
        try std.testing.expectEqualSlices(u8, expected, buf.items);
    }
}
