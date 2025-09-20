// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Logic for the hash-object command.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("helpers.zig").hash;
const model = @import("model.zig");
const Object = model.Object;
const ObjectType = model.ObjectType;
const LooseObject = @import("LooseObject.zig");
const Sha1 = hash.Sha1; // XXX: locked to SHA-1

const max_file_size: usize = 1024 * 1024 * 1024; // XXX: dup of GitObjectStore.max_file_size...

/// Computes the object's identifier name and optionally writes to the object store.
/// `type_str` is the type of the object, returns an error if it is not a valid type.
/// When `check_format` is `true`, it checks that the content passes the standard object parsing.
/// If `persist` is `true` writes to the object store.
/// Caller owns the returned memory.
pub fn hashObject(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// A generic reader instance from which the content will be read.
    reader: anytype,
    /// The type of the object, returns an error if it is not a valid type.
    type_str: []const u8,
    /// `true` means the object must pass standard object parsing otherwise an error is returned.
    check_format: bool,
    /// `true` means the object will be saved into the object store.
    persist: bool,
) ![]const u8 {
    var stream = std.io.bufferedReader(reader);

    const raw_content = try stream.reader().readAllAlloc(allocator, max_file_size);
    defer allocator.free(raw_content);

    const obj_type = ObjectType.parse(type_str) orelse return error.InvalidType;

    const maybe_parsed = if (check_format) try Object.deserialize(allocator, obj_type, raw_content) else null;
    defer {
        if (maybe_parsed) |p| {
            p.deinit(allocator);
        }
    }

    const loose_obj = LooseObject.init(obj_type, raw_content);

    const encoded = try loose_obj.encode(allocator);
    defer allocator.free(encoded);

    var oid: [Sha1.hash_size]u8 = undefined;
    Sha1.hashData(encoded, &oid);

    const hex = try allocator.alloc(u8, Sha1.hash_size * 2);
    errdefer allocator.free(hex);

    try hash.toHex(&oid, hex);

    if (persist) {
        try object_store.write(allocator, hex, encoded);
    }

    return hex;
}
