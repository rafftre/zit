// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("util/hash.zig");

pub const Blob = @import("blob.zig").Blob;
pub const Commit = @import("commit.zig").Commit;
pub const Tag = @import("tag.zig").Tag;
pub const Tree = @import("tree.zig").Tree;
pub const TreeEntryType = @import("tree.zig").EntryType;

/// The type for an object.
pub const Type = enum(u4) {
    blob,
    commit,
    tag,
    tree,
    _,

    /// Parses a tag from a string.
    /// Returns null when the tag is unknown.
    pub fn parse(str: ?[]const u8) ?Type {
        if (str) |s| {
            return std.meta.stringToEnum(Type, s);
        }
        return null;
    }

    /// Converts the tag to an optional string.
    /// Returns null when the tag is unknown.
    pub fn toString(typ: Type) ?[]const u8 {
        return switch (typ) {
            .blob, .commit, .tag, .tree => @tagName(typ),
            else => null,
        };
    }

    /// Returns `true` if t is a knwon tag.
    pub fn isKnown(typ: Type) bool {
        return switch (typ) {
            .blob, .commit, .tag, .tree => true,
            else => false,
        };
    }
};

/// An object in raw format.
/// It's a binary blob of data with a type name.
pub fn LooseObject(comptime Hasher: type) type {
    return struct {
        object_type: Type = .blob,
        content: []u8,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.content);
        }

        /// Encodes the object as a sequence of bytes formed by
        /// - an header (object type name + space + data length),
        /// - a null byte,
        /// - the serialized binary data of the object.
        pub fn encode(self: *const Self, allocator: Allocator) ![]u8 {
            const type_name = self.object_type.toString() orelse "unknown";
            return try std.fmt.allocPrint(
                allocator,
                "{s} {d}\x00{s}",
                .{ type_name, self.content.len, self.content },
            );
        }

        /// Options for `decode`.
        pub const DecodeOptions = struct {
            /// Set this to prevent an error from being returned when reading an unknown tag.
            allow_unknown_type: bool = false,
            /// Use this to verify that the type name matches.
            /// If not, `error.TypeMismatch` will be returned.
            expected_type: ?Type = null,
            /// Use this to verify that the content matches.
            /// If not, `error.HashMismatch` will be returned.
            expected_hash: ?[Hasher.hash_size]u8 = null,
        };

        /// Decodes into an object the sequence of bytes formed by
        /// - an header (object type name + space + data length),
        /// - a null byte,
        /// - the serialized binary data of the object.
        /// Deinitialize with `deinit`.
        pub fn decode(allocator: Allocator, bytes: []u8, options: DecodeOptions) !Self {
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

            try checkHash(bytes, options.expected_hash);
            try checkLength(len_str, content.len);
            const typ = try extractType(type_str, options.expected_type, options.allow_unknown_type);

            return .{ .object_type = typ, .content = try allocator.dupe(u8, content) };
        }

        /// Formatting method for use with `std.io.Writer.print`.
        /// Outputs content as a string.
        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            try writer.print("{s}", .{self.content});
        }

        fn checkHash(bytes: []u8, expected: ?[Hasher.hash_size]u8) !void {
            if (expected) |check_id| {
                var obj_id: [Hasher.hash_size]u8 = undefined;
                Hasher.hashData(bytes, &obj_id);

                if (!std.mem.eql(u8, &check_id, &obj_id)) {
                    var obj_id_buf: [Hasher.hash_size * 2]u8 = undefined;
                    var w: std.io.Writer = .fixed(&obj_id_buf);
                    try hash.formatAsHex(&obj_id, &w);

                    std.log.debug("Found mismatching ID: '{s}'", .{obj_id});
                    return error.HashMismatch;
                }
            }
        }

        fn checkLength(str: []u8, expected: usize) !void {
            const len = std.fmt.parseInt(usize, str, 10) catch return error.BadLength;
            if (len != expected) {
                std.log.debug("Found mismatching length: {d}", .{len});
                return error.LengthMismatch;
            }
        }

        fn extractType(str: []u8, expected: ?Type, allow_unknown: bool) !Type {
            const typ = std.meta.stringToEnum(Type, str) orelse {
                if (allow_unknown) {
                    std.log.debug("Found unknown type: '{s}'", .{str});
                    return @enumFromInt(@typeInfo(Type).@"enum".fields.len);
                }
                return error.UnknownType;
            };

            if (expected) |e| {
                if (typ != e) return error.TypeMismatch;
            }

            return typ;
        }
    };
}

