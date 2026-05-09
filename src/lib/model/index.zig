// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("util/hash.zig");
const FileMode = @import("util/mode.zig").FileMode;

const header_size = 12;
const INDEX_SIGNATURE: u32 = std.mem.readInt(u32, "DIRC", .big);

/// Returns an index that uses the specified hasher function.
/// See [gitformat-index](https://github.com/git/git/blob/master/Documentation/gitformat-index.adoc).
pub fn Index(comptime Hasher: type) type {
    return struct {
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
        extensions: std.ArrayList(Extension),
        checksum: [hash_size]u8,

        const Self = @This();
        const hash_size = Hasher.hash_size;

        pub const Entry = IndexEntry(Hasher.hash_size);
        pub const Extension = IndexExtension;
        pub const MergeStage = IndexMergeStage;
        pub const Flags = IndexFlags;
        pub const ExtendedFlags = ExtendedIndexFlags;

        /// Initializes an empty index.
        /// Deinitialize with `deinit`.
        pub fn init() Self {
            return .{
                .signature = INDEX_SIGNATURE,
                .version = 2,
                .entries = .empty,
                .extensions = .empty,
                .checksum = std.mem.zeroes([hash_size]u8),
            };
        }

        /// Frees referenced resources.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            deinitEntries(allocator, &self.entries);
            deinitExtensions(allocator, &self.extensions);
        }

        fn deinitEntries(allocator: Allocator, entries: *std.ArrayList(Entry)) void {
            for (entries.items) |*e| {
                Entry.deinit(e, allocator);
            }
            entries.deinit(allocator);
        }

        fn deinitExtensions(allocator: Allocator, extensions: *std.ArrayList(Extension)) void {
            for (extensions.items) |*e| {
                Extension.deinit(e, allocator);
            }
            extensions.deinit(allocator);
        }

        /// Parses an index from `data`.
        /// Deinitialize with `deinit`.
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
            std.log.debug("Index has version {d}", .{version});

            const entry_count = std.mem.readInt(u32, data[8..header_size], .big);
            std.log.debug("Index contains {d} entrie(s)", .{entry_count});

            var pos: usize = header_size;
            hasher.update(data[0..pos]);

            // entries
            var entries = try std.ArrayList(Entry).initCapacity(allocator, entry_count);
            errdefer deinitEntries(allocator, &entries);

            for (0..entry_count) |_| {
                const parsed = try Entry.parse(allocator, data[pos..], version);
                try entries.append(allocator, parsed.entry);
                hasher.update(data[pos..(pos + parsed.len)]);
                pos += parsed.len;
            }

            // extensions
            var extensions: std.ArrayList(Extension) = .empty;
            errdefer deinitExtensions(allocator, &extensions);

            if (pos < (data.len - hash_size)) {
                const parsed = try Extension.parse(allocator, data[pos..]);
                try extensions.append(allocator, parsed.extension);
                hasher.update(data[pos..(pos + parsed.len)]);
                pos += parsed.len;

                switch (parsed.extension) {
                    .sparse_directory => {
                        std.log.debug("Found extension 'sparse directory'", .{});
                    },
                    .unknown => |unk| {
                        std.log.debug("Found unknown extension '{s}' of size {d}", .{ unk.signature.toBytes(), unk.data.len });
                    },
                }
            }

            // TODO: exclude SplitIndexExtension entries at start (sort only remaining ones)
            std.mem.sort(Entry, entries.items, {}, Entry.lessThan);

            // checksum
            if ((pos + hash_size) != data.len) {
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
        pub fn writeTo(self: *const Self, allocator: Allocator, buffer: *std.ArrayList(u8)) !void {
            // header
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.signature)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.version)));
            const entry_count: u32 = @intCast(self.entries.items.len);
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, entry_count)));

            // entries
            // TODO: exclude SplitIndexExtension entries at start (sort only remaining ones)
            std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);
            for (self.entries.items) |*entry| {
                try entry.writeTo(allocator, buffer, self.version);
            }

            // extensions
            for (self.extensions.items) |*ext| {
                try ext.writeTo(allocator, buffer);
            }

            // checksum
            var checksum: [hash_size]u8 = undefined;
            Hasher.hashData(buffer.items, &checksum);
            try buffer.appendSlice(allocator, &checksum);
        }

        /// Returns true if `path` is a prefix of an entry in the index.
        pub fn containsPrefix(self: *const Self, path: [:0]const u8, unmerged: bool) bool {
            for (self.entries.items) |entry| {
                if (std.mem.startsWith(u8, entry.path, path)) {
                    return !unmerged or entry.isUnmerged();
                }
            }
            return false;
        }

        /// Returns true if the index contains an entry matching `path`.
        /// Uses only exact match of strings and does not check for
        /// - unmerged files;
        /// - directory paths ending with "/".
        pub fn contains(self: *const Self, path: [:0]const u8) bool {
            return self.containsPrefix(path, false);
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
        's',  'd',  'i',  'r',
        0,    0,    0,    0,
        0x13, 0x85, 0xdb, 0x8f,
        0x48, 0x2c, 0x19, 0xc,
        0x14, 0x10, 0x52, 0xb2,
        0x64, 0x7c, 0x41, 0x25,
        0x3a, 0x5f, 0x88, 0x34,
    });

    var expected: Index(hash.Sha1) = .{
        .signature = INDEX_SIGNATURE,
        .version = 2,
        .entries = .empty,
        .extensions = .empty,
        .checksum = [_]u8{
            0x13, 0x85, 0xdb, 0x8f, 0x48, 0x2c, 0x19, 0xc,  0x14, 0x10,
            0x52, 0xb2, 0x64, 0x7c, 0x41, 0x25, 0x3a, 0x5f, 0x88, 0x34,
        },
    };
    defer expected.deinit(allocator);

    try expected.entries.append(allocator, .{
        .ctime = 0x1390fe681daeebc6,
        .mtime = 0x1390fe681daeebc6,
        .device = 2053,
        .inode = 14_954_102,
        .file_mode = .{
            .type = .regular_file,
            .permissions = .{
                .user = .{ .read = true, .write = true },
                .group = .{ .read = true },
                .others = .{ .read = true },
            },
        },
        .user_id = 1000,
        .group_id = 1000,
        .file_size = 2,
        .hash = [_]u8{
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
            0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
        },
        .flags = .{ .assume_valid = true, .name_length = 8 },
        .path = try allocator.dupeZ(u8, "test.txt"),
    });

    const sparse_dir: SparseDirectory = .{};
    try expected.extensions.append(allocator, sparse_dir.interface());

    var parsed = try Index(hash.Sha1).parse(allocator, bytes);
    defer parsed.deinit(allocator);

    try std.testing.expect(parsed.signature == expected.signature);
    try std.testing.expect(parsed.version == expected.version);
    try std.testing.expect(parsed.entries.items.len == expected.entries.items.len);
    if (expected.entries.items.len > 0) {
        for (parsed.entries.items, expected.entries.items) |*p, *e| {
            try std.testing.expect(std.mem.eql(u8, p.path, e.path));
        }
    }
    try std.testing.expect(parsed.extensions.items.len == expected.extensions.items.len);
    if (expected.extensions.items.len > 0) {
        for (parsed.extensions.items, expected.extensions.items) |*p, *e| {
            try std.testing.expect(std.mem.eql(u8, @tagName(p.*), @tagName(e.*)));
        }
    }
    try std.testing.expect(std.mem.eql(u8, &parsed.checksum, &expected.checksum));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try parsed.writeTo(allocator, &buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

test "index errors" {
    const allocator = std.testing.allocator;

    const too_short1: []u8 = @constCast(&[_]u8{
        'D', 'I', 'R', 'C',
        0,   0,   0,   0x02,
        0,   0,   0,
    });
    try std.testing.expectError(error.UnexpectedEndOfFile, Index(hash.Sha1).parse(allocator, too_short1));

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
    try std.testing.expectError(error.UnexpectedEndOfFile, Index(hash.Sha1).parse(allocator, too_short2));

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
    try std.testing.expectError(error.InvalidSignature, Index(hash.Sha1).parse(allocator, invalid_sign));

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
    try std.testing.expectError(error.UnsupportedVersion, Index(hash.Sha1).parse(allocator, unsupported_version));

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
    try std.testing.expectError(error.InvalidFormat, Index(hash.Sha1).parse(allocator, invalid_format));

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
    try std.testing.expectError(error.InvalidChecksum, Index(hash.Sha1).parse(allocator, invalid_checksum));

    const invalid_extension: []u8 = @constCast(&[_]u8{
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
        'S',  'I',  'G',  'N',
        0,    0,    0,    4,
        0xc7, 0x72, 0xd3, 0xf3,
        0xe0, 0x92, 0x58, 0x3c,
        0x59, 0x5f, 0xc7, 0xff,
        0x84, 0xca, 0x78, 0xc8,
    });
    try std.testing.expectError(error.InvalidFormat, Index(hash.Sha1).parse(allocator, invalid_extension));
}

/// Returns an index entry with the specified hash size in bytes.
fn IndexEntry(comptime hash_size: usize) type {
    return struct {
        // bit layout:
        //  0                   1                   2                   3
        //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | ctime seconds                                                 |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | ctime nanosecond fractions                                    |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | mtime seconds                                                 |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | mtime nanosecond fractions                                    |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | device                                                        |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | inode                                                         |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | 0                             | file mode                     |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | user ID                                                       |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | group ID                                                      |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | file size                                                     |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //  | hash                                                          |
        //  |                                                               |
        //  :                             ....                              :
        //  |                                                               |
        //  |                                                               |
        //  +-+-+-+-:-+-+-+-+-+-+-+-+-+-+-+-:=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
        //  | flags                         : extended flags (v3>)          :
        //  +-+-+-+-:-+-+-+-+-+-+-+-+-+-+-+-:=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+=+
        //  | path...                                                       |
        //  |                                                               |
        //  |                                         +-+-+-+-+-+-+-+-+-+-+-+
        //  |                                                :...null bytes |
        //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        //
        // Path name is a null-terminated string.
        // The entry ends with 1-8 null bytes as necessary to pad the entry to
        // a multiple of 8 bytes while keeping the path name null-terminated.

        ctime: u64,
        mtime: u64,
        device: u32,
        inode: u32,
        file_mode: FileMode,
        user_id: u32,
        group_id: u32,
        file_size: u32,
        hash: [hash_size]u8,
        flags: IndexFlags,
        extended_flags: ?ExtendedIndexFlags = null, // requires flags.extended == true
        path: [:0]const u8,

        const Self = @This();

        /// Frees referenced resources.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.path);
        }

        /// Comparison function for use with `std.mem.sort`.
        /// Sort entries in ascending order on the name field, interpreted as a string of unsigned bytes
        /// (i.e. memcmp() order, no localization, no special casing of directory separator '/').
        /// Entries with the same name are sorted by their stage field.
        pub fn lessThan(_: void, lhs: Self, rhs: Self) bool {
            return switch (std.mem.order(u8, lhs.path, rhs.path)) {
                .eq => @intFromEnum(lhs.flags.stage) < @intFromEnum(rhs.flags.stage),
                .lt => true,
                .gt => false,
            };
        }

        /// Parses an index entry from `data` using index format `version`.
        /// Returns a tuple with the parsed entry and the length in bytes.
        /// Free result entry with `deinit`.
        pub fn parse(allocator: Allocator, data: []u8, version: u32) !struct {
            entry: Self,
            len: usize,
        } {
            if (data.len < 62) {
                return error.UnexpectedEndOfFile;
            }

            const ctime_sec = std.mem.readInt(u32, data[0..4], .big);
            const ctime_nsec = std.mem.readInt(u32, data[4..8], .big);
            const mtime_sec = std.mem.readInt(u32, data[8..12], .big);
            const mtime_nsec = std.mem.readInt(u32, data[12..16], .big);
            const flags: IndexFlags = .of(data[60..62].*);

            var extended_flags: ?ExtendedIndexFlags = null;
            if (version >= 3 and flags.extended) {
                if (data.len < 64) {
                    return error.UnexpectedEndOfFile;
                }
                extended_flags = .of(data[62..64].*);
            }

            var path_name_start: usize = 62;
            if (extended_flags) |_| {
                path_name_start = 64;
            }
            const path = try parsePathName(allocator, data[path_name_start..], flags.name_length);

            const path_name_end = path_name_start + path.len + 1; // +1 is for the null-terminator
            const pad_len = calcPaddingLen(version, path_name_end);

            const entry: Self = .{
                .ctime = @as(u64, ctime_sec) * std.time.ns_per_s + ctime_nsec,
                .mtime = @as(u64, mtime_sec) * std.time.ns_per_s + mtime_nsec,
                .device = std.mem.readInt(u32, data[16..20], .big),
                .inode = std.mem.readInt(u32, data[20..24], .big),
                .file_mode = FileMode.of(std.mem.readInt(u16, data[26..28], .big)),
                .user_id = std.mem.readInt(u32, data[28..32], .big),
                .group_id = std.mem.readInt(u32, data[32..36], .big),
                .file_size = std.mem.readInt(u32, data[36..40], .big),
                .hash = data[40..(40 + hash_size)].*,
                .flags = flags,
                .extended_flags = extended_flags,
                .path = path,
            };

            return .{
                .entry = entry,
                .len = path_name_end + pad_len,
            };
        }

        /// Writes the index entry to `buffer` using format `version`.
        pub fn writeTo(self: *const Self, allocator: Allocator, buffer: *std.ArrayList(u8), version: u32) !void {
            const start_pos = buffer.items.len;

            const ctime_sec: u32 = @intCast(@divFloor(self.ctime, std.time.ns_per_s));
            const ctime_nsec: u32 = @intCast(@mod(self.ctime, std.time.ns_per_s));
            const mtime_sec: u32 = @intCast(@divFloor(self.mtime, std.time.ns_per_s));
            const mtime_nsec: u32 = @intCast(@mod(self.mtime, std.time.ns_per_s));
            const file_mode = @as(u32, self.file_mode.toInt());

            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, ctime_sec)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, ctime_nsec)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, mtime_sec)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, mtime_nsec)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.device)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.inode)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, file_mode)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.user_id)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.group_id)));
            try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, self.file_size)));
            try buffer.appendSlice(allocator, &self.hash);

            try self.checkPathNameLen();
            try buffer.appendSlice(allocator, &self.flags.toBytes());

            if (version >= 3 and self.flags.extended) {
                if (self.extended_flags) |ext_flags| {
                    try buffer.appendSlice(allocator, &ext_flags.toBytes());
                }
            }

            try buffer.appendSlice(allocator, self.path);
            try buffer.append(allocator, 0); // null-terminator

            const pad_len = calcPaddingLen(version, buffer.items.len - start_pos);
            for (0..pad_len) |_| {
                try buffer.append(allocator, 0);
            }
        }

        /// Returns true if the entry is changed in comparison to the provided file stats.
        pub fn isChanged(self: *const Self, stat: std.Io.File.Stat) bool {
            if (self.extended_flags) |ext| {
                if (ext.intent_to_add and self.flags.extended) {
                    return true;
                }
            }

            // FIXME: check mode changes

            const ctime: i96 = @intCast(self.ctime);
            const mtime: i96 = @intCast(self.mtime);

            return self.file_size != stat.size or
                ctime != stat.ctime.nanoseconds or
                mtime != stat.mtime.nanoseconds;
        }

        /// Returns true if the entry has a merge stage.
        pub fn isUnmerged(self: *const Self) bool {
            return self.flags.stage != .none;
        }

        fn parsePathName(allocator: Allocator, data: []u8, name_length: u12) ![:0]const u8 {
            const name_len = if (name_length < 0xFFF) name_length else find_null: {
                var len: usize = 0;
                while (len < data.len and data[len] != 0) {
                    len += 1;
                }
                break :find_null len;
            };

            if (name_len >= data.len) return error.UnexpectedEndOfFile;

            return allocator.dupeZ(u8, data[0..name_len]);
        }

        fn checkPathNameLen(self: *const Self) !void {
            const maxU12 = std.math.maxInt(u12);
            const path_name_len = if (self.path.len > maxU12) maxU12 else self.path.len;
            if (self.flags.name_length != path_name_len) {
                return error.UnexpectedPathNameLength;
            }
        }
    };
}

