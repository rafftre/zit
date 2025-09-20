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
openFn: *const fn (ptr: *anyopaque) anyerror!void,

/// Frees up used resources.
closeFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,

/// Returns the name of the repository.
/// It can be a path, an URL or something else - the implementation determines that.
nameFn: *const fn (ptr: *anyopaque) ?[]const u8,

/// Interface function wrapper.
/// Propagates to the object store.
pub fn open(r: Repository) !void {
    try r.objects.open();
    try r.openFn(r.ptr);
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
