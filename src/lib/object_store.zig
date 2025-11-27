// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const FileObjectStore = @import("storage/FileObjectStore.zig");

/// The interface for an object store.
pub const ObjectStore = union(enum) {
    file: FileObjectStore,

    const Self = @This();

    /// Sets up all the initial structures needed for an object store.
    /// This is supposed to be performed on first use of a new object store,
    /// but can be done again to recover corrupted structures.
    pub fn setup(self: *Self) !void {
        switch (self.*) {
            inline else => |*s| try s.*.setup(),
        }
    }

    /// Returns the raw content of an object in the store.
    /// Returned memory is owned by the caller.
    pub fn read(self: *const Self, allocator: Allocator, name: []const u8) ![]u8 {
        switch (self.*) {
            inline else => |*s| return s.*.read(allocator, name),
        }
    }

    /// Writes the raw content of an object to the store.
    pub fn write(self: *const Self, allocator: Allocator, name: []const u8, bytes: []u8) !void {
        switch (self.*) {
            inline else => |*s| try s.*.write(allocator, name, bytes),
        }
    }
};

test "test object store" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    var store: ObjectStore = .{ .file = .{} };

    try store.file.init(allocator, test_dir_path);
    defer store.file.deinit(allocator);

    try store.setup();

    const obj_name = "r3test";
    const obj_data = "sample content";

    try store.write(allocator, obj_name, @constCast(obj_data));

    const read_data = try store.read(allocator, obj_name);
    defer allocator.free(read_data);

    try std.testing.expect(std.mem.eql(u8, read_data, obj_data));
}
