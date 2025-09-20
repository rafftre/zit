// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! A commit object.
//! It specifies
//! - the top-level tree,
//! - the parent commits if any,
//! - the author/commiter information,
//! - a message.
//! Conforms to the object interface.

const Commit = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Object = @import("object.zig").Object;
const ObjectId = @import("ObjectId.zig");
const Signature = @import("Signature.zig");

tree: ObjectId,
parents: std.ArrayList(ObjectId) = undefined,
author: Signature,
committer: Signature,
message: []const u8,

/// Returns an instance of the object interface.
pub inline fn interface(self: Commit) Object {
    return .{ .commit = self };
}

/// Initializes this struct.
pub fn init(props: anytype) Commit {
    return std.mem.zeroInit(Commit, props);
}

/// Frees referenced resources.
pub fn deinit(self: *const Commit, allocator: Allocator) void {
    self.parents.deinit();
    self.author.deinit(allocator);
    self.committer.deinit(allocator);
    allocator.free(self.message);
}

/// Adds a new entry to the tree.
pub fn addParent(self: *Commit, name: []const u8) !void {
    const oid = try ObjectId.parseHex(name);
    try self.parents.append(oid);
}

/// Deserializes a commit from `data`.
/// Free with `deinit`.
pub fn deserialize(allocator: Allocator, data: []const u8) !Commit {
    var tree: ?ObjectId = null;
    var parents = std.ArrayList(ObjectId).init(allocator);
    var author: ?Signature = null;
    var committer: ?Signature = null;

    errdefer {
        parents.deinit();
        if (author) |a| a.deinit(allocator);
        if (committer) |c| c.deinit(allocator);
    }

    var msgbuf = std.ArrayList(u8).init(allocator);
    errdefer msgbuf.deinit();

    var in_message = false;
    var in_pgpsign = false;

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (in_pgpsign) {
            if (line.len > 0 and line[0] == ' ') {
                _ = std.mem.trimLeft(u8, line, " ");
                continue;
            } else {
                in_pgpsign = false;
            }
        }

        if (in_message) {
            if (msgbuf.items.len > 0) {
                try msgbuf.append('\n');
            }
            try msgbuf.appendSlice(line);
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
                    tree = try ObjectId.parseHex(value);
                } else if (std.mem.eql(u8, header, "parent") == true) {
                    const oid = try ObjectId.parseHex(value);
                    try parents.append(oid);
                } else if (std.mem.eql(u8, header, "author") == true) {
                    author = try Signature.deserialize(allocator, value);
                } else if (std.mem.eql(u8, header, "committer") == true) {
                    committer = try Signature.deserialize(allocator, value);
                } else if (std.mem.eql(u8, header, "gpgsig") == true) {
                    in_pgpsign = true;
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
        .message = try msgbuf.toOwnedSlice(),
    };
}

/// Serializes the commit content.
/// Caller owns the returned memory.
pub fn serialize(self: *const Commit, allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try result.writer().print("{any}", .{self});

    return try result.toOwnedSlice();
}

/// Formatting method for use with `std.fmt.format`.
/// Format and options are ignored.
pub fn format(
    self: Commit,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try writer.print("tree {any}\n", .{self.tree});

    for (self.parents.items) |parent| {
        try writer.print("parent {any}\n", .{parent});
    }

    try writer.print(
        \\author {any}
        \\committer {any}
        \\
        \\{s}
    , .{ self.author, self.committer, self.message });
}

test "serialize and deserialize" {
    const allocator = std.testing.allocator;

    const tree_id = try ObjectId.parseHex("1234567890abcdef1234567890abcdef12345678");

    const author = Signature.init(.{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });
    const committer = Signature.init(.{
        .identity = .{
            .name = "Test Committer",
            .email = "committer@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995300,
            .tz_offset_min = 120,
        },
    });

    var commit = init(.{
        .tree = tree_id,
        .parents = std.ArrayList(ObjectId).init(allocator),
        .author = author,
        .committer = committer,
        .message = "Test commit message",
    });
    defer commit.parents.deinit();

    try commit.addParent("fedcba0987654321fedcba0987654321fedcba09");
    try commit.addParent("ba0987654321fedcba0987654321fedcba09fedc");

    const serialized = try commit.serialize(allocator);
    defer allocator.free(serialized);

    var deserialized = try deserialize(allocator, serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(commit.tree.eql(&deserialized.tree));
    try std.testing.expectEqual(2, deserialized.parents.items.len);
    try std.testing.expect(commit.author.eql(&deserialized.author));
    try std.testing.expect(commit.committer.eql(&deserialized.committer));
    try std.testing.expectEqualStrings(commit.message, deserialized.message);
}

test "format" {
    const allocator = std.testing.allocator;

    const test_data =
        \\tree 1234567890abcdef1234567890abcdef12345678
        \\parent fedcba0987654321fedcba0987654321fedcba09
        \\parent ba0987654321fedcba0987654321fedcba09fedc
        \\author Test Author <author@example.com> 1640995200 +0200
        \\committer Test Committer <committer@example.com> 1640995300 +0200
        \\
        \\Test commit message
    ;

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    const tree_id = try ObjectId.parseHex("1234567890abcdef1234567890abcdef12345678");

    const author = Signature.init(.{
        .identity = .{
            .name = "Test Author",
            .email = "author@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995200,
            .tz_offset_min = 120,
        },
    });
    const committer = Signature.init(.{
        .identity = .{
            .name = "Test Committer",
            .email = "committer@example.com",
        },
        .time = .{
            .seconds_from_epoch = 1640995300,
            .tz_offset_min = 120,
        },
    });

    var commit = init(.{
        .tree = tree_id,
        .parents = std.ArrayList(ObjectId).init(allocator),
        .author = author,
        .committer = committer,
        .message = "Test commit message",
    });
    defer commit.parents.deinit();

    try commit.addParent("fedcba0987654321fedcba0987654321fedcba09");
    try commit.addParent("ba0987654321fedcba0987654321fedcba09fedc");

    try std.fmt.format(buf.writer(), "{any}", .{commit});

    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