test "format loose object" {
    const test_data = "Hello, Git blob!";

    var buf: [32]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);

    const self: LooseObject(hash.Sha1) = .{
        .object_type = .blob,
        .content = @constCast(test_data),
    };
    try w.print("{f}", .{self});

    try std.testing.expectEqualStrings(test_data, w.buffered());
}

test "encode object" {
    const allocator = std.testing.allocator;

    const test_content = "Hello, Git blob!";
    const test_bytes = "blob 16\x00" ++ test_content;

    const obj: LooseObject(hash.Sha1) = .{ .content = @constCast(test_content) };

    const encoded = try obj.encode(allocator);
    defer allocator.free(encoded);

    try std.testing.expectEqualStrings(test_bytes, encoded);
}

test "decode object" {
    const allocator = std.testing.allocator;

    const test_type: Type = .blob;
    const test_content = "Hello, Git blob!";
    const test_bytes = "blob 16\x00" ++ test_content;

    const test_hex = "420d00a951a59d664d3617a1f4f6e2de8091049f";

    var test_hash: [hash.Sha1.hash_size]u8 = undefined;
    try hash.parseHex(test_hex, &test_hash);

    var decoded = try LooseObject(hash.Sha1).decode(
        allocator,
        @constCast(test_bytes),
        .{
            .expected_type = test_type,
            .expected_hash = test_hash,
        },
    );
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(test_type, decoded.object_type);
    try std.testing.expectEqual(test_content.len, decoded.content.len);
    try std.testing.expectEqualStrings(test_content, decoded.content);
}

test "decode object errors" {
    const allocator = std.testing.allocator;
    const object = LooseObject(hash.Sha1);

    var test_hash: [hash.Sha1.hash_size]u8 = undefined;
    try hash.parseHex("30f51a3fba5274d53522d0f19748456974647b4f", &test_hash);

    // read known tag while allowing unknown
    var known = try object.decode(
        allocator,
        @constCast("blob 13\x00hello, world!"),
        .{ .allow_unknown_type = true },
    );
    defer known.deinit(allocator);
    try std.testing.expect(known.object_type == .blob);
    try std.testing.expectEqual(13, known.content.len);
    try std.testing.expectEqualSlices(u8, "hello, world!", known.content);

    // read unknown tag
    var unk = try object.decode(
        allocator,
        @constCast("test 13\x00hello, world!"),
        .{ .allow_unknown_type = true },
    );
    defer unk.deinit(allocator);
    try std.testing.expect(!unk.object_type.isKnown());
    try std.testing.expectEqual(13, unk.content.len);
    try std.testing.expectEqualSlices(u8, "hello, world!", unk.content);

    // read empty data
    var nodata = try object.decode(allocator, @constCast("blob 0\x00"), .{});
    defer nodata.deinit(allocator);
    try std.testing.expect(nodata.object_type == .blob);
    try std.testing.expectEqual(0, nodata.content.len);
    try std.testing.expectEqualSlices(u8, "", nodata.content);

    // unknown tag error
    try std.testing.expectError(
        error.UnknownType,
        object.decode(allocator, @constCast("test 13\x00hello, world!"), .{ .allow_unknown_type = false }),
    );

    // mismatching tag error
    try std.testing.expectError(
        error.TypeMismatch,
        object.decode(allocator, @constCast("tree 13\x00hello, world!"), .{ .expected_type = .blob }),
    );

    // mismatching length error
    try std.testing.expectError(
        error.LengthMismatch,
        object.decode(allocator, @constCast("blob 12\x00hello, world!"), .{}),
    );

    // bad length error
    try std.testing.expectError(
        error.BadLength,
        object.decode(allocator, @constCast("blob aa\x00hello, world!"), .{}),
    );

    // mismatching object ID error
    try std.testing.expectError(
        error.HashMismatch,
        object.decode(allocator, @constCast("blob 13\x00hello, world"), .{ .expected_hash = test_hash }),
    );

    // missing header error
    try std.testing.expectError(
        error.MissingHeader,
        object.decode(allocator, @constCast("blob 130hello, world!"), .{}),
    );
    try std.testing.expectError(
        error.MissingHeader,
        object.decode(allocator, @constCast("hello, world!"), .{}),
    );
    try std.testing.expectError(
        error.MissingHeader,
        object.decode(allocator, @constCast("hello,world!"), .{}),
    );
    try std.testing.expectError(
        error.MissingHeader,
        object.decode(allocator, @constCast(""), .{}),
    );

    // malformed header error
    try std.testing.expectError(
        error.MalformedHeader,
        object.decode(allocator, @constCast("blob13\x00hello, world!"), .{}),
    );
    try std.testing.expectError(
        error.MalformedHeader,
        object.decode(allocator, @constCast("blob13\x00hello,world!"), .{}),
    );
}

