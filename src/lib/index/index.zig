// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const helpers = @import("../helpers.zig");

const index_entry = @import("index_entry.zig");
const IndexExtension = @import("index_extension.zig").Extension;

const header_size = 12;
const INDEX_SIGNATURE: u32 = std.mem.readInt(u32, "DIRC", .big);

pub const IndexSha1 = Index(helpers.hash.Sha1);
pub const IndexSha256 = Index(helpers.hash.Sha256);

/// Returns an index that uses the specified hasher function.
/// See [gitformat-index](https://github.com/git/git/blob/master/Documentation/gitformat-index.adoc).
pub fn Index(comptime Hasher: type) type {
    return struct {
        const Self = @This();
        const hash_size = Hasher.hash_size;
        pub const Entry = index_entry.Entry(Hasher.hash_size);

        // bit layout:
        //  0                   1                   2                   3
        //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | signature                                                     |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | version number                                                |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | number of index entries                                       |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | entries                                                       |
        //  |                             ....                              |
        //  |                                                               |
        //  +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
        //  : extensions                                                    :
        //  :                             ....                              :
        //  :                                                               :
        //  +=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
        //  | hash checksum                                                 |
        //  |                                                               |
        //  :                             ....                              :
        //  |                                                               |
        //  |                                                               |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

        signature: u32,
        version: u32,
        entries: std.ArrayList(Entry),
        extensions: std.ArrayList(IndexExtension),
        checksum: [hash_size]u8,
        // TODO: sort entries in ascending order on the name field,
        // interpreted as a string of unsigned bytes
        // (i.e. memcmp() order, no localization, no special casing of directory separator '/').
        // Entries with the same name are sorted by their stage field.
        // NB. exclude SplitIndexExtension enties at start (sort only remaining ones)

        /// Frees referenced resources.
        pub fn deinit(self: *const Self) void {
            deinitEntries(self.entries);
            deinitExtensions(self.extensions);
        }

        inline fn deinitEntries(entries: std.ArrayList(Entry)) void {
            for (entries.items) |*entry| {
                entry.deinit(entries.allocator); // XXX: use this approach for objects?
            }
            entries.deinit();
        }

        inline fn deinitExtensions(extensions: std.ArrayList(IndexExtension)) void {
            for (extensions.items) |*ext| {
                ext.deinit(extensions.allocator);
            }
            extensions.deinit();
        }

        /// Parses an index from `data`.
        /// Free with `deinit`.
        pub fn parse(allocator: Allocator, data: []u8) !Self {
            if (data.len < header_size) {
                return error.UnexpectedEndOfFile;
            }

            var hasher = Hasher.init();

            // header
            const signature = std.mem.readInt(u32, data[0..4], .big);
            if (signature != INDEX_SIGNATURE) {
                return error.InvalidSignature;
            }

            const version = std.mem.readInt(u32, data[4..8], .big);
            if (version < 2 or version > 4) {
                return error.UnsupportedVersion;
            }

            const entry_count = std.mem.readInt(u32, data[8..header_size], .big);

            var pos: usize = header_size;
            hasher.update(data[0..pos]);

            // entries
            var entries = try std.ArrayList(Entry).initCapacity(allocator, entry_count);
            errdefer deinitEntries(entries);

            for (0..entry_count) |_| {
                const parsed = try Entry.parse(allocator, data[pos..], version);
                try entries.append(parsed.entry);
                hasher.update(data[pos..(pos + parsed.len)]);
                pos += parsed.len;
            }

            // extensions
            const extensions = std.ArrayList(IndexExtension).init(allocator);
            errdefer deinitExtensions(extensions);

            // TODO: parse extensions

            // checksum
            if (pos + hash_size != data.len) {
                return error.InvalidFormat;
            }
            var checksum: [hash_size]u8 = undefined;
            @memcpy(&checksum, data[pos..(pos + hash_size)]);

            // verify checksum
            var calculated_checksum: [hash_size]u8 = undefined;
            hasher.final(&calculated_checksum);

            if (!std.mem.eql(u8, &checksum, &calculated_checksum)) {
                return error.InvalidChecksum;
            }

            return .{
                .signature = signature,
                .version = version,
                .entries = entries,
                .extensions = extensions,
                .checksum = checksum,
            };
        }

        /// Writes the index to `buffer`.
        pub fn writeTo(self: *const Self, buffer: *std.ArrayList(u8)) !void {
            // header
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.signature)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.version)));
            const entry_count: u32 = @intCast(self.entries.items.len);
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, entry_count)));

            // entries
            for (self.entries.items) |*entry| {
                try entry.writeTo(buffer, self.version);
            }

            // extensions
            for (self.extensions.items) |*ext| {
                try ext.writeTo(buffer);
            }

            // checksum
            var checksum: [hash_size]u8 = undefined;
            Hasher.hashData(buffer.items, &checksum);
            try buffer.appendSlice(&checksum);
        }
    };
}