fn calcPaddingLen(version: u32, entry_len: usize) usize {
    if (version != 4) {
        const rem = entry_len % 8;
        if (rem > 0) {
            return 8 - rem;
        }
    }
    return 0;
}

test "entry" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct { u32, []u8, IndexEntry(hash.Sha1.hash_size) }{
        .{
            2,
            @constCast(&[_]u8{
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
                0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
                0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
                0x0f, 0x1e, 0x2d, 0x3c, 0x80, 0x08, 't',  'e',
                's',  't',  '.',  't',  'x',  't',  0,    0,
            }),
            .{
                .ctime = 0x1390fe681daeebc6,
                .mtime = 0x1390fe681daeebc6,
                .device = 2053,
                .inode = 14_954_102,
                .file_mode = .{
                    .type = .regular_file,
                    .permissions = .{
                        .user = .{ .read = true, .write = true },
                        .group = .{ .read = true },
                        .others = .{ .read = true },
                    },
                },
                .user_id = 1000,
                .group_id = 1000,
                .file_size = 2,
                .hash = [_]u8{
                    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
                    0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
                },
                .flags = .{ .assume_valid = true, .name_length = 8 },
                .path = "test.txt",
            },
        },
        .{
            2,
            @constCast(&[_]u8{
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
                0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
                0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
                0x0f, 0x1e, 0x2d, 0x3c, 0x80, 0x09, 't',  'e',
                's',  't',  '2',  '.',  't',  'x',  't',  0,
            }),
            .{
                .ctime = 0x1390fe681daeebc6,
                .mtime = 0x1390fe681daeebc6,
                .device = 2053,
                .inode = 14_954_102,
                .file_mode = .{
                    .type = .regular_file,
                    .permissions = .{
                        .user = .{ .read = true, .write = true },
                        .group = .{ .read = true },
                        .others = .{ .read = true },
                    },
                },
                .user_id = 1000,
                .group_id = 1000,
                .file_size = 2,
                .hash = [_]u8{
                    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
                    0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
                },
                .flags = .{ .assume_valid = true, .name_length = 9 },
                .path = "test2.txt",
            },
        },
        .{
            3,
            @constCast(&[_]u8{
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
                0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
                0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
                0x0f, 0x1e, 0x2d, 0x3c, 0xc0, 0x08, 0x20, 0,
                't',  'e',  's',  't',  '.',  't',  'x',  't',
                0,    0,    0,    0,    0,    0,    0,    0,
            }),
            .{
                .ctime = 0x1390fe681daeebc6,
                .mtime = 0x1390fe681daeebc6,
                .device = 2053,
                .inode = 14_954_102,
                .file_mode = .{
                    .type = .regular_file,
                    .permissions = .{
                        .user = .{ .read = true, .write = true },
                        .group = .{ .read = true },
                        .others = .{ .read = true },
                    },
                },
                .user_id = 1000,
                .group_id = 1000,
                .file_size = 2,
                .hash = [_]u8{
                    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
                    0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
                },
                .flags = .{ .assume_valid = true, .extended = true, .name_length = 8 },
                .extended_flags = .{ .intent_to_add = true },
                .path = "test.txt",
            },
        },
        .{
            4,
            @constCast(&[_]u8{
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
                0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
                0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
                0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
                0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
                0x0f, 0x1e, 0x2d, 0x3c, 0x80, 0x08, 't',  'e',
                's',  't',  '.',  't',  'x',  't',  0,
            }),
            .{
                .ctime = 0x1390fe681daeebc6,
                .mtime = 0x1390fe681daeebc6,
                .device = 2053,
                .inode = 14_954_102,
                .file_mode = .{
                    .type = .regular_file,
                    .permissions = .{
                        .user = .{ .read = true, .write = true },
                        .group = .{ .read = true },
                        .others = .{ .read = true },
                    },
                },
                .user_id = 1000,
                .group_id = 1000,
                .file_size = 2,
                .hash = [_]u8{
                    0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
                    0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
                },
                .flags = .{ .assume_valid = true, .name_length = 8 },
                .path = "test.txt",
            },
        },
    };

    for (test_cases) |c| {
        const v, const bytes, var expected = c;
        try expectEntry(allocator, bytes, &expected, v);
    }
}

