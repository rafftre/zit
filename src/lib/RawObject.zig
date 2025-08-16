// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! An object in raw format.
//! It can be used to encode or decode an object and consists of the serialized
//! data of the object, the type, and the length of the data.
//! When decoded, it retains the raw type name and length as they are read.
//!
//! An encoded object is a sequence of bytes formed by
//! - an header (object type name + space + data length),
//! - a null byte,
//! - the serialized binary data of the object.
//!
//! An instance of this struct can be the result of a fully determined object
//! (to be written to the store) or a set of parsed data (read from the store)
//! that may be incomplete or erroneous.

const RawObject = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Hasher = @import("hash.zig").Hasher;
const Object = @import("core/object.zig").Object;
const ObjectId = @import("core/ObjectId.zig");
const ObjectType = @import("core/object_type.zig").ObjectType;
const hex_chars = ObjectId.hex_chars;

pub const MaybeType = union(enum) {
    known_type: ObjectType,
    unknown_tag: []const u8,
};

data: []u8,
typ: MaybeType,
len: usize,

/// Initializes a raw object for a known type.
pub fn init(obj_type: ObjectType, data: []u8) RawObject {
    return .{
        .data = data,
        .typ = .{ .known_type = obj_type },
        .len = data.len,
    };
}

/// Encodes the object.
/// An encoded object is a sequence of bytes formed by
/// - an header (object type name + space + data length),
/// - a null byte,
/// - the serialized binary data of the object.
pub fn encode(self: *const RawObject, allocator: Allocator) ![]u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s} {d}\x00{s}",
        .{
            switch (self.typ) {
                .known_type => |typ| @tagName(typ),
                .unknown_tag => |typ| typ,
            },
            self.len,
            self.data,
        },
    );
}

/// Options for `decode`.
pub const DecodeOptions = struct {
    /// Set this to prevent an error from being returned when reading an unknown type.
    allow_unknown_type: bool = false,
    /// Use this to verify that the type matches.
    /// If not, `error.TypeMismatch` will be returned.
    expected_type: ?ObjectType = null,
    /// Use this to verify that the content matches.
    /// If not, `error.ObjectIdMismatch` will be returned.
    expected_id: ?ObjectId = null,
};

/// Decodes the encoded bytes of an object.
pub fn decode(bytes: []u8, options: DecodeOptions) !RawObject {
    const null_index = std.mem.indexOf(u8, bytes, "\x00") orelse return error.MissingHeader;
    if (null_index >= bytes.len) {
        return error.MissingHeader;
    }

    const space_index = std.mem.indexOf(u8, bytes, " ") orelse return error.MalformedHeader;
    if (space_index >= null_index or space_index >= bytes.len) {
        return error.MalformedHeader;
    }

    const type_str = bytes[0..space_index];
    const len_str = bytes[(space_index + 1)..null_index];
    const content = bytes[(null_index + 1)..];

    if (options.expected_id) |check_id| {
        var oid = Hasher.hashData(bytes);
        if (!check_id.eql(&oid)) {
            var buf: [hex_chars]u8 = undefined;
            try oid.toHexString(&buf);
            std.log.debug("Found mismatching object ID: '{s}'", .{buf});

            return error.ObjectIdMismatch;
        }
    }

    const maybe_type = try extractType(type_str, options.expected_type, options.allow_unknown_type);
    const len = try extractLength(len_str, content.len);

    return .{
        .data = content,
        .typ = maybe_type,
        .len = len,
    };
}

inline fn extractType(str: []u8, expected: ?ObjectType, allow_unknown: bool) !MaybeType {
    const typ = std.meta.stringToEnum(ObjectType, str) orelse {
        if (allow_unknown) {
            return .{ .unknown_tag = str };
        }
        return error.UnknownType;
    };

    if (expected) |e| {
        if (typ != e) return error.TypeMismatch;
    }

    return .{ .known_type = typ };
}

inline fn extractLength(str: []u8, expected: usize) !usize {
    const len = std.fmt.parseInt(usize, str, 10) catch return error.BadLength;
    if (len != expected) {
        return error.LengthMismatch;
    }
    return len;
}

test "encode" {
    const allocator = std.testing.allocator;

    const test_type = ObjectType.blob;
    const test_content = "Hello, Git blob!";
    const test_bytes = "blob 16\x00" ++ test_content;

    const raw_obj = init(test_type, @constCast(test_content));

    const encoded = try raw_obj.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, test_bytes, encoded);
}

test "decode" {
    const test_type = ObjectType.blob;
    const test_content = "Hello, Git blob!";
    const test_bytes = "blob 16\x00" ++ test_content;

    const test_hex = "420d00a951a59d664d3617a1f4f6e2de8091049f";
    const test_id = try ObjectId.parseHexString(test_hex);

    const decoded = try decode(@constCast(test_bytes), .{
        .expected_type = test_type,
        .expected_id = test_id,
    });

    try std.testing.expectEqual(test_type, decoded.typ.known_type);
    try std.testing.expectEqual(test_content.len, decoded.len);
    try std.testing.expectEqualSlices(u8, test_content, decoded.data);
}

test "decode errors" {
    const test_id = try ObjectId.parseHexString("30f51a3fba5274d53522d0f19748456974647b4f");

    // read known type while allowing unknown
    const known = try decode(@constCast("blob 13\x00hello, world!"), .{ .allow_unknown_type = true });
    try std.testing.expect(known.typ.known_type == .blob);
    try std.testing.expectEqual(13, known.len);
    try std.testing.expectEqualSlices(u8, "hello, world!", known.data);

    // read unknown type
    const unk = try decode(@constCast("test 13\x00hello, world!"), .{ .allow_unknown_type = true });
    try std.testing.expectEqualStrings("test", unk.typ.unknown_tag);
    try std.testing.expectEqual(13, unk.len);
    try std.testing.expectEqualSlices(u8, "hello, world!", unk.data);

    // read empty data
    const nodata = try decode(@constCast("blob 0\x00"), .{});
    try std.testing.expect(nodata.typ.known_type == .blob);
    try std.testing.expectEqual(0, nodata.len);
    try std.testing.expectEqualSlices(u8, "", nodata.data);

    // unknown type error
    try std.testing.expectError(
        error.UnknownType,
        decode(@constCast("test 13\x00hello, world!"), .{ .allow_unknown_type = false }),
    );

    // mismatching type error
    try std.testing.expectError(
        error.TypeMismatch,
        decode(@constCast("tree 13\x00hello, world!"), .{ .expected_type = .blob }),
    );

    // mismatching length error
    try std.testing.expectError(error.LengthMismatch, decode(@constCast("blob 12\x00hello, world!"), .{}));

    // bad length error
    try std.testing.expectError(error.BadLength, decode(@constCast("blob aa\x00hello, world!"), .{}));

    // mismatching object ID error
    try std.testing.expectError(
        error.ObjectIdMismatch,
        decode(@constCast("blob 13\x00hello, world"), .{ .expected_id = test_id }),
    );

    // missing header error
    try std.testing.expectError(error.MissingHeader, decode(@constCast("blob 130hello, world!"), .{}));
    try std.testing.expectError(error.MissingHeader, decode(@constCast("hello, world!"), .{}));
    try std.testing.expectError(error.MissingHeader, decode(@constCast("hello,world!"), .{}));
    try std.testing.expectError(error.MissingHeader, decode(@constCast(""), .{}));

    // malformed header error
    try std.testing.expectError(error.MalformedHeader, decode(@constCast("blob13\x00hello, world!"), .{}));
    try std.testing.expectError(error.MalformedHeader, decode(@constCast("blob13\x00hello,world!"), .{}));
}
