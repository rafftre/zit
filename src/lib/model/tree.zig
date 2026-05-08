// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs = @import("util/fs.zig");
const hash = @import("util/hash.zig");
const Object = @import("object.zig").Object;
const LooseObject = @import("object.zig").LooseObject;

const mode_len = std.fmt.comptimePrint("{f}", .{fs.FileMode{}}).len;

/// Types of the supported file modes for tree entries.
const TreeEntryType = enum {
    none,
    blob,
    executable,
    tree,
    symlink,
    submodule,

    /// Returns the type for the given file mode.
    pub fn of(m: fs.FileMode) TreeEntryType {
        return switch (m.type) {
            .directory => .tree,
            .symbolic_link => .symlink,
            .gitlink => .submodule,
            .regular_file => if (m.permissions.user.execute) .executable else .blob,
            else => .none,
        };
    }

    /// Returns the file mode for this entry type.
    pub fn mode(self: TreeEntryType) fs.FileMode {
        return switch (self) {
            .none => .{},
            .tree => .{ .type = .directory },
            .symlink => .{ .type = .symbolic_link },
            .submodule => .{ .type = .gitlink },
            .blob => .{
                .type = .regular_file,
                .permissions = .{
                    .user = .{ .read = true, .write = true },
                    .group = .{ .read = true },
                    .others = .{ .read = true },
                },
            },
            .executable => .{
                .type = .regular_file,
                .permissions = .{
                    .user = .{ .read = true, .write = true, .execute = true },
                    .group = .{ .read = true, .execute = true },
                    .others = .{ .read = true, .execute = true },
                },
            },
        };
    }
};

/// A tree entry.
/// It's composed by a file mode, a name, and an object ID.
/// The name borrows from the LooseObject used during deserialization.
pub fn TreeEntry(comptime Hasher: type) type {
    return struct {
        entry_type: TreeEntryType = .blob,
        object_id: ObjectId,
        name: []const u8,

        const Self = @This();
        const ObjectId = Object(Hasher).Id;

        /// Deserializes an entry.
        /// The name in the returned entry borrows from `data`, for this reason `data` must outlive the entry.
        pub fn deserialize(data: []const u8) !Self {
            var offset: usize = 0;

            const mode_end = std.mem.indexOf(u8, data[offset..], " ") orelse return error.InvalidFormat;
            const parsed_mode = try fs.FileMode.parse(data[offset..(offset + mode_end)]);
            offset += mode_end + 1;

            const name_end = std.mem.indexOf(u8, data[offset..], "\x00") orelse return error.InvalidFormat;
            const name = data[offset..(offset + name_end)];
            offset += name_end + 1;

            if (data.len < offset + Hasher.hash_size) return error.InvalidFormat;

            var object_id: ObjectId = .{};
            @memcpy(object_id.bytes[0..Hasher.hash_size], data[offset..(offset + Hasher.hash_size)]);

            return .{
                .entry_type = .of(parsed_mode),
                .object_id = object_id,
                .name = name,
            };
        }

        /// Serializes the entry content.
        /// Caller owns the returned memory.
        pub fn serialize(self: *const Self, allocator: Allocator) ![]u8 {
            const hash_size = Hasher.hash_size;
            const total_len = mode_len + 1 + self.name.len + 1 + hash_size;

            const result = try allocator.alloc(u8, total_len);
            errdefer allocator.free(result);

            _ = try std.fmt.bufPrint(result[0..mode_len], "{f}", .{self.entry_type.mode()});

            var offset: usize = mode_len;

            result[offset] = ' ';
            offset += 1;

            @memcpy(result[offset..(offset + self.name.len)], self.name);
            offset += self.name.len;

            result[offset] = 0;
            offset += 1;

            @memcpy(result[offset..(offset + hash_size)], &self.object_id.bytes);

            return result;
        }

        /// Comparison function for use with `std.mem.sort`.
        pub fn lessThan(_: void, lhs: Self, rhs: Self) bool {
            // Modified version of std.mem.order to take into consideration that
            // directory entries are ordered by adding a slash to the end.
            // See https://github.com/git/git/blob/6074a7d4ae6b658c18465f10bbbf144882d2d4b0/fsck.c#L497

            const n = @min(lhs.name.len, rhs.name.len);
            for (lhs.name[0..n], rhs.name[0..n]) |lhs_elem, rhs_elem| {
                switch (std.math.order(lhs_elem, rhs_elem)) {
                    .eq => continue,
                    .lt => return true,
                    .gt => return false,
                }
            }

            if (lhs.entry_type == .tree and rhs.entry_type != .tree) {
                return rhs.name.len > n and std.math.order('/', rhs.name[n]) == .lt;
            } else if (lhs.entry_type != .tree and rhs.entry_type == .tree) {
                return lhs.name.len <= n or std.math.order(lhs.name[n], '/') == .lt;
            }

            return std.math.order(lhs.name.len, rhs.name.len) == .lt;
        }

        /// Formatting method for use with `std.Io.Writer.print`.
        /// Outputs a single-line string with the format "mode type object-id name".
        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            const mode_label = switch (self.entry_type) {
                .none => "",
                .tree => "tree",
                .submodule => "submodule",
                else => "blob",
            };

            try writer.print("{f} {s} {f} {s}", .{
                self.entry_type.mode(),
                mode_label,
                &self.object_id,
                self.name,
            });
        }
    };
}

