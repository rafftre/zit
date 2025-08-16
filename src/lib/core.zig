// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! Git core objects.

const std = @import("std");

pub const FileMode = @import("core/file_mode.zig").FileMode;
pub const ObjectType = @import("core/object_type.zig").ObjectType;

pub const Object = @import("core/object.zig").Object;
pub const ObjectId = @import("core/ObjectId.zig");

pub const Blob = @import("core/Blob.zig");
pub const Commit = @import("core/Commit.zig");
pub const Identity = @import("core/Identity.zig");
pub const Signature = @import("core/Signature.zig");
pub const Tag = @import("core/Tag.zig");
pub const Tree = @import("core/Tree.zig");
pub const TreeEntry = @import("core/TreeEntry.zig");

pub const ObjectStore = @import("core/ObjectStore.zig");
pub const Repository = @import("core/Repository.zig");

test {
    std.testing.refAllDecls(@This());
}
