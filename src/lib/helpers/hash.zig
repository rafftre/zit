// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Hashing functions and binary to hex string conversions.

const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

pub const Sha1 = Hasher(std.crypto.hash.Sha1);
pub const Sha256 = Hasher(std.crypto.hash.sha2.Sha256);

/// Handles the computation of hashes with the specified function.
pub fn Hasher(comptime HashFn: type) type {
    return struct {
        hash_fn: HashFn,

        const Self = @This();
        pub const hash_size = HashFn.digest_length;

        /// Initializes a new hasher.
        pub fn init() Self {
            return .{
                .hash_fn = HashFn.init(.{}),
            };
        }

        /// Updates hasher with data.
        pub fn update(self: *Self, data: []const u8) void {
            self.hash_fn.update(data);
        }

        /// Finalize the hash and store the result into `out`.
        pub fn final(self: *Self, out: *[hash_size]u8) void {
            self.hash_fn.final(out);
        }

        /// Convenience function to hash data in one step and store the result into `out`.
        pub fn hashData(data: []const u8, out: *[hash_size]u8) void {
            var hasher = init();
            hasher.update(data);
            hasher.final(out);
        }
    };
}

test "basic SHA-1 operations" {
    var hasher = Sha1.init();

    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");

    var hash: [Sha1.hash_size]u8 = undefined;
    hasher.final(&hash);

    var single_step: [Sha1.hash_size]u8 = undefined;
    Sha1.hashData("hello world", &single_step);

    try std.testing.expectEqualSlices(u8, &hash, &single_step);
}

test "SHA-1 with empty data" {
    var hasher = Sha1.init();

    var empty_result: [Sha1.hash_size]u8 = undefined;
    hasher.final(&empty_result);

    var expected: [Sha1.hash_size]u8 = undefined;
    Sha1.hashData("", &expected);

    try std.testing.expectEqualSlices(u8, &empty_result, &expected);
}

