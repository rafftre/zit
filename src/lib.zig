// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! Git logic and rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const core = @import("lib/core.zig");
pub const GitObjectStore = @import("lib/GitObjectStore.zig");
pub const GitRepository = @import("lib/GitRepository.zig");
pub const Hasher = @import("lib/hash.zig").Hasher;
pub const RawObject = @import("lib/RawObject.zig");

const Object = core.Object;
const ObjectId = core.ObjectId;
const ObjectType = core.ObjectType;
const Repository = core.Repository;

const deserializeByType = @import("lib/core/object.zig").deserializeByType;
const max_file_size = GitObjectStore.max_file_size;

/// Opens an existing Git repository.
/// Search the repository on the file-system starting from `start_dir_name`,
/// or from the current directory if not specified.
/// Free with `deinit`.
pub inline fn openGitRepository(allocator: Allocator, start_dir_name: ?[]const u8) !Repository {
    var git_repo = try GitRepository.init(allocator, start_dir_name);
    var git_obj_store = try GitObjectStore.init(allocator, git_repo.git_dir_path);

    var repo = git_repo.repository(git_obj_store.objectStore());
    try repo.open();
    return repo;
}

pub const CreateRepositoryOptions = @import("lib/GitRepository.zig").SetupOptions;

/// Creates an empty Git repository or reinitializes an existing one.
/// The repository will be created on the file-system
/// in the directory `options.name` (or in the current directory when not specified)
/// and with an in initial branch named `options.initial_branch` (or `main` when not specified).
/// Free with `deinit`.
pub inline fn createGitRepository(allocator: Allocator, options: CreateRepositoryOptions) !Repository {
    var git_repo = try GitRepository.setup(allocator, options);
    var git_obj_store = try GitObjectStore.setup(allocator, git_repo.git_dir_path);

    return git_repo.repository(git_obj_store.objectStore());
}

/// Computes the object's identifier name and optionally writes to the object store.
/// `type_str` is the type of the object, returns an error if it is not a valid type.
/// When `check_format` is `true`, it checks that the content passes the standard object parsing.
/// If `persist` is `true` writes to the object store.
/// Caller owns the returned memory.
pub fn hashObject(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// A generic reader instance from which the content will be read.
    reader: anytype,
    /// The type of the object, returns an error if it is not a valid type.
    type_str: []const u8,
    /// `true` means the object must pass standard object parsing otherwise an error is returned.
    check_format: bool,
    /// `true` means the object will be saved into the object store.
    persist: bool,
) ![]const u8 {
    var stream = std.io.bufferedReader(reader);

    const raw_content = try stream.reader().readAllAlloc(allocator, max_file_size);
    defer allocator.free(raw_content);

    const obj_type = ObjectType.parse(type_str) orelse return error.InvalidType;

    const maybe_parsed = if (check_format) try Object.deserializeByType(allocator, obj_type, raw_content) else null;
    defer {
        if (maybe_parsed) |p| {
            p.destroy(allocator);
        }
    }

    const raw_obj = RawObject.init(obj_type, raw_content);

    const encoded = try raw_obj.encode(allocator);
    defer allocator.free(encoded);

    const oid = Hasher.hashData(encoded);

    const hex = try oid.toHexStringAlloc(allocator);
    errdefer allocator.free(hex);

    if (persist) {
        try object_store.write(allocator, hex, encoded);
    }

    return hex;
}

/// Reads the object content identified by `name` in the object store.
/// When `expected_type` is specified, the type read must match it, otherwise an error will be returned.
/// Caller owns the returned memory.
pub fn readObject(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// The name used to identify the object.
    name: []const u8,
    /// The expected type of the object, returns an error if it doesn't match.
    expected_type: ?[]const u8,
) !Object {
    try validateObjectName(name);

    const raw_content = try object_store.read(allocator, name);
    defer allocator.free(raw_content);

    if (raw_content.len == 0) return error.InvalidObject;

    const decoded = try RawObject.decode(raw_content, .{
        .expected_type = ObjectType.parse(expected_type),
    });
    switch (decoded.typ) {
        .known_type => |t| return try Object.deserializeByType(allocator, t, decoded.data),
        .unknown_tag => return error.UnknownType,
    }
}

/// Reads the type and the size of the object identified by `name` in the object store.
/// If `allow_unknown_type` is `true`, no error will be raised for an unknown type.
/// Caller owns the returned memory.
pub fn readTypeAndSize(
    allocator: Allocator,
    /// An object store instance.
    object_store: anytype,
    /// The name used to identify the object.
    name: []const u8,
    /// If `true` no error will be raised for an unknown type.
    allow_unknown_type: bool,
) !struct { obj_type: []const u8, obj_size: usize } {
    try validateObjectName(name);

    const raw_content = try object_store.read(allocator, name);
    defer allocator.free(raw_content);

    if (raw_content.len == 0) return error.InvalidObject;

    const decoded = try RawObject.decode(raw_content, .{
        .allow_unknown_type = allow_unknown_type,
    });
    switch (decoded.typ) {
        .known_type => |t| return .{ .obj_type = @tagName(t), .obj_size = decoded.len },
        .unknown_tag => |t| if (allow_unknown_type) {
            return .{ .obj_type = t, .obj_size = decoded.len };
        } else {
            return error.UnknownType;
        },
    }
}

inline fn validateObjectName(hex_string: []const u8) !void {
    _ = try ObjectId.parseHexString(hex_string);
}

test {
    std.testing.refAllDecls(@This());
}
