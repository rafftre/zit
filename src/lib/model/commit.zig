// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("util/hash.zig");
const Object = @import("object.zig").Object;
const LooseObject = @import("object.zig").LooseObject;
const Signature = @import("signature.zig").Signature;

/// A commit object, i.e. a directory tree snapshot.
/// It contains
/// - the object ID of the top-level tree,
/// - the list of parents commits (as object IDs) if any
/// - the author and committer signatures,
/// - a text message.
/// Conforms to the object interface.
/// String fields (author, committer, message) borrow from the LooseObject used during deserialization.
/// The `parents` ArrayList is owned and freed by `deinit`.
pub fn Commit(comptime Hasher: type) type {
    return struct {
        tree: ObjectId,
        parents: std.ArrayList(ObjectId) = .empty,
        author: Signature,
        committer: Signature,
        message: []const u8,

        const Self = @This();
        const ObjectId = Object(Hasher).Id;

        /// Returns an instance of the object interface.
        pub fn interface(self: Self) Object(Hasher) {
            return .{ .commit = self };
        }

        /// Frees the `parents` list.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.parents.deinit(allocator);
        }

        /// Adds a new commit as parent.
        pub fn addParent(self: *Self, allocator: Allocator, object_id: ObjectId) !void {
            try self.parents.append(allocator, object_id);
        }

        /// Deserializes a commit.
        /// String fields in the returned commit borrow from `obj.content`,
        /// for this reason `obj` must outlive the commit.
        /// Deinitialize with `deinit` to free the `parents` list.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(allocator: Allocator, obj: *const LooseObject(Hasher)) !Self {
            const body_sep = std.mem.indexOf(u8, obj.content, "\n\n") orelse return error.InvalidCommitFormat;
            const headers_part = obj.content[0..body_sep];
            const message: []const u8 = obj.content[(body_sep + 2)..];

            var tree: ?ObjectId = null;
            var author: ?Signature = null;
            var committer: ?Signature = null;
            var parents: std.ArrayList(ObjectId) = .empty;
            errdefer parents.deinit(allocator);

            var skipping_header = false;

            var it = std.mem.splitScalar(u8, headers_part, '\n');
            while (it.next()) |line| {
                if (skipping_header) {
                    if (line.len > 0 and line[0] == ' ') {
                        continue;
                    } else {
                        skipping_header = false;
                    }
                }

                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len == 0) continue;

                const space_idx = std.mem.indexOf(u8, trimmed, " ");
                if (space_idx) |i| {
                    const header = trimmed[0..i];
                    const value = trimmed[(i + 1)..];

                    if (std.mem.eql(u8, header, "tree")) {
                        tree = try .fromHex(value);
                    } else if (std.mem.eql(u8, header, "parent")) {
                        const object_id: ObjectId = try .fromHex(value);
                        try parents.append(allocator, object_id);
                    } else if (std.mem.eql(u8, header, "author")) {
                        author = try Signature.deserialize(value);
                    } else if (std.mem.eql(u8, header, "committer")) {
                        committer = try Signature.deserialize(value);
                    } else {
                        skipping_header = true;
                    }
                }
            }

            if (tree == null or author == null or committer == null) {
                return error.InvalidCommitFormat;
            }

            return .{
                .tree = tree.?,
                .parents = parents,
                .author = author.?,
                .committer = committer.?,
                .message = message,
            };
        }

        /// Serializes the commit.
        /// Caller owns the returned memory.
        /// Implements the method with the same name in the object interface.
        pub fn serialize(self: *const Self, allocator: Allocator) !LooseObject(Hasher) {
            var result: std.ArrayList(u8) = .empty;
            defer result.deinit(allocator);

            try result.print(allocator, "{f}", .{self});

            return .{
                .object_type = .commit,
                .content = try result.toOwnedSlice(allocator),
            };
        }

        /// Formatting method for use with `std.io.Writer.print`.
        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            try writer.print("tree {f}\n", .{&self.tree});

            for (self.parents.items) |*parent| {
                try writer.print("parent {f}\n", .{parent});
            }

            try writer.print(
                \\author {f}
                \\committer {f}
                \\
                \\{s}
            , .{ self.author, self.committer, self.message });
        }
    };
}

test "commit serialization" {
    const allocator = std.testing.allocator;
    const TestCommit = Commit(hash.Sha1);

    var commit: TestCommit = .{
        .tree = try .fromHex("1234567890abcdef1234567890abcdef12345678"),
        .author = .{
            .identity = .{
                .name = "Test Author",
                .email = "author@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .committer = .{
            .identity = .{
                .name = "Test Committer",
                .email = "committer@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995300, .tz_offset_minutes = 120 },
        },
        .message = "Test commit message",
    };
    defer commit.deinit(allocator);

    try commit.addParent(allocator, try .fromHex("fedcba0987654321fedcba0987654321fedcba09"));
    try commit.addParent(allocator, try .fromHex("ba0987654321fedcba0987654321fedcba09fedc"));

    var serialized = try commit.serialize(allocator);
    defer serialized.deinit(allocator);

    var deserialized: TestCommit = try .deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(commit.tree.eql(&deserialized.tree));
    try std.testing.expectEqual(2, deserialized.parents.items.len);
    try std.testing.expect(commit.author.eql(&deserialized.author));
    try std.testing.expect(commit.committer.eql(&deserialized.committer));
    try std.testing.expectEqualStrings(commit.message, deserialized.message);
}

test "format commit" {
    const allocator = std.testing.allocator;
    const TestCommit = Commit(hash.Sha1);

    const test_data =
        \\tree 1234567890abcdef1234567890abcdef12345678
        \\parent fedcba0987654321fedcba0987654321fedcba09
        \\parent ba0987654321fedcba0987654321fedcba09fedc
        \\author Test Author <author@example.com> 1640995200 +0200
        \\committer Test Committer <committer@example.com> 1640995300 +0200
        \\
        \\Test commit message
    ;

    var commit: TestCommit = .{
        .tree = try .fromHex("1234567890abcdef1234567890abcdef12345678"),
        .author = .{
            .identity = .{
                .name = "Test Author",
                .email = "author@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .committer = .{
            .identity = .{
                .name = "Test Committer",
                .email = "committer@example.com",
            },
            .time = .{ .seconds_from_epoch = 1640995300, .tz_offset_minutes = 120 },
        },
        .message = "Test commit message",
    };
    defer commit.deinit(allocator);

    try commit.addParent(allocator, try .fromHex("fedcba0987654321fedcba0987654321fedcba09"));
    try commit.addParent(allocator, try .fromHex("ba0987654321fedcba0987654321fedcba09fedc"));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{commit});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