test "SHA-1 with large chunks of data" {
    const large_data = "x" ** 1024;

    var hash1: [Sha1.hash_size]u8 = undefined;
    Sha1.hashData(large_data, &hash1);

    // hash in smaller chunks
    var hasher = Sha1.init();
    var i: usize = 0;
    while (i < large_data.len) {
        const chunk_size = @min(64, large_data.len - i);
        hasher.update(large_data[i..(i + chunk_size)]);
        i += chunk_size;
    }
    var hash2: [Sha1.hash_size]u8 = undefined;
    hasher.final(&hash2);

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "basic SHA-256 operations" {
    var hasher = Sha256.init();

    hasher.update("hello");
    hasher.update(" ");
    hasher.update("world");

    var hash: [Sha256.hash_size]u8 = undefined;
    hasher.final(&hash);

    var single_step: [Sha256.hash_size]u8 = undefined;
    Sha256.hashData("hello world", &single_step);

    try std.testing.expectEqualSlices(u8, &hash, &single_step);
}

test "SHA-256 with empty data" {
    var hasher = Sha256.init();

    var empty_result: [Sha256.hash_size]u8 = undefined;
    hasher.final(&empty_result);

    var expected: [Sha256.hash_size]u8 = undefined;
    Sha256.hashData("", &expected);

    try std.testing.expectEqualSlices(u8, &empty_result, &expected);
}

test "SHA-256 with large chunks of data" {
    const large_data = "x" ** 1024;

    var hash1: [Sha256.hash_size]u8 = undefined;
    Sha256.hashData(large_data, &hash1);

    // hash in smaller chunks
    var hasher = Sha256.init();
    var i: usize = 0;
    while (i < large_data.len) {
        const chunk_size = @min(64, large_data.len - i);
        hasher.update(large_data[i..(i + chunk_size)]);
        i += chunk_size;
    }
    var hash2: [Sha256.hash_size]u8 = undefined;
    hasher.final(&hash2);

    try std.testing.expectEqualSlices(u8, &hash1, &hash2);
}

/// Converts an hash as an hexadecimal string into `out`.
pub fn toHex(hash: []u8, out: []u8) !void {
    const hex_len = hash.len * 2;

    if (out.len != hex_len) {
        return error.InvalidBufferLength;
    }

    for (hash, 0..) |byte, i| {
        const j = i * 2;
        _ = try std.fmt.bufPrint(out[j..(j + 2)], "{x:0>2}", .{byte});
    }
}

/// Parses an hash from an hexadecimal string into `out`.
pub fn parseHex(hex: []const u8, out: []u8) !void {
    const hash_size = hex.len / 2;

    if (out.len != hash_size) {
        return error.InvalidBufferLength;
    }

    var buf = [_]u8{0} ** 32;
    var fba = FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const res = try allocator.alloc(u8, hash_size);
    defer allocator.free(res);

    for (0..hash_size) |i| {
        const j = i * 2;
        const hex_pair = hex[j..(j + 2)];
        res[i] = std.fmt.parseInt(u8, hex_pair, 16) catch return error.InvalidHexCharacter;
    }

    @memcpy(out[0..hash_size], res);
}

test "conversion to hex" {
    const allocator = std.testing.allocator;

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    const test_hash = @constCast(&[_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    });

    const buf = try allocator.alloc(u8, Sha1.hash_size * 2);
    defer allocator.free(buf);

    try toHex(test_hash, buf);
    try std.testing.expectEqualStrings(test_chars, buf);

    var parsed: [Sha1.hash_size]u8 = undefined;
    try parseHex(buf, &parsed);
    try std.testing.expect(std.mem.eql(u8, test_hash, &parsed));
}

test "conversion errors" {
    const test_hash = @constCast(&[_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    });

    var buf: [Sha1.hash_size]u8 = undefined;

    // invalid length
    try std.testing.expectError(error.InvalidBufferLength, parseHex("abc", &buf));

    // invalid characters
    try std.testing.expectError(
        error.InvalidHexCharacter,
        parseHex("gggggggggggggggggggggggggggggggggggggggg", &buf),
    );

    // buffer too small
    var small_buffer: [(Sha1.hash_size * 2) - 1]u8 = undefined;
    try std.testing.expectError(error.InvalidBufferLength, toHex(test_hash, &small_buffer));

    // invalid characters & partial writes
    const zeros: [Sha1.hash_size]u8 = [_]u8{0} ** Sha1.hash_size;
    buf = [_]u8{0} ** Sha1.hash_size;
    try std.testing.expectError(
        error.InvalidHexCharacter,
        parseHex("0123456789abcdeffedcba98765432100f1e2d3g", &buf),
    );
    try std.testing.expect(std.mem.eql(u8, &zeros, &buf));
}

/// Formats an hash as an hexadecimal string to `writer`.
pub fn formatAsHex(hash: []u8, writer: anytype) !void {
    for (hash) |byte| {
        _ = try writer.print("{x:0>2}", .{byte});
    }
}

test "format" {
    const allocator = std.testing.allocator;

    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    const test_hash = @constCast(&[_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    });

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try formatAsHex(test_hash, buf.writer());

    try std.testing.expectEqualSlices(u8, test_chars, buf.items);
}

/// Returns whether the hash starts with `prefix`.
pub fn hasPrefix(hash: []u8, prefix: []u8) bool {
    if (prefix.len > hash.len) {
        return false;
    }
    return std.mem.eql(u8, hash[0..prefix.len], prefix);
}

test "has prefix" {
    const test_hash = @constCast(&[_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0xfe, 0xdc,
        0xba, 0x98, 0x76, 0x54, 0x32, 0x10, 0x0f, 0x1e, 0x2d, 0x3c,
    });
    const test_prefix: []u8 = @constCast(&[_]u8{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd,
    });
    var non_prefix = [_]u8{0} ** 21;
    @memcpy(non_prefix[0..test_hash.len], test_hash);

    try std.testing.expect(hasPrefix(test_hash, test_prefix));
    try std.testing.expect(hasPrefix(test_hash, test_hash));

    try std.testing.expect(!hasPrefix(test_hash, @constCast(&[_]u8{0})));
    try std.testing.expect(!hasPrefix(test_hash, @constCast(&non_prefix)));
}

/// Returns whether the hexadecimal string starts with `prefix`.
pub fn startsWith(hex: []const u8, prefix: []const u8) bool {
    if (prefix.len > hex.len) {
        return false;
    }
    return std.mem.eql(u8, hex[0..prefix.len], prefix);
}

test "starts with" {
    const test_chars = "0123456789abcdeffedcba98765432100f1e2d3c";
    const test_prefix = "0123456";
    const non_prefix = test_chars ++ "0";

    try std.testing.expect(startsWith(test_chars, test_prefix));
    try std.testing.expect(startsWith(test_chars, test_chars));

    try std.testing.expect(!startsWith(test_chars, "a"));
    try std.testing.expect(!startsWith(test_chars, non_prefix));
}
