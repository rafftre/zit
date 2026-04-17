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
/// A commit object takes ownership of all the referenced `tree` and `parents`.
pub fn Commit(comptime Hasher: type) type {
    return struct {
        tree: *ObjectId,
        parents: std.ArrayList(*ObjectId) = .empty,
        author: Signature,
        committer: Signature,
        message: []const u8,

        const Self = @This();
        const ObjectId = Object(Hasher).Id;

        /// Returns an instance of the object interface.
        pub fn interface(self: Self) Object(Hasher) {
            return .{ .commit = self };
        }

        /// Implements the method with the same name in the object interface.
        /// Note: this also frees the referenced `tree` and all `parents`.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.tree.deinit(allocator);
            for (self.parents.items) |p| {
                p.deinit(allocator);
            }
            self.parents.deinit(allocator);
            self.author.deinit(allocator);
            self.committer.deinit(allocator);
            allocator.free(self.message);
        }

        /// Adds a new commit as parent.
        pub fn addParent(self: *Self, allocator: Allocator, object_id: *ObjectId) !void {
            try self.parents.append(allocator, object_id);
        }

        /// Deserializes a commit.
        /// Deinitialize with `deinit`.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(allocator: Allocator, obj: *LooseObject(Hasher)) !Self {
            var tree: ?*ObjectId = null;
            var parents: std.ArrayList(*ObjectId) = .empty;
            var author: ?Signature = null;
            var committer: ?Signature = null;
            var msgbuf: std.ArrayList(u8) = .empty;
            errdefer {
                if (author) |*a| {
                    Signature.deinit(@constCast(a), allocator);
                }
                if (committer) |*c| {
                    Signature.deinit(@constCast(c), allocator);
                }
                parents.deinit(allocator);
                msgbuf.deinit(allocator);
            }

            var in_message = false;
            var skipping_header = false;

            var it = std.mem.splitScalar(u8, obj.content, '\n');
            while (it.next()) |line| {
                if (skipping_header) {
                    if (line.len > 0 and line[0] == ' ') {
                        continue;
                    } else {
                        skipping_header = false;
                    }
                }

                if (in_message) {
                    if (msgbuf.items.len > 0) {
                        try msgbuf.append(allocator, '\n');
                    }
                    try msgbuf.appendSlice(allocator, line);
                } else {
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    if (trimmed.len == 0) {
                        in_message = true;
                        continue;
                    }

                    const space_idx = std.mem.indexOf(u8, trimmed, " ");
                    if (space_idx) |i| {
                        const header = line[0..i];
                        const value = line[(i + 1)..];

                        if (std.mem.eql(u8, header, "tree") == true) {
                            tree = try .fromHex(allocator, value);
                        } else if (std.mem.eql(u8, header, "parent") == true) {
                            const object_id: *ObjectId = try .fromHex(allocator, value);
                            try parents.append(allocator, object_id);
                        } else if (std.mem.eql(u8, header, "author") == true) {
                            author = try .deserialize(allocator, value);
                        } else if (std.mem.eql(u8, header, "committer") == true) {
                            committer = try .deserialize(allocator, value);
                        } else {
                            skipping_header = true;
                        }
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
                .message = try msgbuf.toOwnedSlice(allocator),
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
            try writer.print("tree {f}\n", .{self.tree});

            for (self.parents.items) |parent| {
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
        .tree = try .fromHex(allocator, "1234567890abcdef1234567890abcdef12345678"),
        .author = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Author"),
                .email = try allocator.dupe(u8, "author@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .committer = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Committer"),
                .email = try allocator.dupe(u8, "committer@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995300, .tz_offset_minutes = 120 },
        },
        .message = try allocator.dupe(u8, "Test commit message"),
    };
    defer commit.deinit(allocator);

    try commit.addParent(allocator, try .fromHex(allocator, "fedcba0987654321fedcba0987654321fedcba09"));
    try commit.addParent(allocator, try .fromHex(allocator, "ba0987654321fedcba0987654321fedcba09fedc"));

    var serialized = try commit.serialize(allocator);
    defer serialized.deinit(allocator);

    var deserialized: TestCommit = try .deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(commit.tree.eql(deserialized.tree));
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
        .tree = try .fromHex(allocator, "1234567890abcdef1234567890abcdef12345678"),
        .author = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Author"),
                .email = try allocator.dupe(u8, "author@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .committer = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Committer"),
                .email = try allocator.dupe(u8, "committer@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995300, .tz_offset_minutes = 120 },
        },
        .message = try allocator.dupe(u8, "Test commit message"),
    };
    defer commit.deinit(allocator);

    try commit.addParent(allocator, try .fromHex(allocator, "fedcba0987654321fedcba0987654321fedcba09"));
    try commit.addParent(allocator, try .fromHex(allocator, "ba0987654321fedcba0987654321fedcba09fedc"));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{commit});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
