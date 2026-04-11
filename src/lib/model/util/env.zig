// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Environment variables utilities.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GIT_DIR = "GIT_DIR";
pub const GIT_OBJECT_DIR = "GIT_OBJECT_DIRECTORY";

pub const HOME = "HOME";
pub const HOME_WIN = "USERPROFILE";

/// Get the value of the environment variable with `name`.
/// Returns `null` if the variable does not exist.
/// Returns `error.EmptyValue` if the variable exists, but has no content.
/// Caller owns the returned memory.
pub fn getEnv(allocator: Allocator, name: []const u8) !?[]u8 {
    if (std.process.getEnvVarOwned(allocator, name)) |val| {
        std.log.debug("Found environment {s}={s}", .{ name, val });

        if (val.len > 0) {
            return val;
        }

        allocator.free(val);
        return error.EmptyValue;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    }
}

/// Returns the user home directory based on the environment variables
pub fn getHomeDir(allocator: Allocator) ![]u8 {
    const home_env = comptime blk: {
        const os_tag = @import("builtin").os.tag;
        break :blk switch (os_tag) {
            // Note: in some versions of Windows HOME variable may be defined,
            // but it contains something as "/c/Users/name" and this may cause a
            // failure while comparing its content to paths retrived from opened
            // directories (that are in the form "C:\Users\name")
            .windows => HOME_WIN,
            else => HOME,
        };
    };

    return try getEnv(allocator, home_env) orelse allocator.dupe(u8, "");
}
