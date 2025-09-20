// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! An index extension that is not understood.
//! Conforms to the index extension interface.

const UnknownExtension = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Signature = @import("index_extension.zig").Signature;
const Extension = @import("index_extension.zig").Extension;

signature: Signature,
data: []u8,

/// Returns an instance of the extension interface.
pub inline fn interface(self: UnknownExtension) Extension {
    return .{ .unknown = self };
}

/// Frees referenced resources.
pub fn deinit(self: *const UnknownExtension, allocator: Allocator) void {
    allocator.free(self.data);
}

/// Writes the index extension to `buffer`.
pub fn writeTo(self: *const UnknownExtension, buffer: *std.ArrayList(u8)) !void {
    const type_bytes = self.signature.toBytes();
    try buffer.appendSlice(&type_bytes);
    try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(self.data.len))));
    try buffer.appendSlice(self.data);
}

/// Parses an index extension from `data`.
pub fn parse(allocator: Allocator, signature: Signature, data: []u8) !UnknownExtension {
    return .{
        .signature = signature,
        .data = try allocator.dupe(u8, data),
    };
}

test "unknown extension" {
    const allocator = std.testing.allocator;

    const bytes: []u8 = @constCast(&[_]u8{
        'S', 'I', 'G', 'N',
        0,   0,   0,   17,
        'u', 'n', 'k', 'n',
        'o', 'w', 'n', ' ',
        'e', 'x', 't', 'e',
        'n', 's', 'i', 'o',
        'n',
    });

    var parsed = try Extension.parse(allocator, bytes);
    defer parsed.extension.deinit(allocator);

    try std.testing.expect(parsed.len == bytes.len);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try parsed.extension.writeTo(&buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

test "unknown extension errors" {
    const allocator = std.testing.allocator;

    const too_short_v1: []u8 = @constCast(&[_]u8{
        'S', 'I', 'G', 'N',
        0,   0,   0,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, Extension.parse(allocator, too_short_v1));

    const too_short_v2: []u8 = @constCast(&[_]u8{
        'S', 'I', 'G', 'N',
        0,   0,   0,   17,
        'u', 'n', 'k', 'n',
        'o', 'w', 'n', ' ',
        'e', 'x', 't', 'e',
        'n', 's', 'i', 'o',
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, Extension.parse(allocator, too_short_v2));

    const unk: []u8 = @constCast(&[_]u8{
        't', 'e', 's', 't',
        0,   0,   0,   4,
        't', 'e', 's', 't',
    });
    try std.testing.expectError(error.UnknownExtension, Extension.parse(allocator, unk));
}