/// The interface for an object.
pub fn Object(comptime Hasher: type) type {
    return union(enum(u4)) {
        blob: Blob(Hasher),
        commit: Commit(Hasher),
        tag: Tag(Hasher),
        tree: Tree(Hasher),

        const Self = @This();

        /// An object ID.
        /// Identifies the object content.
        pub const Id = struct {
            bytes: [Hasher.hash_size]u8 = [_]u8{0} ** Hasher.hash_size,

            pub fn deinit(id: *Id, allocator: Allocator) void {
                allocator.destroy(id);
            }

            /// Parses an object ID from an hexadecimal string.
            /// Deinitialize with `deinit`.
            pub fn fromHex(allocator: Allocator, hex: []const u8) !*Id {
                var id = try allocator.create(Id);
                errdefer allocator.destroy(id);

                try hash.parseHex(hex, &id.bytes);

                return id;
            }

            /// Formats this object ID as an hexadecimal string.
            /// Caller owns the returned memory.
            pub fn toHex(id: *Id, allocator: Allocator) ![]u8 {
                const res = try allocator.alloc(u8, Hasher.hash_size * 2);
                errdefer allocator.free(res);

                try hash.toHex(&id.bytes, res);

                return res;
            }

            /// Returns `true` if the object IDs are equal.
            pub fn eql(a: *const Id, b: *const Id) bool {
                return std.mem.eql(u8, &a.bytes, &b.bytes);
            }

            /// Formatting method for use with `std.io.Writer.print`.
            /// Outputs an hexadecimal string.
            pub fn format(id: *const Id, writer: *std.io.Writer) !void {
                try hash.formatAsHex(@constCast(id.bytes[0..]), writer);
            }
        };

        /// Calls `deinit` on the child object.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            switch (self.*) {
                inline else => |*s| s.*.deinit(allocator),
            }
        }

        /// Deserializes an object.
        /// Deinitialize with `deinit`.
        pub fn deserialize(allocator: Allocator, obj: *LooseObject(Hasher)) !Self {
            return switch (obj.object_type) {
                .commit => .{ .commit = try .deserialize(allocator, obj) },
                .tag => .{ .tag = try .deserialize(allocator, obj) },
                .tree => .{ .tree = try .deserialize(allocator, obj) },
                else => .{ .blob = try Blob(Hasher).deserialize(allocator, obj) },
            };
        }

        /// Serializes the object.
        /// Caller owns the returned memory.
        pub fn serialize(self: *const Self, allocator: Allocator) !LooseObject(Hasher) {
            switch (self.*) {
                inline else => |*s| return s.*.serialize(allocator),
            }
        }

        /// Formatting method for use with `std.io.Writer.print`.
        pub fn format(self: *const Self, writer: *std.io.Writer) !void {
            switch (self.*) {
                inline else => |*s| try s.format(writer),
            }
        }
    };
}

test "object id" {
    const allocator = std.testing.allocator;

    const Oid = Object(hash.Sha1).Id;

    var empty_oid: Oid = undefined;

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    var test_oid: Oid = .{ .bytes = [_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    } };

    const copy_oid = try allocator.dupe(u8, &test_oid.bytes);
    defer allocator.free(copy_oid);

    var test_copy_oid: Oid = .{ .bytes = copy_oid[0..hash.Sha1.hash_size].* };

    try std.testing.expect(!empty_oid.eql(&test_oid));
    try std.testing.expect(test_oid.eql(&test_copy_oid));

    var buf: [hash.Sha1.hash_size * 2]u8 = undefined;
    var w: std.io.Writer = .fixed(&buf);

    try w.print("{f}", .{test_oid});
    try std.testing.expectEqualStrings(test_chars, w.buffered());
}