test "tree entry serialization" {
    const allocator = std.testing.allocator;
    const TestEntry = TreeEntry(hash.Sha1);

    const entry: TestEntry = .{
        .entry_type = .executable,
        .object_id = try .fromHex("fedcba0987654321fedcba0987654321fedcba09"),
        .name = "script.sh",
    };

    const serialized = try entry.serialize(allocator);
    defer allocator.free(serialized);

    const deserialized: TestEntry = try .deserialize(serialized);

    try std.testing.expect(entry.entry_type == deserialized.entry_type);
    try std.testing.expectEqualSlices(u8, entry.name, deserialized.name);
    try std.testing.expect(entry.object_id.eql(&deserialized.object_id));
}

test "sort tree entry" {
    const TestEntry = TreeEntry(hash.Sha1);

    const empty_file_hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    const readme: TestEntry = .{
        .object_id = try .fromHex(empty_file_hash),
        .name = "README",
    };
    const aout_exe: TestEntry = .{
        .entry_type = .executable,
        .object_id = try .fromHex(empty_file_hash),
        .name = "a.out",
    };
    const aout: TestEntry = .{
        .object_id = try .fromHex(empty_file_hash),
        .name = "a.out",
    };
    const lib: TestEntry = .{
        .object_id = try .fromHex(empty_file_hash),
        .name = "lib",
    };
    const lib_dir: TestEntry = .{
        .entry_type = .tree,
        .object_id = try .fromHex(empty_file_hash),
        .name = "lib",
    };
    const liba: TestEntry = .{
        .object_id = try .fromHex(empty_file_hash),
        .name = "lib-a",
    };

    // lexicographic order
    try std.testing.expectEqual(true, TestEntry.lessThan({}, readme, aout_exe));
    try std.testing.expectEqual(false, TestEntry.lessThan({}, aout_exe, readme));

    // same name
    try std.testing.expectEqual(false, TestEntry.lessThan({}, aout_exe, aout));
    try std.testing.expectEqual(false, TestEntry.lessThan({}, aout, aout_exe));

    // same name has different order when is file or dir
    try std.testing.expectEqual(true, TestEntry.lessThan({}, lib, liba));
    try std.testing.expectEqual(false, TestEntry.lessThan({}, lib_dir, liba));
    try std.testing.expectEqual(true, TestEntry.lessThan({}, liba, lib_dir));

    // same name compared between file and dir versions
    try std.testing.expectEqual(true, TestEntry.lessThan({}, lib, lib_dir));
    try std.testing.expectEqual(false, TestEntry.lessThan({}, lib_dir, lib));
}

test "format tree entry" {
    const allocator = std.testing.allocator;

    const test_hex = "420d00a951a59d664d3617a1f4f6e2de8091049f";
    const test_name = "script.sh";
    const test_data = "100755 blob " ++ test_hex ++ " " ++ test_name;

    const entry: TreeEntry(hash.Sha1) = .{
        .entry_type = .executable,
        .object_id = try Object(hash.Sha1).Id.fromHex(test_hex),
        .name = test_name,
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{entry});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}