test "index" {
    const allocator = std.testing.allocator;

    const bytes: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'C',
        0,    0,    0,    0x02,
        0,    0,    0,    0x01,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05,
        0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4,
        0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8,
        0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c,
        0x80, 0x08, 't',  'e',
        's',  't',  '.',  't',
        'x',  't',  0,    0,
        0x63, 0x52, 0xc0, 0x83,
        0x9c, 0x74, 0xa9, 0x70,
        0x89, 0xc0, 0x87, 0x61,
        0xe4, 0x2b, 0x18, 0xd,
        0x62, 0xa9, 0xda, 0xd6,
    });

    var expected: IndexSha1 = .{
        .signature = INDEX_SIGNATURE,
        .version = 2,
        .entries = std.ArrayList(IndexSha1.Entry).init(allocator),
        .extensions = std.ArrayList(IndexExtension).init(allocator),
        .checksum = [_]u8{
            0x63, 0x52, 0xc0, 0x83, 0x9c, 0x74, 0xa9, 0x70, 0x89, 0xc0,
            0x87, 0x61, 0xe4, 0x2b, 0x18, 0xd,  0x62, 0xa9, 0xda, 0xd6,
        },
    };
    defer expected.deinit();

    try expected.entries.append(.{
        .ctime = 0x1390fe681daeebc6,
        .mtime = 0x1390fe681daeebc6,
        .device = 2053,
        .inode = 14_954_102,
        .file_mode = .regular_file,
        .user_id = 1000,
        .group_id = 1000,
        .file_size = 2,
        .hash = [_]u8{
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
            0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
        },
        .flags = index_entry.Flags{ .assume_valid = true, .name_length = 8 },
        .path_name = try allocator.dupeZ(u8, "test.txt"),
    });

    const parsed = try IndexSha1.parse(allocator, bytes);
    defer parsed.deinit();

    try std.testing.expect(parsed.signature == expected.signature);
    try std.testing.expect(parsed.version == expected.version);
    try std.testing.expect(parsed.entries.items.len == expected.entries.items.len);
    if (expected.entries.items.len > 0) {
        for (parsed.entries.items, expected.entries.items) |*p, *e| {
            try std.testing.expect(std.mem.eql(u8, p.path_name, e.path_name));
        }
    }
    try std.testing.expect(parsed.extensions.items.len == expected.extensions.items.len);
    if (expected.extensions.items.len > 0) {
        // TODO: test extensions?
    }
    try std.testing.expect(std.mem.eql(u8, &parsed.checksum, &expected.checksum));

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try parsed.writeTo(&buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

test "index errors" {
    const allocator = std.testing.allocator;

    const too_short1: []u8 = @constCast(&[_]u8{
        'D', 'I', 'R', 'C',
        0,   0,   0,   0x02,
        0,   0,   0,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexSha1.parse(allocator, too_short1));

    const too_short2: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'C',
        0,    0,    0,    0x02,
        0,    0,    0,    0x01,
        0xc7, 0x72, 0xd3, 0xf3,
        0xe0, 0x92, 0x58, 0x3c,
        0x59, 0x5f, 0xc7, 0xff,
        0x84, 0xca, 0x78, 0xc8,
        0xe5, 0xe6, 0x71,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, IndexSha1.parse(allocator, too_short2));

    const invalid_sign: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'D',
        0,    0,    0,    0x02,
        0,    0,    0,    0x01,
        0xc7, 0x72, 0xd3, 0xf3,
        0xe0, 0x92, 0x58, 0x3c,
        0x59, 0x5f, 0xc7, 0xff,
        0x84, 0xca, 0x78, 0xc8,
        0xe5, 0xe6, 0x71, 0x15,
    });
    try std.testing.expectError(error.InvalidSignature, IndexSha1.parse(allocator, invalid_sign));

    const unsupported_version: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'C',
        0,    0,    0,    0x01,
        0,    0,    0,    0x01,
        0xc7, 0x72, 0xd3, 0xf3,
        0xe0, 0x92, 0x58, 0x3c,
        0x59, 0x5f, 0xc7, 0xff,
        0x84, 0xca, 0x78, 0xc8,
        0xe5, 0xe6, 0x71, 0x15,
    });
    try std.testing.expectError(error.UnsupportedVersion, IndexSha1.parse(allocator, unsupported_version));

    const invalid_format: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'C',
        0,    0,    0,    0x02,
        0,    0,    0,    0x01,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05,
        0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4,
        0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8,
        0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c,
        0x80, 0x08, 't',  'e',
        's',  't',  '.',  't',
        'x',  't',  0,    0,
        0xc7, 0x72, 0xd3, 0xf3,
        0xe0, 0x92, 0x58, 0x3c,
        0x59, 0x5f, 0xc7, 0xff,
        0x84, 0xca, 0x78, 0xc8,
    });
    try std.testing.expectError(error.InvalidFormat, IndexSha1.parse(allocator, invalid_format));

    const invalid_checksum: []u8 = @constCast(&[_]u8{
        'D',  'I',  'R',  'C',
        0,    0,    0,    0x02,
        0,    0,    0,    0x01,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6,
        0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05,
        0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4,
        0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8,
        0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98,
        0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c,
        0x80, 0x08, 't',  'e',
        's',  't',  '.',  't',
        'x',  't',  0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
        0,    0,    0,    0,
    });
    try std.testing.expectError(error.InvalidChecksum, IndexSha1.parse(allocator, invalid_checksum));
}
