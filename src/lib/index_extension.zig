// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

const Hasher = @import("hash.zig").Hasher;
const ObjectId = @import("core/ObjectId.zig");

const hash_size = @import("core/ObjectId.zig").hash_size;

/// Type of an extensions, used for signature bytes.
pub const ExtensionType = enum(u32) {
    split_index = std.mem.readInt(u32, "link", .big),
    sparse_dir = std.mem.readInt(u32, "sdir", .big),
    _, // for all other not understood extensions

    /// Tracks full directory structure in the cache tree.
    //    cache_tree = std.mem.readInt(u32, "TREE", .big),

    /// Conflict resolution (uses the "stage" bits).
    //    resolve_undo = std.mem.readInt(u32, "REUC", .big),

    /// Saves the untracked file list.
    //    untracked_cache = std.mem.readInt(u32, "UNTR", .big),

    /// Tracks files from the core.fsmonitor hook.
    //    fsmonitor = std.mem.readInt(u32, "FSMN", .big),

    /// Locate the beginning of the extensions  in the index (i.e. the end of entries).
    //    end_of_entries = std.mem.readInt(u32, "EOIE", .big),

    /// Enables multi-threaded conversion from on-disk to in-memory index formats.
    //    index_entry_offset_table = std.mem.readInt(u32, "IEOT", .big),

    pub fn fromBytes(bytes: [4]u8) ExtensionType {
        return @enumFromInt(std.mem.readInt(u32, &bytes, .big));
    }

    pub fn toBytes(self: ExtensionType) [4]u8 {
        const value = @intFromEnum(self);
        return std.mem.toBytes(std.mem.nativeToBig(u32, value));
    }

    pub fn isOptional(self: ExtensionType) bool {
        const bytes = self.toBytes();
        return bytes[0] >= 'A' and bytes[0] <= 'Z';
    }
};

/// The interface for an index extension.
pub const IndexExtension = union(enum(u32)) {
    // bit layout:
    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | signature                                                     |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | size                                                          |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | data                                                          |
    //  |                             ....                              |
    //  |                                                               |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    split_index: SplitIndexExtension = @intFromEnum(ExtensionType.split_index),
    sparse_dir: SparseDirExtension = @intFromEnum(ExtensionType.sparse_dir),
    unknown: UnknownExtension,

    /// Frees referenced resources.
    pub fn deinit(self: *const IndexExtension, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*s| s.*.deinit(allocator),
        }
    }

    /// Writes this index extension to `buffer`.
    pub fn writeTo(self: *const IndexExtension, buffer: *std.ArrayList(u8)) !void {
        // TODO: write common header? e.g. ext_type
        switch (self.*) {
            inline else => |*s| try s.*.writeTo(buffer),
        }
    }

    /// Parses an index extension from `data`.
    /// Returns a tuple with the parsed extension and the length in bytes.
    /// Free returned extension with `deinit`.
    pub fn parse(allocator: Allocator, data: []u8) !struct {
        extension: IndexExtension,
        len: usize,
    } {
        if (data.len < 8) {
            return error.UnexpectedEndOfFile;
        }

        const ext_type = ExtensionType.fromBytes(data[0..4].*);
        const ext_size = std.mem.readInt(u32, data[4..8], .big);

        const ext_len = 8 + ext_size;
        if (data.len < ext_len) {
            return error.UnexpectedEndOfFile;
        }

        const ext_data = data[8..ext_len];

        const instance = switch (ext_type) {
            .split_index => (try SplitIndexExtension.parse(allocator, ext_type, ext_data)).interface(),
            .sparse_dir => (try SparseDirExtension.parse(allocator, ext_type, ext_data)).interface(),
            _ => blk: {
                if (!ext_type.isOptional()) {
                    std.log.debug("Found unknown extension {s}", .{ext_type.toBytes()});
                    return error.UnknownExtension;
                }
                const res = try UnknownExtension.parse(allocator, ext_type, ext_data);
                break :blk res.interface();
            },
        };
        return .{
            .extension = instance,
            .len = ext_len,
        };
    }
};

