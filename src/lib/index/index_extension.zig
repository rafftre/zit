// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const SparseDirectory = @import("SparseDirectory.zig");
const UnknownExtension = @import("UnknownExtension.zig");

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
pub const Extension = union(enum(u32)) {
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
    pub fn deinit(self: *const Extension, allocator: Allocator) void {
        switch (self.*) {
            inline else => |*s| s.*.deinit(allocator),
        }
    }

    /// Parses an index extension from `data`.
    /// Returns a tuple with the parsed extension and the length in bytes.
    /// Free returned extension with `deinit`.
    pub fn parse(allocator: Allocator, data: []u8) !struct {
        extension: Extension,
        len: usize,
    } {
        if (data.len < 8) {
            // std.log.err("Found unexpected extension length: {d} < 8", .{data.len});
            return error.UnexpectedEndOfFile;
        }

        const signature = Signature.fromBytes(data[0..4].*);
        const size = std.mem.readInt(u32, data[4..8], .big);

        const total_len = 8 + size;
        if (data.len < total_len) {
            // std.log.err("Found unexpected extension length: {d} < {d}", .{ data.len, total_len });
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
    pub fn writeTo(self: *const Extension, buffer: *std.ArrayList(u8)) !void {
        switch (self.*) {
            inline else => |*s| try s.*.writeTo(buffer),
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