/// A tree object.
/// It's a list of entries, sorted by name.
/// Directory entries are ordered by adding a slash to the end.
/// Conforms to the object interface.
/// Entry names do not own their memory; see `addEntry` and `deserialize` functions.
pub fn Tree(comptime Hasher: type) type {
    return struct {
        entries: std.ArrayList(Entry) = .empty,

        const Self = @This();
        const ObjectId = Object(Hasher).Id;

        pub const Entry = TreeEntry(Hasher);
        pub const EntryType = TreeEntryType;

        /// Returns an instance of the object interface.
        pub fn interface(self: Self) Object(Hasher) {
            return .{ .tree = self };
        }

        /// Frees the `entries` list.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.entries.deinit(allocator);
        }

        /// Adds a new entry to the tree.
        /// The `name` slice is stored as-is, the caller must keep it alive for the lifetime of the tree.
        /// Sorts entries after addition.
        pub fn addEntry(
            self: *Self,
            allocator: Allocator,
            entry_type: EntryType,
            object_id: ObjectId,
            name: []const u8,
        ) !Entry {
            const entry: Entry = .{
                .entry_type = entry_type,
                .object_id = object_id,
                .name = name,
            };

            try self.entries.append(allocator, entry);
            std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);

            return entry;
        }

        /// Deserializes a tree.
        /// Entry names borrow from `obj.content`,
        /// for this reason `obj` must outlive the tree.
        /// Deinitialize with `deinit` to free the `entries` list.
        /// Implements the method with the same name in the object interface.
        pub fn deserialize(allocator: Allocator, obj: *const LooseObject(Hasher)) !Self {
            var entries: std.ArrayList(Entry) = .empty;
            errdefer entries.deinit(allocator);

            const data: []const u8 = obj.content;

            var offset: usize = 0;
            while (offset < data.len) {
                const space_pos = std.mem.indexOf(u8, data[offset..], " ") orelse break;
                const null_pos = std.mem.indexOf(u8, data[(offset + space_pos + 1)..], "\x00") orelse break;
                const entry_end = offset + space_pos + 1 + null_pos + 1 + Hasher.hash_size;

                if (entry_end > data.len) break;

                const entry = try entries.addOne(allocator);
                entry.* = try Entry.deserialize(data[offset..entry_end]);

                offset = entry_end;
            }

            return .{ .entries = entries };
        }

        /// Serializes the tree.
        /// Caller owns the returned memory.
        /// Implements the method with the same name in the object interface.
        pub fn serialize(self: *const Self, allocator: Allocator) !LooseObject(Hasher) {
            std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);

            var total_size: usize = 0;
            var serialized_entries = try allocator.alloc([]u8, self.entries.items.len);
            defer {
                for (serialized_entries) |entry_data| {
                    allocator.free(entry_data);
                }
                allocator.free(serialized_entries);
            }

            for (self.entries.items, 0..) |*entry, i| {
                serialized_entries[i] = try entry.serialize(allocator);
                total_size += serialized_entries[i].len;
            }

            const result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);

            var offset: usize = 0;
            for (serialized_entries) |entry_data| {
                @memcpy(result[offset..(offset + entry_data.len)], entry_data);
                offset += entry_data.len;
            }

            return .{
                .object_type = .tree,
                .content = result,
            };
        }

        /// Formatting method for use with `std.Io.Writer.print`.
        /// Outputs an entry for each line.
        pub fn format(self: *const Self, writer: *std.Io.Writer) !void {
            std.mem.sort(Entry, self.entries.items, {}, Entry.lessThan);

            for (self.entries.items) |*entry| {
                try writer.print("{f}\n", .{entry});
            }
        }
    };
}

test "tree serialization" {
    const allocator = std.testing.allocator;
    const TestTree = Tree(hash.Sha1);

    var tree: TestTree = .{};
    defer tree.deinit(allocator);

    const file_entry = try tree.addEntry(
        allocator,
        .blob,
        try .fromHex("1234567890123456789012345678901234567890"),
        "file1.txt",
    );

    const dir_entry = try tree.addEntry(
        allocator,
        .tree,
        try .fromHex("abcdefabcdefabcdefabcdefabcdefabcdefabcd"),
        "subdir",
    );

    var serialized = try tree.serialize(allocator);
    defer serialized.deinit(allocator);

    var deserialized = try TestTree.deserialize(allocator, &serialized);
    defer deserialized.deinit(allocator);

    try std.testing.expectEqual(2, deserialized.entries.items.len);

    const first_entry = deserialized.entries.items[0];
    try std.testing.expect(file_entry.entry_type == first_entry.entry_type);
    try std.testing.expectEqualSlices(u8, file_entry.name, first_entry.name);
    try std.testing.expect(file_entry.object_id.eql(&first_entry.object_id));

    const second_entry = deserialized.entries.items[1];
    try std.testing.expect(dir_entry.entry_type == second_entry.entry_type);
    try std.testing.expectEqualSlices(u8, dir_entry.name, second_entry.name);
    try std.testing.expect(dir_entry.object_id.eql(&second_entry.object_id));
}

test "format tree" {
    const allocator = std.testing.allocator;
    const TestTree = Tree(hash.Sha1);

    const test_data =
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 README
        \\100755 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo.bar
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 foo.bar.baz
        \\100644 blob e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 lib-a
        \\040000 tree e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 lib
        \\
    ;
    const empty_file_hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";

    var tree: TestTree = .{};
    defer tree.deinit(allocator);

    _ = try tree.addEntry(allocator, .blob, try .fromHex(empty_file_hash), "foo.bar.baz");
    _ = try tree.addEntry(allocator, .blob, try .fromHex(empty_file_hash), "foo.bar");
    _ = try tree.addEntry(allocator, .executable, try .fromHex(empty_file_hash), "foo");
    _ = try tree.addEntry(allocator, .tree, try .fromHex(empty_file_hash), "lib");
    _ = try tree.addEntry(allocator, .blob, try .fromHex(empty_file_hash), "lib-a");
    _ = try tree.addEntry(allocator, .blob, try .fromHex(empty_file_hash), "README");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "{f}", .{tree});
    try std.testing.expectEqualSlices(u8, test_data, buf.items);
}