fn expectEntry(allocator: Allocator, bytes: []u8, expected: *IndexEntry(hash.Sha1.hash_size), version: u32) !void {
    const parsed = try IndexEntry(hash.Sha1.hash_size).parse(allocator, bytes, version);

    var entry = parsed.entry;
    defer entry.deinit(allocator);

    var expected_len: usize = 62 + expected.flags.name_length;
    if (expected.flags.extended) {
        expected_len += 2;
    }
    expected_len += if (version == 4) 1 else 8 - (expected_len % 8);
    try std.testing.expect(parsed.len == expected_len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try entry.writeTo(allocator, &buf, version);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));

    try std.testing.expect(entry.ctime == expected.ctime);
    try std.testing.expect(entry.mtime == expected.mtime);
    try std.testing.expect(entry.device == expected.device);
    try std.testing.expect(entry.inode == expected.inode);
    try std.testing.expect(entry.file_mode.eql(&expected.file_mode));
    try std.testing.expect(entry.user_id == expected.user_id);
    try std.testing.expect(entry.group_id == expected.group_id);
    try std.testing.expect(entry.file_size == expected.file_size);

    try std.testing.expect(entry.flags.assume_valid == expected.flags.assume_valid);
    try std.testing.expect(entry.flags.extended == expected.flags.extended);
    try std.testing.expect(entry.flags.stage == expected.flags.stage);
    try std.testing.expect(entry.flags.name_length == expected.flags.name_length);

    if (expected.extended_flags) |extended_flags| {
        try std.testing.expect(entry.extended_flags.?.skip_worktree == extended_flags.skip_worktree);
        try std.testing.expect(entry.extended_flags.?.intent_to_add == extended_flags.intent_to_add);
    }

    try std.testing.expect(std.mem.eql(u8, entry.path, expected.path));
}

