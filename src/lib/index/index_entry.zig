// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const helpers = @import("../helpers.zig");
const FileMode = helpers.file.Mode;

pub const EntrySha1 = Entry(helpers.hash.Sha1.hash_size);
pub const EntrySha256 = Entry(helpers.hash.Sha256.hash_size);

/// Returns an index entry with the specified hash size in bytes.
pub fn Entry(comptime hash_size: usize) type {
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
        //  | path name...                                                  |
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
        flags: Flags,
        extended_flags: ?ExtendedFlags = null, // requires flags.extended == true
        path_name: [:0]const u8,

        const Self = @This();

        /// Frees referenced resources.
        pub fn deinit(self: *const Self, allocator: Allocator) void {
            allocator.free(self.path_name);
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
            const flags = Flags.of(data[60..62].*);

            var extended_flags: ?ExtendedFlags = null;
            if (version >= 3 and flags.extended) {
                if (data.len < 64) {
                    return error.UnexpectedEndOfFile;
                }
                extended_flags = ExtendedFlags.of(data[62..64].*);
            }

            var path_name_start: usize = 62;
            if (extended_flags) |_| {
                path_name_start = 64;
            }
            const path_name = try parsePathName(allocator, data[path_name_start..], flags.name_length);

            const path_name_end = path_name_start + path_name.len + 1; // +1 is for the null-terminator
            const pad_len = if (version == 4) 0 else 8 - (path_name_end % 8);

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
                .path_name = path_name,
            };

            return .{
                .entry = entry,
                .len = path_name_end + pad_len,
            };
        }

        /// Writes the index entry to `buffer` using format `version`.
        pub fn writeTo(self: *Self, buffer: *std.ArrayList(u8), version: u32) !void {
            const start_pos = buffer.items.len;

            const ctime_sec: u32 = @intCast(@divFloor(self.ctime, std.time.ns_per_s));
            const ctime_nsec: u32 = @intCast(@mod(self.ctime, std.time.ns_per_s));
            const mtime_sec: u32 = @intCast(@divFloor(self.mtime, std.time.ns_per_s));
            const mtime_nsec: u32 = @intCast(@mod(self.mtime, std.time.ns_per_s));
            const file_mode = @as(u32, self.file_mode.toInt());

            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, ctime_sec)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, ctime_nsec)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, mtime_sec)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, mtime_nsec)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.device)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.inode)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, file_mode)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.user_id)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.group_id)));
            try buffer.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, self.file_size)));
            try buffer.appendSlice(&self.hash);
            try buffer.appendSlice(&self.flags.toBytes());

            if (version >= 3 and self.flags.extended) {
                if (self.extended_flags) |ext_flags| {
                    try buffer.appendSlice(&ext_flags.toBytes());
                }
            }

            try buffer.appendSlice(self.path_name);
            try buffer.append(0); // null-terminator

            if (version != 4) { // padding
                const entry_len = buffer.items.len - start_pos;
                const pad_len = 8 - (entry_len % 8);
                for (0..pad_len) |_| {
                    try buffer.append(0);
                }
            }
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
    };
}

test "entry" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct { u32, []u8, EntrySha1 }{
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
                .flags = Flags{ .assume_valid = true, .name_length = 8 },
                .path_name = "test.txt",
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
                .flags = Flags{ .assume_valid = true, .extended = true, .name_length = 8 },
                .extended_flags = ExtendedFlags{ .intent_to_add = true },
                .path_name = "test.txt",
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
                .flags = Flags{ .assume_valid = true, .name_length = 8 },
                .path_name = "test.txt",
            },
        },
    };

    for (test_cases) |c| {
        const v, const bytes, var expected = c;
        try expectEntry(allocator, bytes, &expected, v);
    }
}

