// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectId = @import("core/ObjectId.zig");

/// Handles the computation of hashes.
pub const Hasher = struct {
    sha1: std.crypto.hash.Sha1,

    /// Initializes a new hasher.
    pub fn init() Hasher {
        return .{
            .sha1 = std.crypto.hash.Sha1.init(.{}),
        };
    }

    /// Updates hasher with data.
    pub fn update(h: *Hasher, data: []const u8) void {
        h.sha1.update(data);
    }

    /// Updates hasher with data from the reader.
    /// Data are read in chunks using the provided buffer.
    pub fn updateFromReader(h: *Hasher, reader: anytype, buffer: []u8) !void {
        while (true) {
            const bytes_read = try reader.read(buffer);
            if (bytes_read == 0) break;
            h.update(buffer[0..bytes_read]);
        }
    }

    /// Resets hasher for reuse.
    pub fn reset(h: *Hasher) void {
        h.sha1 = std.crypto.hash.Sha1.init(.{});
    }

    /// Finalize the hash and store the result in `oid`.
    pub fn final(h: *Hasher, oid: *ObjectId) void {
        h.sha1.final(&oid.hash);
    }

    /// Convenience function to hash data in one step.
    pub fn hashData(data: []const u8) ObjectId {
        var oid = ObjectId.init(.{});

        var hasher = init();
        hasher.update(data);
        hasher.final(&oid);

        return oid;
    }

    /// Convenience function to hash data in one step.
    /// `allocator` is used to create an ObjectId with the computed hash.
    /// Caller owns the returned memory.
    pub fn hashDataAlloc(allocator: Allocator, data: []const u8) !*ObjectId {
        const oid = try ObjectId.alloc(allocator, .{});

        var hasher = init();
        hasher.update(data);
        hasher.final(oid);

        return oid;
    }
};

test "basic operations" {
    const allocator = std.testing.allocator;

    var hasher = Hasher.init();

    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");

    var oid = ObjectId.init(.{});
    hasher.final(&oid);

    var single_step = Hasher.hashData("hello world");
    try std.testing.expect(oid.eql(&single_step));

    const single_step_alloc =
        try Hasher.hashDataAlloc(allocator, "hello world");
    defer allocator.destroy(single_step_alloc);
    try std.testing.expect(oid.eql(single_step_alloc));
}

test "streamed content" {
    const test_data = "This is a test string for streaming";
    var stream = std.io.fixedBufferStream(test_data);

    var hasher = Hasher.init();

    var buf: [8]u8 = undefined;
    try hasher.updateFromReader(stream.reader(), &buf);

    var streamed_result = ObjectId.init(.{});
    hasher.final(&streamed_result);

    var single_step = Hasher.hashData(test_data);
    try std.testing.expect(streamed_result.eql(&single_step));
}

test "reset" {
    var first_result = ObjectId.init(.{});
    var second_result = ObjectId.init(.{});

    var hasher = Hasher.init();

    hasher.update("first data");
    hasher.final(&first_result);

    hasher.reset();
    hasher.update("second data");
    hasher.final(&second_result);
    try std.testing.expect(!first_result.eql(&second_result));

    var fresh_hash = Hasher.hashData("second data");
    try std.testing.expect(second_result.eql(&fresh_hash));
}

test "hashing empty data" {
    var hasher = Hasher.init();

    var empty_result = ObjectId.init(.{});
    hasher.final(&empty_result);

    var expected = Hasher.hashData("");
    try std.testing.expect(empty_result.eql(&expected));
}

test "hashing large chunks" {
    const large_data = "x" ** 1024;

    var obj_id1 = Hasher.hashData(large_data);

    // hash in smaller chunks
    var hasher = Hasher.init();
    var i: usize = 0;
    while (i < large_data.len) {
        const chunk_size = @min(64, large_data.len - i);
        hasher.update(large_data[i..(i + chunk_size)]);
        i += chunk_size;
    }
    var obj_id2 = ObjectId.init(.{});
    hasher.final(&obj_id2);

    try std.testing.expect(obj_id1.eql(&obj_id2));
}