test "entry errors" {
    const allocator = std.testing.allocator;

    const too_short_v2: []u8 = @constCast(&[_]u8{
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c, 0x80,
    });
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        IndexEntry(hash.Sha1.hash_size).parse(allocator, too_short_v2, 2),
    );

    const too_short_v3: []u8 = @constCast(&[_]u8{
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c, 0xc0, 0x08, 0x20,
    });
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        IndexEntry(hash.Sha1.hash_size).parse(allocator, too_short_v3, 3),
    );

    const too_short_path_name: []u8 = @constCast(&[_]u8{
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0x54, 0x09, 0x76, 0xe6, 0x1d, 0x81, 0x6f, 0xc6,
        0,    0,    0x08, 0x05, 0,    0xe4, 0x2e, 0x76,
        0,    0,    0x81, 0xa4, 0,    0,    0x03, 0xe8,
        0,    0,    0x03, 0xe8, 0,    0,    0,    0x02,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        0x0f, 0x1e, 0x2d, 0x3c, 0x80, 0x08, 't',  'e',
        's',  't',  '.',  't',  'x',  't',
    });
    try std.testing.expectError(
        error.UnexpectedEndOfFile,
        IndexEntry(hash.Sha1.hash_size).parse(allocator, too_short_path_name, 2),
    );

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var unmatching_name_len: IndexEntry(hash.Sha1.hash_size) = .{
        .ctime = 0x1390fe681daeebc6,
        .mtime = 0x1390fe681daeebc6,
        .device = 2053,
        .inode = 14_954_102,
        .file_mode = .{
            .type = .regular_file,
            .permissions = .{
                .user = .{ .read = true, .write = true },
                .group = .{ .read = true },
                .others = .{ .read = true },
            },
        },
        .user_id = 1000,
        .group_id = 1000,
        .file_size = 2,
        .hash = [_]u8{
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
            0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
        },
        .flags = .{ .assume_valid = true, .name_length = 9 },
        .path = "test.txt",
    };
    try std.testing.expectError(
        error.UnexpectedPathNameLength,
        IndexEntry(hash.Sha1.hash_size).writeTo(&unmatching_name_len, allocator, &buf, 2),
    );
}