test "blob via object interface" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, Git blob!";

    var blob_obj: Blob(hash.Sha1) = .{ .content = try allocator.dupe(u8, test_data) };

    var obj = blob_obj.interface();
    defer obj.deinit(allocator);

    try std.testing.expectEqualStrings("blob", @tagName(obj));

    var serialized = try obj.serialize(allocator);
    defer serialized.deinit(allocator);

    try std.testing.expect(serialized.object_type == .blob);

    var deserialized = try Object(hash.Sha1).deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqualSlices(u8, blob_obj.content, deserialized.blob.content);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "tree via object interface" {
    const allocator = std.testing.allocator;

    const test_data =
        \\100644 blob 0123456789abcdef0123456789abcdef01234567 README.md
        \\
    ;

    var tree_obj: Tree(hash.Sha1) = .{};
    _ = try tree_obj.addEntry(
        allocator,
        .blob,
        try .fromHex(allocator, "0123456789abcdef0123456789abcdef01234567"),
        "README.md",
    );

    var obj = tree_obj.interface();
    defer obj.deinit(allocator);

    try std.testing.expectEqualStrings("tree", @tagName(obj));

    var serialized = try obj.serialize(allocator);
    defer serialized.deinit(allocator);

    try std.testing.expect(serialized.object_type == .tree);

    var deserialized = try Object(hash.Sha1).deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(1, deserialized.tree.entries.items.len);
    try std.testing.expect(deserialized.tree.entries.items[0].entry_type == .blob);
    try std.testing.expect(std.mem.eql(u8, deserialized.tree.entries.items[0].name, "README.md"));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "commit via object interface" {
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

    var commit_obj: Commit(hash.Sha1) = .{
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
    try commit_obj.addParent(allocator, try .fromHex(allocator, "fedcba0987654321fedcba0987654321fedcba09"));
    try commit_obj.addParent(allocator, try .fromHex(allocator, "ba0987654321fedcba0987654321fedcba09fedc"));

    var obj = commit_obj.interface();
    defer obj.deinit(allocator);

    try std.testing.expectEqualStrings("commit", @tagName(obj));

    var serialized = try obj.serialize(allocator);
    defer serialized.deinit(allocator);

    try std.testing.expect(serialized.object_type == .commit);

    var deserialized = try Object(hash.Sha1).deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(commit_obj.tree.eql(deserialized.commit.tree));
    try std.testing.expectEqual(commit_obj.parents.items.len, deserialized.commit.parents.items.len);
    try std.testing.expect(commit_obj.author.eql(&deserialized.commit.author));
    try std.testing.expect(commit_obj.committer.eql(&deserialized.commit.committer));
    try std.testing.expectEqualStrings(commit_obj.message, deserialized.commit.message);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

test "tag via object interface" {
    const allocator = std.testing.allocator;

    const test_data =
        \\object 1234567890abcdef1234567890abcdef12345678
        \\type commit
        \\tag test-tag
        \\tagger Test Author <author@example.com> 1640995200 +0200
        \\
        \\Test tag message
    ;

    var tag_obj: Tag(hash.Sha1) = .{
        .object_id = try .fromHex(allocator, "1234567890abcdef1234567890abcdef12345678"),
        .object_type = .commit,
        .tagger = .{
            .identity = .{
                .name = try allocator.dupe(u8, "Test Author"),
                .email = try allocator.dupe(u8, "author@example.com"),
            },
            .time = .{ .seconds_from_epoch = 1640995200, .tz_offset_minutes = 120 },
        },
        .name = try allocator.dupe(u8, "test-tag"),
        .message = try allocator.dupe(u8, "Test tag message"),
    };

    var obj = tag_obj.interface();
    defer obj.deinit(allocator);

    try std.testing.expectEqualStrings("tag", @tagName(obj));

    var serialized = try obj.serialize(allocator);
    defer serialized.deinit(allocator);

    try std.testing.expect(serialized.object_type == .tag);

    var deserialized = try Object(hash.Sha1).deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expect(tag_obj.object_id.eql(deserialized.tag.object_id));
    try std.testing.expectEqual(tag_obj.object_type, deserialized.tag.object_type);
    try std.testing.expect(tag_obj.tagger.eql(&deserialized.tag.tagger));
    try std.testing.expectEqualStrings(tag_obj.name, deserialized.tag.name);
    try std.testing.expectEqualStrings(tag_obj.message, deserialized.tag.message);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{deserialized});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
