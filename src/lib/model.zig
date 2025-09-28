// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for core object models.

pub const Identity = @import("model/Identity.zig");
pub const ModeType = @import("model/file_mode.zig").Type;
pub const Signature = @import("model/Signature.zig");
pub const Time = @import("model/Time.zig");

pub const ObjectId = @import("model/ObjectId.zig");

pub const Object = @import("model/object.zig").Object;
pub const ObjectType = @import("model/object.zig").Type;

pub const Blob = @import("model/Blob.zig");
pub const Commit = @import("model/Commit.zig");
pub const Tag = @import("model/Tag.zig");
pub const Tree = @import("model/Tree.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