/// Flag used during merge.
pub const IndexMergeStage = enum(u2) {
    /// Fully merged, there are no conflicts. It's the default stage.
    none = 0,
    /// Stores the version from the common ancestor.
    base = 1,
    /// Stores the version from the head branch.
    ours = 2,
    /// Stores the version from the other branch.
    theirs = 3,
};

/// Index entry flags.
pub const IndexFlags = packed struct(u16) {
    // bit layout:
    //  0                   1
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  |V|X| S | name length           |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //
    // V: assume-valid flag
    // X: extended flag (0 in index format v2, which does not have extended flags)
    // S: stage (during merge)
    // name length: 12-bit length, limited to 0xFFF if greater

    name_length: u12 = 0,
    stage: IndexMergeStage = .none,
    extended: bool = false,
    assume_valid: bool = false,

    pub fn of(bytes: [2]u8) IndexFlags {
        return @bitCast(std.mem.readInt(u16, &bytes, .big));
    }

    pub fn toBytes(self: IndexFlags) [2]u8 {
        return std.mem.toBytes(std.mem.nativeToBig(u16, @bitCast(self)));
    }

    pub fn eql(a: *const IndexFlags, b: *const IndexFlags) bool {
        return a.assume_valid == b.assume_valid and
            a.extended == b.extended and
            a.stage == b.stage and
            a.name_length == b.name_length;
    }
};

