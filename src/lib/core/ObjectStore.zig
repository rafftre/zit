// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! The interface for an object store.

const Store = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The pointer to the instance.
ptr: *anyopaque,

/// Opens an existing store.
/// Use `closeFn` to free up used resources.
openFn: *const fn (ptr: *anyopaque) anyerror!void,

/// Frees up used resources.
closeFn: *const fn (ptr: *anyopaque, allocator: Allocator) void,

/// Returns the raw content of an object in the store.
/// Returned memory is owned by the caller.
readFn: *const fn (ptr: *anyopaque, allocator: Allocator, name: []const u8) anyerror![]u8,

/// Writes the raw content of an object to the store.
writeFn: *const fn (ptr: *anyopaque, allocator: Allocator, name: []const u8, bytes: []u8) anyerror!void,

/// Interface function wrapper.
pub fn open(s: Store) !void {
    try s.openFn(s.ptr);
}

/// Interface function wrapper.
pub fn close(s: Store, allocator: Allocator) void {
    s.closeFn(s.ptr, allocator);
}

/// Interface function wrapper.
pub fn read(s: Store, allocator: Allocator, name: []const u8) ![]u8 {
    return try s.readFn(s.ptr, allocator, name);
}

/// Interface function wrapper.
pub fn write(s: Store, allocator: Allocator, name: []const u8, bytes: []u8) !void {
    try s.writeFn(s.ptr, allocator, name, bytes);
}
