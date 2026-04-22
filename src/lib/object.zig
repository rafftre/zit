// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const Allocator = std.mem.Allocator;

const hash = @import("model/util/hash.zig");
const Repository = @import("repository.zig").Repository;

/// The type for an object.
pub const Type = @import("model/object.zig").Type;

/// Computes the object's identifier and optionally writes the content to the object store.
/// When `check_format` is `true`, it checks that the content passes the standard object parsing.
/// If `repository` is provided, writes to the object store.
/// Caller owns the returned memory.
pub fn create(
    allocator: Allocator,
    /// A reader instance from which the content will be read.
    reader: *std.Io.Reader,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for writing the object; it can be null if it is not to be saved to the store.
    repository: ?Repository(Hasher),
    /// The type of the object, returns an error if it is not a valid type.
    obj_type: Type,
    /// `true` means the object must pass standard object parsing otherwise an error is returned.
    check_format: bool,
) !Repository(Hasher).Object.Id {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();

    _ = try reader.streamRemaining(&bytes.writer);

    var obj: Repository(Hasher).LooseObject = .{
        .object_type = obj_type,
        .content = try bytes.toOwnedSlice(),
    };
    defer obj.deinit(allocator);

    const encoded_obj = try obj.encode(allocator);
    defer allocator.free(encoded_obj);

    if (check_format) {
        var decoded: Repository(Hasher).LooseObject = try .decode(
            allocator,
            encoded_obj,
            .{ .expected_type = obj_type },
        );
        defer decoded.deinit(allocator);
    }

    var object_id: Repository(Hasher).Object.Id = .{};
    Hasher.hashData(encoded_obj, &object_id.bytes);

    if (repository) |r| {
        var obj_r: std.Io.Reader = .fixed(encoded_obj);
        try r.writeObject(allocator, &obj_r, &object_id);
    }

    return object_id;
}

/// Reads the object identified by `object_id` in the object store.
/// When `expected_type` is specified, the type read must match it, otherwise an error will be returned.
/// Caller owns the returned memory.
pub fn read(
    allocator: Allocator,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for reading the object.
    repository: Repository(Hasher),
    /// The object's identifier.
    object_id: *const Repository(Hasher).Object.Id,
    /// The expected type of the object, returns an error if it doesn't match.
    expected_type: ?Type,
) !Repository(Hasher).LooseObject {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();

    try repository.readObject(allocator, &bytes.writer, object_id);

    return .decode(allocator, bytes.written(), .{
        .expected_type = expected_type,
        .expected_hash = object_id.bytes,
    });
}

test "create and read object" {
    const allocator = std.testing.allocator;

    const test_hasher = hash.Sha1;
    const test_hex = "cbf44659b798ad460e1bd18ded6b4784b0db4997";
    const test_content = "Hello, Zig!";

    var repo = try tmpRepository(allocator, test_hasher);
    defer repo.deinit(allocator);

    const obj_id = try createTestObject(allocator, test_hasher, repo, test_hex, @constCast(test_content));

    var read_obj = try read(allocator, test_hasher, repo, &obj_id, .blob);
    defer read_obj.deinit(allocator);

    try std.testing.expectEqual(.blob, read_obj.object_type);
    try std.testing.expectEqualStrings(test_content, read_obj.content);
}

/// Reads the type of the object identified by `object_id` in the object store.
/// If `allow_unknown_type` is `true`, no error will be raised for an unknown type.
/// Caller owns the returned memory.
pub fn getType(
    allocator: Allocator,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for reading the object.
    repository: Repository(Hasher),
    /// The object's identifier.
    object_id: *const Repository(Hasher).Object.Id,
    /// If `true` no error will be raised for an unknown type.
    allow_unknown_type: bool,
) !Type {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();

    try repository.readObject(allocator, &bytes.writer, object_id);

    var decoded: Repository(Hasher).LooseObject = try .decode(allocator, bytes.written(), .{
        .allow_unknown_type = allow_unknown_type,
    });
    defer decoded.deinit(allocator);

    return decoded.object_type;
}

test "get object type" {
    const allocator = std.testing.allocator;

    const test_hasher = hash.Sha1;
    const test_hex = "cbf44659b798ad460e1bd18ded6b4784b0db4997";
    const test_content = "Hello, Zig!";

    var repo = try tmpRepository(allocator, test_hasher);
    defer repo.deinit(allocator);

    const obj_id = try createTestObject(allocator, test_hasher, repo, test_hex, @constCast(test_content));

    const read_typ = try getType(allocator, test_hasher, repo, &obj_id, true);
    try std.testing.expectEqualStrings("blob", read_typ.toString().?);
}

/// Reads the size of the object identified by `object_id` in the object store.
/// If `allow_unknown_type` is `true`, no error will be raised for an unknown type.
/// Caller owns the returned memory.
pub fn getSize(
    allocator: Allocator,
    /// The type of hasher.
    comptime Hasher: type,
    /// The repository to use for reading the object.
    repository: Repository(Hasher),
    /// The object's identifier.
    object_id: *Repository(Hasher).Object.Id,
    /// If `true` no error will be raised for an unknown type.
    allow_unknown_type: bool,
) !usize {
    var bytes: std.Io.Writer.Allocating = .init(allocator);
    defer bytes.deinit();

    try repository.readObject(allocator, &bytes.writer, object_id);

    var decoded: Repository(Hasher).LooseObject = try .decode(allocator, bytes.written(), .{
        .allow_unknown_type = allow_unknown_type,
    });
    defer decoded.deinit(allocator);

    return decoded.content.len;
}

test "get object size" {
    const allocator = std.testing.allocator;

    const test_hasher = hash.Sha1;
    const test_hex = "cbf44659b798ad460e1bd18ded6b4784b0db4997";
    const test_content = "Hello, Zig!";

    var repo = try tmpRepository(allocator, test_hasher);
    defer repo.deinit(allocator);

    var obj_id = try createTestObject(allocator, test_hasher, repo, test_hex, @constCast(test_content));

    const obj_size = try getSize(allocator, test_hasher, repo, &obj_id, true);
    try std.testing.expect(test_content.len == obj_size);
}

fn createTestObject(
    allocator: Allocator,
    comptime Hasher: type,
    repository: Repository(Hasher),
    object_name: []const u8,
    content: []u8,
) !Repository(Hasher).Object.Id {
    var reader: std.Io.Reader = .fixed(content);

    const object_id = try create(allocator, &reader, Hasher, repository, .blob, true);

    const hex = try object_id.toHex(allocator);
    defer allocator.free(hex);

    try std.testing.expectEqualStrings(object_name, hex);

    return object_id;
}

/// Setup a new Git repository in a temp directory.
fn tmpRepository(allocator: Allocator, comptime Hasher: type) !Repository(Hasher) {
    const GitRepository = Repository(Hasher).GitRepository;

    var env: std.process.EnvMap = .init(allocator);
    defer env.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const test_dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(test_dir_path);

    return .{ .git = try GitRepository.setup(
        allocator,
        test_dir_path,
        "test",
        false,
        env,
    ) };
}