test "flags" {
    const test_cases = [_]struct { [2]u8, IndexFlags }{
        .{ [_]u8{ 0x00, 0x00 }, .{} },
        .{ [_]u8{ 0x80, 0x00 }, .{ .assume_valid = true } },
        .{ [_]u8{ 0x40, 0x00 }, .{ .extended = true } },
        .{ [_]u8{ 0x30, 0x00 }, .{ .stage = .theirs } },
        .{ [_]u8{ 0x20, 0x00 }, .{ .stage = .ours } },
        .{ [_]u8{ 0x10, 0x00 }, .{ .stage = .base } },
        .{ [_]u8{ 0x00, 0x01 }, .{ .name_length = 1 } },
    };

    for (test_cases) |c| {
        const n, const expected = c;

        const flags: IndexFlags = .of(n);
        try std.testing.expect(flags.eql(&expected));

        const reconstructed = flags.toBytes();
        try std.testing.expect(std.mem.eql(u8, &n, &reconstructed));
    }
}

/// Index entry extended flags, used from index format v3.
pub const ExtendedIndexFlags = packed struct(u16) {
    // bit layout:
    //  0                   1
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //  |r|W|A| unused                  |
    //  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    //
    // r: reserved for future
    // W: skip-worktree flag (used by sparse checkout)
    // A: intent-to-add flag (used by "git add -N")

    unused: u13 = 0,
    intent_to_add: bool = false,
    skip_worktree: bool = false,
    reserved: bool = false,

    pub fn of(bytes: [2]u8) ExtendedIndexFlags {
        return @bitCast(std.mem.readInt(u16, &bytes, .big));
    }

    pub fn toBytes(self: ExtendedIndexFlags) [2]u8 {
        return std.mem.toBytes(std.mem.nativeToBig(u16, @bitCast(self)));
    }

    pub fn eql(a: *const ExtendedIndexFlags, b: *const ExtendedIndexFlags) bool {
        return a.skip_worktree == b.skip_worktree and a.intent_to_add == b.intent_to_add;
    }
};