fn expectEntry(allocator: Allocator, bytes: []u8, expected: *EntrySha1, version: u32) !void {
    const parsed = try EntrySha1.parse(allocator, bytes, version);

    var entry = parsed.entry;
    defer entry.deinit(allocator);

    var expected_len: usize = 62 + expected.flags.name_length;
    if (expected.flags.extended) {
        expected_len += 2;
    }
    expected_len += if (version == 4) 1 else 8 - (expected_len % 8);
    try std.testing.expect(parsed.len == expected_len);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try entry.writeTo(&buf, version);
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

    try std.testing.expect(std.mem.eql(u8, entry.path_name, expected.path_name));
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
    try std.testing.expectError(error.UnexpectedEndOfFile, EntrySha1.parse(allocator, too_short_v2, 2));

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
    try std.testing.expectError(error.UnexpectedEndOfFile, EntrySha1.parse(allocator, too_short_v3, 3));

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
        EntrySha1.parse(allocator, too_short_path_name, 2),
    );
}

/// Flag used during merge.
pub const MergeStage = enum(u2) {
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
pub const Flags = packed struct(u16) {
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
    stage: MergeStage = .none,
    extended: bool = false,
    assume_valid: bool = false,

    pub fn of(bytes: [2]u8) Flags {
        return @bitCast(std.mem.readInt(u16, &bytes, .big));
    }

    pub fn toBytes(self: Flags) [2]u8 {
        return std.mem.toBytes(std.mem.nativeToBig(u16, @bitCast(self)));
    }
};

test "flags" {
    const test_cases = [_]struct { [2]u8, Flags }{
        .{ [_]u8{ 0x00, 0x00 }, Flags{} },
        .{ [_]u8{ 0x80, 0x00 }, Flags{ .assume_valid = true } },
        .{ [_]u8{ 0x40, 0x00 }, Flags{ .extended = true } },
        .{ [_]u8{ 0x30, 0x00 }, Flags{ .stage = .theirs } },
        .{ [_]u8{ 0x20, 0x00 }, Flags{ .stage = .ours } },
        .{ [_]u8{ 0x10, 0x00 }, Flags{ .stage = .base } },
        .{ [_]u8{ 0x00, 0x01 }, Flags{ .name_length = 1 } },
    };

    for (test_cases) |c| {
        const n, const expected = c;
        try expectFlags(n, expected);
    }
}

fn expectFlags(bytes: [2]u8, expected: Flags) !void {
    const flags = Flags.of(bytes);
    const reconstructed = flags.toBytes();

    try std.testing.expect(std.mem.eql(u8, &bytes, &reconstructed));

    try std.testing.expect(flags.assume_valid == expected.assume_valid);
    try std.testing.expect(flags.extended == expected.extended);
    try std.testing.expect(flags.stage == expected.stage);
    try std.testing.expect(flags.name_length == expected.name_length);
}

/// Index entry extended flags, used from index format v3.
pub const ExtendedFlags = packed struct(u16) {
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

    pub fn of(bytes: [2]u8) ExtendedFlags {
        return @bitCast(std.mem.readInt(u16, &bytes, .big));
    }

    pub fn toBytes(self: ExtendedFlags) [2]u8 {
        return std.mem.toBytes(std.mem.nativeToBig(u16, @bitCast(self)));
    }
};

test "extended flags" {
    const test_cases = [_]struct { [2]u8, ExtendedFlags }{
        .{ [_]u8{ 0x00, 0x00 }, ExtendedFlags{} },
        .{ [_]u8{ 0x40, 0x00 }, ExtendedFlags{ .skip_worktree = true } },
        .{ [_]u8{ 0x20, 0x00 }, ExtendedFlags{ .intent_to_add = true } },
    };

    for (test_cases) |c| {
        const n, const expected = c;
        try expectExtendedFlags(n, expected);
    }
}

fn expectExtendedFlags(bytes: [2]u8, expected: ExtendedFlags) !void {
    const flags = ExtendedFlags.of(bytes);
    const reconstructed = flags.toBytes();

    try std.testing.expect(std.mem.eql(u8, &bytes, &reconstructed));

    try std.testing.expect(flags.skip_worktree == expected.skip_worktree);
    try std.testing.expect(flags.intent_to_add == expected.intent_to_add);
}
