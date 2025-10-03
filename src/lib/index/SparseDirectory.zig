// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Indicates that the index contains sparse directory entries
//! (pointing to a tree instead of the list of file paths).
//! This struct has no fields because it is only a marker.
//! Conforms to the index extension interface.

const SparseDirectory = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Signature = @import("index_extension.zig").Signature;
const Extension = @import("index_extension.zig").Extension;

/// Returns an instance of the extension interface.
pub inline fn interface(self: SparseDirectory) Extension {
    return .{ .sparse_directory = self };
}

/// Frees referenced resources.
pub fn deinit(_: *const SparseDirectory, _: Allocator) void {}

/// Parses an index extension from `data`.
pub fn parse(_: Allocator, _: Signature, _: []u8) !SparseDirectory {
    return .{};
}

/// Writes the index extension to `buffer`.
pub fn writeTo(_: *const SparseDirectory, buffer: *std.ArrayList(u8)) !void {
    const type_bytes = Signature.sparse_directory.toBytes();
    try buffer.appendSlice(&type_bytes);
    try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
}

test "sparse directory extension" {
    const allocator = std.testing.allocator;

    const bytes: []u8 = @constCast(&[_]u8{
        's', 'd', 'i', 'r',
        0,   0,   0,   0,
    });

    var parsed = try Extension.parse(allocator, bytes);
    defer parsed.extension.deinit(allocator);

    try std.testing.expectEqualStrings(@tagName(parsed.extension), @tagName(Signature.sparse_directory));
    try std.testing.expect(parsed.len == bytes.len);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try parsed.extension.writeTo(&buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}
