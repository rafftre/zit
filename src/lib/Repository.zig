// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! The interface for a repository.

const Repository = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const ObjectStore = @import("ObjectStore.zig");

/// The pointer to the instance.
ptr: *anyopaque,
/// The object store.
objects: ObjectStore,

/// Opens an existing repository.
/// Use `closeFn` to free up used resources.
openFn: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!void,

/// Frees up used resources.
closeFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,

/// Returns the name of the repository.
/// It can be a path, an URL or something else - the implementation determines that.
nameFn: *const fn (ptr: *anyopaque) ?[]const u8,

/// Returns the path of the worktree, if available.
worktreeFn: *const fn (ptr: *anyopaque) ?[]const u8,

/// Returns the content of the index file.
/// Caller owns the returned memory.
readIndexFn: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]u8,

/// Interface function wrapper.
/// Propagates to the object store.
pub fn open(r: Repository, allocator: Allocator) !void {
    try r.objects.open();
    try r.openFn(r.ptr, allocator);
}

/// Interface function wrapper.
/// Propagates to the object store.
pub fn close(r: Repository, allocator: Allocator) void {
    r.objects.close(allocator);
    r.closeFn(r.ptr, allocator);
}

/// Interface function wrapper.
pub fn name(r: Repository) ?[]const u8 {
    return r.nameFn(r.ptr);
}

/// Interface function wrapper.
pub fn worktree(r: Repository) ?[]const u8 {
    return r.worktreeFn(r.ptr);
}

/// Interface function wrapper.
pub fn readIndex(r: Repository, allocator: Allocator) ![]u8 {
    return r.readIndexFn(r.ptr, allocator);
}
