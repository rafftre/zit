// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Functions for reading and writing objects.

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("helpers.zig").hash;
const model = @import("model.zig");
const Object = model.Object;
const ObjectId = model.ObjectId;
const ObjectType = model.ObjectType;
const LooseObject = @import("LooseObject.zig");
const Sha1 = hash.Sha1;

const max_file_size = @import("storage.zig").max_file_size;

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

/// Reads the object content identified by `name` in the object store.
/// When `expected_type` is specified, the type read must match it, otherwise an error will be returned.
/// Caller owns the returned memory.
pub fn readObject(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// The name used to identify the object.
    name: []const u8,
    /// The expected type of the object, returns an error if it doesn't match.
    expected_type: ?[]const u8,
) !Object {
    try validateObjectName(name);

    const raw_content = try object_store.read(allocator, name);
    defer allocator.free(raw_content);

    if (raw_content.len == 0) return error.InvalidObject;

    const decoded = try LooseObject.decode(raw_content, Sha1, .{
        .expected_type = ObjectType.parse(expected_type),
    });
    switch (decoded.typ) {
        .known_type => |t| return try Object.deserialize(allocator, t, decoded.data),
        .unknown_tag => return error.UnknownType,
    }
}

/// Reads the type and the size of the object identified by `name` in the object store.
/// If `allow_unknown_type` is `true`, no error will be raised for an unknown type.
/// Caller owns the returned memory.
pub fn readTypeAndSize(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// The name used to identify the object.
    name: []const u8,
    /// If `true` no error will be raised for an unknown type.
    allow_unknown_type: bool,
) !struct { obj_type: []const u8, obj_size: usize } {
    try validateObjectName(name);

    const raw_content = try object_store.read(allocator, name);
    defer allocator.free(raw_content);

    if (raw_content.len == 0) return error.InvalidObject;

    const decoded = try LooseObject.decode(raw_content, Sha1, .{
        .allow_unknown_type = allow_unknown_type,
    });
    switch (decoded.typ) {
        .known_type => |t| return .{ .obj_type = @tagName(t), .obj_size = decoded.len },
        .unknown_tag => |t| if (allow_unknown_type) {
            return .{ .obj_type = t, .obj_size = decoded.len };
        } else {
            return error.UnknownType;
        },
    }
}

/// Reads the encoded content - i.e. header (type name, space, and length) and
/// serialized data - of the object identified by `name` in the object store.
/// Caller owns the returned memory.
pub fn readEncodedData(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// The name used to identify the object.
    name: []const u8,
) ![]u8 {
    try validateObjectName(name);
    return object_store.read(allocator, name);
}

inline fn validateObjectName(hex_string: []const u8) !void {
    _ = try ObjectId.parseHex(hex_string);
}
