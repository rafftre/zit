// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("object.zig").Object;
const Blob = @import("Blob.zig");
const Commit = @import("Commit.zig");
const Tag = @import("Tag.zig");
const Tree = @import("Tree.zig");

/// The tag for an Object
pub const ObjectType = enum(u3) {
    blob,
    commit,
    tag,
    tree,

    /// Returns the tag of an object.
    pub fn of(obj: Object) ObjectType {
        switch (obj) {
            .blob => return ObjectType.blob,
            .commit => return ObjectType.commit,
            .tag => return ObjectType.tag,
            .tree => return ObjectType.tree,
        }
    }

    /// Parses a tag from a string.
    pub fn parse(type_str: ?[]const u8) ?ObjectType {
        if (type_str) |s| {
            return std.meta.stringToEnum(ObjectType, s);
        }
        return null;
    }
};