test "extended flags" {
    const test_cases = [_]struct { [2]u8, ExtendedIndexFlags }{
        .{ [_]u8{ 0x00, 0x00 }, .{} },
        .{ [_]u8{ 0x40, 0x00 }, .{ .skip_worktree = true } },
        .{ [_]u8{ 0x20, 0x00 }, .{ .intent_to_add = true } },
    };

    for (test_cases) |c| {
        const n, const expected = c;

        const flags: ExtendedIndexFlags = .of(n);
        try std.testing.expect(flags.eql(&expected));

        const reconstructed = flags.toBytes();
        try std.testing.expect(std.mem.eql(u8, &n, &reconstructed));
    }
}

/// The signature for of an index extension.
pub const Signature = enum(u32) {
    sparse_directory = std.mem.readInt(u32, "sdir", .big),
    _, // for all other not understood extensions

    pub fn fromBytes(bytes: [4]u8) Signature {
        return @enumFromInt(std.mem.readInt(u32, &bytes, .big));
    }

    pub fn toBytes(self: Signature) [4]u8 {
        const value = @intFromEnum(self);
        return std.mem.toBytes(std.mem.nativeToBig(u32, value));
    }

    pub fn isOptional(self: Signature) bool {
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

    sparse_directory: SparseDirectory = @intFromEnum(Signature.sparse_directory),
    unknown: UnknownExtension,

    /// Calls `deinit` on the child object.
    pub fn deinit(self: *IndexExtension, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*s| s.*.deinit(allocator),
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

        const signature = Signature.fromBytes(data[0..4].*);
        const size = std.mem.readInt(u32, data[4..8], .big);

        const total_len = 8 + size;
        if (data.len < total_len) {
            return error.UnexpectedEndOfFile;
        }

        const ext_data = data[8..total_len];

        const instance = blk: switch (signature) {
            .sparse_directory => {
                const sdir = try SparseDirectory.parse(allocator, signature, ext_data);
                break :blk sdir.interface();
            },
            _ => {
                if (!signature.isOptional()) {
                    std.log.debug("Found unknown extension {s}", .{signature.toBytes()});
                    return error.UnknownExtension;
                }
                const res = try UnknownExtension.parse(allocator, signature, ext_data);
                break :blk res.interface();
            },
        };

        return .{
            .extension = instance,
            .len = total_len,
        };
    }

    /// Writes this index extension to `buffer`.
    pub fn writeTo(self: *const IndexExtension, allocator: Allocator, buffer: *std.ArrayList(u8)) !void {
        switch (self.*) {
            inline else => |*s| try s.*.writeTo(allocator, buffer),
        }
    }
};

/// Indicates that the index contains sparse directory entries
/// (pointing to a tree instead of the list of file paths).
/// This struct has no fields because it is only a marker.
/// Conforms to the index extension interface.
pub const SparseDirectory = struct {
    /// Returns an instance of the extension interface.
    pub fn interface(self: SparseDirectory) IndexExtension {
        return .{ .sparse_directory = self };
    }

    pub fn deinit(_: *const SparseDirectory, _: Allocator) void {}

    /// Parses an index extension from `data`.
    pub fn parse(_: Allocator, _: Signature, _: []u8) !SparseDirectory {
        return .{};
    }

    /// Writes the index extension to `buffer`.
    pub fn writeTo(_: *const SparseDirectory, allocator: Allocator, buffer: *std.ArrayList(u8)) !void {
        const type_bytes = Signature.sparse_directory.toBytes();
        try buffer.appendSlice(allocator, &type_bytes);
        try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
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

    try std.testing.expectEqualStrings(@tagName(parsed.extension), @tagName(Signature.sparse_directory));
    try std.testing.expect(parsed.len == bytes.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try parsed.extension.writeTo(allocator, &buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}

/// An index extension that is not understood.
/// Conforms to the index extension interface.
pub const UnknownExtension = struct {
    signature: Signature,
    data: []u8,

    /// Returns an instance of the extension interface.
    pub fn interface(self: UnknownExtension) IndexExtension {
        return .{ .unknown = self };
    }

    /// Frees referenced resources.
    pub fn deinit(self: *UnknownExtension, allocator: Allocator) void {
        allocator.free(self.data);
    }

    /// Parses an index extension from `data`.
    pub fn parse(allocator: Allocator, signature: Signature, data: []u8) !UnknownExtension {
        return .{
            .signature = signature,
            .data = try allocator.dupe(u8, data),
        };
    }

    /// Writes the index extension to `writer`.
    pub fn writeTo(self: *const UnknownExtension, allocator: Allocator, buffer: *std.ArrayList(u8)) !void {
        const type_bytes = self.signature.toBytes();
        try buffer.appendSlice(allocator, &type_bytes);
        try buffer.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(self.data.len))));
        try buffer.appendSlice(allocator, self.data);
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

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try parsed.extension.writeTo(allocator, &buf);
    try std.testing.expect(std.mem.eql(u8, buf.items, bytes));
}