/// An extension that is not understood.
pub const UnknownExtension = struct {
    ext_type: ExtensionType,
    data: []u8,

    /// Returns an instance of the extension interface.
    pub inline fn interface(self: UnknownExtension) IndexExtension {
        return .{ .unknown = self };
    }

    /// Frees referenced resources.
    pub fn deinit(self: *const UnknownExtension, allocator: Allocator) void {
        allocator.free(self.data);
    }

    /// Writes the index extension to `buffer`.
    pub fn writeTo(self: *const UnknownExtension, buffer: *std.ArrayList(u8)) !void {
        const type_bytes = self.ext_type.toBytes();
        try buffer.appendSlice(&type_bytes);
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(self.data.len))));
        try buffer.appendSlice(self.data);
    }

    /// Parses an index extension from `data`.
    pub fn parse(allocator: Allocator, ext_type: ExtensionType, data: []u8) !UnknownExtension {
        return .{
            .ext_type = ext_type,
            .data = try allocator.dupe(u8, data),
        };
    }
};

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

    var parsed = try IndexExtension.parse(allocator, bytes);
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
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexExtension.parse(allocator, too_short_v1));

    const too_short_v2: []u8 = @constCast(&[_]u8{
        'S', 'I', 'G', 'N',
        0,   0,   0,   17,
        'u', 'n', 'k', 'n',
        'o', 'w', 'n', ' ',
        'e', 'x', 't', 'e',
        'n', 's', 'i', 'o',
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexExtension.parse(allocator, too_short_v2));

    const unk: []u8 = @constCast(&[_]u8{
        't', 'e', 's', 't',
        0,   0,   0,   4,
        't', 'e', 's', 't',
    });
    try std.testing.expectError(error.UnknownExtension, IndexExtension.parse(allocator, unk));
}

/// Stores the majority of entries in a separate file,
/// named "sharedindex.<hash>" and located inside the Git directory.
/// This extension records the changes to be made on top of that file to produce the final index.
pub const SplitIndexExtension = struct {
    // bit layout:
    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | SHA-1 hash of the shared index file                           |
    //  |                                                               |
    //  |                                                               |
    //  |                                                               |
    //  |                                                               |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | ewah-encoded delete bitmap...                                 :
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  | ewah-encoded replace bitmap...                                |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //
    // If all bits of the hash are zero, the index does not require a shared index file.
    //
    // Each bit in the delete bitmap represents an entry in the shared index.
    // If a bit is set, its corresponding entry in the shared index will be removed from the final index.
    //
    // Each bit in the replace bitmap represents an entry in the shared index.
    // If a bit is set, its corresponding entry in the shared index will be replaced with an entry in this index file.
    // All replaced entries are stored in sorted order in this index.
    // Replaced entries may have empty path names to save space.
    // Note that, after the replaced entries, there may be others that will be added to the final index.
    // These additional entries are sorted according to the usual rules for entries in the index.

    shared_id: ObjectId,
    delete_bitmap: []u8,
    replace_bitmap: []u8,

    /// Returns an instance of the extension interface.
    pub inline fn interface(self: SplitIndexExtension) IndexExtension {
        return .{ .split_index = self };
    }

    pub fn init() SplitIndexExtension {
        return .{
            .shared_id = ObjectId.init(.{}),
            .delete_bitmap = &.{},
            .replace_bitmap = &.{},
        };
    }

    /// Frees referenced resources.
    pub fn deinit(self: *const SplitIndexExtension, allocator: Allocator) void {
        if (self.delete_bitmap.len > 0) {
            allocator.free(self.delete_bitmap);
        }
        if (self.replace_bitmap.len > 0) {
            allocator.free(self.replace_bitmap);
        }
    }

    /// Writes the index extension to `buffer`.
    pub fn writeTo(self: *const SplitIndexExtension, buffer: *std.ArrayList(u8)) !void {
        const type_bytes = ExtensionType.split_index.toBytes();
        try buffer.appendSlice(&type_bytes);

        const len = hash_size + self.delete_bitmap.len + self.replace_bitmap.len;
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(len))));

        try buffer.appendSlice(&self.shared_id.hash);
        try buffer.appendSlice(self.delete_bitmap);
        try buffer.appendSlice(self.replace_bitmap);
    }

    /// Parses an index extension from `data`.
    pub fn parse(allocator: Allocator, _: ExtensionType, data: []u8) !SplitIndexExtension {
        if (data.len < hash_size) {
            return error.InvalidFormat;
        }

        var shared_id = ObjectId.init(.{});
        @memcpy(&shared_id.hash, data[0..hash_size]);

        var pos: usize = hash_size;

        const delete_bitmap_len = try parseEwahBitmapLength(data[pos..]);
        if (pos + delete_bitmap_len > data.len) {
            return error.UnexpectedEndOfFile;
        }

        const delete_bitmap = try allocator.dupe(u8, data[pos..(pos + delete_bitmap_len)]);

        pos += delete_bitmap_len;
        if (pos >= data.len) {
            return error.InvalidFormat;
        }

        const replace_bitmap_len = try parseEwahBitmapLength(data[pos..]);

        if (pos + replace_bitmap_len > data.len) {
            return error.UnexpectedEndOfFile;
        }

        const replace_bitmap = try allocator.dupe(u8, data[pos..(pos + replace_bitmap_len)]);

        return .{
            .shared_id = shared_id,
            .delete_bitmap = delete_bitmap,
            .replace_bitmap = replace_bitmap,
        };
    }
};

