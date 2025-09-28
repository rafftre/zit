// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const file = @import("../helpers/file.zig");

/// Types of the supported file modes.
pub const Type = enum {
    none,
    blob,
    executable,
    tree,
    symlink,
    submodule,

    /// Returns the type for the given file mode.
    pub fn of(m: file.Mode) Type {
        return switch (m.type) {
            .directory => .tree,
            .symbolic_link => .symlink,
            .gitlink => .submodule,
            .regular_file => if (m.permissions.user.execute) .executable else .blob,
            else => .none,
        };
    }

    /// Returns the file mode for this type.
    pub fn mode(self: Type) file.Mode {
        return switch (self) {
            .none => .{},
            .tree => .{ .type = .directory },
            .symlink => .{ .type = .symbolic_link },
            .submodule => .{ .type = .gitlink },
            .blob => .{
                .type = .regular_file,
                .permissions = .{
                    .user = .{ .read = true, .write = true },
                    .group = .{ .read = true },
                    .others = .{ .read = true },
                },
            },
            .executable => .{
                .type = .regular_file,
                .permissions = .{
                    .user = .{ .read = true, .write = true, .execute = true },
                    .group = .{ .read = true, .execute = true },
                    .others = .{ .read = true, .execute = true },
                },
            },
        };
    }
};
