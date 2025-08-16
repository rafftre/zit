// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

/// File modes for tree entries.
pub const FileMode = enum(u32) {
    tree = 0o40000,
    blob = 0o100644,
    executable = 0o100755,
    symlink = 0o120000,
    gitlink = 0o160000,

    /// Returns the file mode for the given string.
    pub fn of(s: []const u8) !FileMode {
        const i = try std.fmt.parseInt(u32, s, 8);
        return try std.meta.intToEnum(FileMode, i);
    }

    /// Formatting method for use with `std.fmt.format`.
    /// Format and options are ignored.
    pub fn format(
        self: FileMode,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        const label = switch (self) {
            .tree => "tree",
            .blob, .executable, .symlink => "blob",
            .gitlink => "submodule",
        };

        try writer.print("{s}", .{label});
    }
};