test "split index extension" {
    const allocator = std.testing.allocator;

    const expected_shared_id = try ObjectId.parseHexString("0123456789abcdeffedcba98765432100f1e2d3c");

    // use a minimal EWAH bitmap: header (8 bytes) with zeros
    const bytes: []u8 = @constCast(&[_]u8{
        'l',  'i',  'n',  'k',
        0,    0,    0,    36,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c,
        0, 0, 0, 0, // delete bitmap header: compressed words
        0, 0, 0, 0, // delete bitmap header: literal words
        0, 0, 0, 0, // replace bitmap header: compressed words
        0, 0, 0, 0, // replace bitmap header: literal words
    });

    var parsed = try IndexExtension.parse(allocator, bytes);
    defer parsed.extension.deinit(allocator);

    try std.testing.expectEqualStrings(@tagName(parsed.extension), @tagName(ExtensionType.split_index));
    try std.testing.expect(parsed.len == bytes.len);

    const split_index = parsed.extension.split_index;
    try std.testing.expect(split_index.shared_id.eql(&expected_shared_id));
    try std.testing.expect(split_index.delete_bitmap.len == 8);
    try std.testing.expect(split_index.replace_bitmap.len == 8);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try parsed.extension.writeTo(&buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

test "split index errors" {
    const allocator = std.testing.allocator;

    const too_short_v1: []u8 = @constCast(&[_]u8{
        'l',  'i',  'n',  'k',
        0,    0,    0,    36,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexExtension.parse(allocator, too_short_v1));

    const too_short_v2: []u8 = @constCast(&[_]u8{
        'l',  'i',  'n',  'k',
        0,    0,    0,    36,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexExtension.parse(allocator, too_short_v2));
}

/// Indicates that the index contains sparse directory entries (pointing to a tree instead of the list of file paths).
/// This struct has no fields because it is only a marker.
pub const SparseDirExtension = struct {
    /// Returns an instance of the extension interface.
    pub inline fn interface(self: SparseDirExtension) IndexExtension {
        return .{ .sparse_dir = self };
    }

    /// Frees referenced resources.
    pub fn deinit(_: *const SparseDirExtension, _: Allocator) void {}

    /// Writes the index extension to `buffer`.
    pub fn writeTo(_: *const SparseDirExtension, buffer: *std.ArrayList(u8)) !void {
        const type_bytes = ExtensionType.sparse_dir.toBytes();
        try buffer.appendSlice(&type_bytes);
        try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
    }

    /// Parses an index extension from `data`.
    pub fn parse(_: Allocator, _: ExtensionType, _: []u8) !SparseDirExtension {
        return .{};
    }
};

test "sparse directory extension" {
    const allocator = std.testing.allocator;

    const bytes: []u8 = @constCast(&[_]u8{
        's', 'd', 'i', 'r',
        0,   0,   0,   0,
    });

    var parsed = try IndexExtension.parse(allocator, bytes);
    defer parsed.extension.deinit(allocator);

    try std.testing.expectEqualStrings(@tagName(parsed.extension), @tagName(ExtensionType.sparse_dir));
    try std.testing.expect(parsed.len == bytes.len);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try parsed.extension.writeTo(&buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

/// Parse the length of an EWAH-encoded bitmap.
/// This is a simplified parser that reads the header to determine size.
fn parseEwahBitmapLength(data: []const u8) !usize {
    if (data.len < 8) {
        return error.UnexpectedEndOfFile;
    }

    // EWAH format starts with a header containing:
    // - number of 64-bit words of compressed bitmap (32 bits)
    // - number of 64-bit literal words (32 bits)
    const compressed_words = std.mem.readInt(u32, data[0..4], .little);
    const literal_words = std.mem.readInt(u32, data[4..8], .little);

    const total_size = 8 + (@as(usize, compressed_words) * 8) + (@as(usize, literal_words) * 8);

    if (total_size > data.len) {
        return error.UnexpectedEndOfFile;
    }

    return total_size;
}
