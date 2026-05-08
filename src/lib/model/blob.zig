// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("util/hash.zig");
const Object = @import("object.zig").Object;
const LooseObject = @import("object.zig").LooseObject;

/// A blob object.
/// It's a sequence of binary data.
/// Conforms to the object interface.
pub fn Blob(comptime Hasher: type) type {
    return struct {
        content: []const u8,

        const Self = @This();

        /// Returns an instance of the object interface.
        pub fn interface(self: Self) Object(Hasher) {
            return .{ .blob = self };
        }

        /// No-op.
        pub fn deinit(_: *Self, _: Allocator) void {}

        /// Deserializes a blob.
        /// The returned content borrows from `obj`, for this reason `obj` must outlive the blob.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(obj: *const LooseObject(Hasher)) Self {
            return .{ .content = obj.content };
        }

        /// Serializes the blob.
        /// Caller owns the returned memory.
        /// Implements the method with the same name in the object interface.
        pub fn serialize(self: *const Self, allocator: Allocator) !LooseObject(Hasher) {
            return .{
                .object_type = .blob,
                .content = try allocator.dupe(u8, self.content),
            };
        }

        /// Formatting method for use with `std.Io.Writer.print`.
        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            try writer.print("{s}", .{self.content});
        }
    };
}

test "blob serialization" {
    const allocator = std.testing.allocator;
    const TestBlob = Blob(hash.Sha1);

    const blob: TestBlob = .{ .content = "Hello, Git blob!" };

    var serialized = try blob.serialize(allocator);
    defer serialized.deinit(allocator);

    const deserialized: TestBlob = .deserialize(&serialized);

    try std.testing.expectEqualSlices(u8, blob.content, deserialized.content);
}

test "format blob" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    const blob: Blob(hash.Sha1) = .{ .content = test_data };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{blob});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
