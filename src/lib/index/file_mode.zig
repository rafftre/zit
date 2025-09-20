// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

/// File modes for index entries.
pub const FileMode = enum(u32) {
    // bit layout:
    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | 0                             | type  | 0   | unix permission |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //
    // type:
    // - 0100 (0o4 ) directory
    // - 1000 (0o10) regular file
    // - 1010 (0o12) symbolic link
    // - 1110 (0o16) gitlink
    //
    // unix permission (3 x 3 bits):
    // - 0o644 regular file
    // - 0o664 regular file with group write
    // - 0o755 executable
    // - 0      symbolic link and gitlink

    indeterminate = 0,
    directory = 0o40000, // 0x4000
    regular_file = 0o100644, // 0x81a4
    executable = 0o100755, // 0x81ed
    symbolic_link = 0o120000, // 0xa000
    git_link = 0o160000, // 0xe000
    // 0o100664 is a deprecated mode supported by the first versions of Git.
    // This mode can still be found in old packfiles and should be treated as a regular file.

    /// Returns the file mode for the given string (representing an octal number).
    pub fn ofString(octal: []const u8) !FileMode {
        const n = try std.fmt.parseInt(u32, octal, 8);
        if (n == 0o100664) {
            return .regular_file;
        }
        return try std.meta.intToEnum(FileMode, n);
    }

    /// Returns the file mode for the given integer.
    pub inline fn ofNum(n: u32) FileMode {
        if (n == 0o100664) {
            return .regular_file;
        }
        return std.meta.intToEnum(FileMode, n) catch .indeterminate;
    }

    /// Formatting method for use with `std.fmt.format`.
    ///
    /// The supported formats are:
    /// - 'b' for binary output
    /// - 'o' for octal string
    /// - Any other value will result in a descriptive string ("blob", "tree", or "submodule").
    ///
    /// Options are ignored.
    pub fn format(
        self: FileMode,
        comptime fmt: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (std.mem.eql(u8, fmt, "b")) {
            try writer.print("{b}", .{@intFromEnum(self)});
        } else if (std.mem.eql(u8, fmt, "o")) {
            try writer.print("{o:0>6}", .{@intFromEnum(self)});
        } else {
            const label = switch (self) {
                .indeterminate => "",
                .directory => "tree",
                .git_link => "submodule",
                else => "blob",
            };

            try writer.print("{s}", .{label});
        }
    }
};

test "parse string" {
    try std.testing.expect(try FileMode.ofString("000000") == .indeterminate);
    try std.testing.expect(try FileMode.ofString("040000") == .directory);
    try std.testing.expect(try FileMode.ofString("100644") == .regular_file);
    try std.testing.expect(try FileMode.ofString("100664") == .regular_file);
    try std.testing.expect(try FileMode.ofString("100755") == .executable);
    try std.testing.expect(try FileMode.ofString("120000") == .symbolic_link);
    try std.testing.expect(try FileMode.ofString("160000") == .git_link);

    try std.testing.expect(try FileMode.ofString("0000000") == .indeterminate);
    try std.testing.expect(try FileMode.ofString("0040000") == .directory);
    try std.testing.expect(try FileMode.ofString("0100644") == .regular_file);
    try std.testing.expect(try FileMode.ofString("0100664") == .regular_file);
    try std.testing.expect(try FileMode.ofString("0100755") == .executable);
    try std.testing.expect(try FileMode.ofString("0120000") == .symbolic_link);
    try std.testing.expect(try FileMode.ofString("0160000") == .git_link);

    try std.testing.expectError(error.InvalidEnumTag, FileMode.ofString("140000"));
    try std.testing.expectError(error.InvalidCharacter, FileMode.ofString(""));
    try std.testing.expectError(error.InvalidCharacter, FileMode.ofString("abcdef"));
}

test "from integer" {
    try std.testing.expect(FileMode.ofNum(0o40000) == .directory);
    try std.testing.expect(FileMode.ofNum(0o100644) == .regular_file);
    try std.testing.expect(FileMode.ofNum(0o100664) == .regular_file);
    try std.testing.expect(FileMode.ofNum(0o100755) == .executable);
    try std.testing.expect(FileMode.ofNum(0o120000) == .symbolic_link);
    try std.testing.expect(FileMode.ofNum(0o160000) == .git_link);

    try std.testing.expect(FileMode.ofNum(0) == .indeterminate);
    try std.testing.expect(FileMode.ofNum(0o140000) == .indeterminate);
}

test "format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try std.fmt.format(buf.writer(), "{any}", .{FileMode.indeterminate});
    try std.testing.expectEqualSlices(u8, "", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{FileMode.directory});
    try std.testing.expectEqualSlices(u8, "tree", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{FileMode.regular_file});
    try std.testing.expectEqualSlices(u8, "blob", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{FileMode.executable});
    try std.testing.expectEqualSlices(u8, "blob", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{FileMode.symbolic_link});
    try std.testing.expectEqualSlices(u8, "blob", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{any}", .{FileMode.git_link});
    try std.testing.expectEqualSlices(u8, "submodule", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{b}", .{FileMode.regular_file});
    try std.testing.expectEqualSlices(u8, "1000000110100100", buf.items);

    buf.clearRetainingCapacity();
    try std.fmt.format(buf.writer(), "{o}", .{FileMode.regular_file});
    try std.testing.expectEqualSlices(u8, "100644", buf.items);
}
