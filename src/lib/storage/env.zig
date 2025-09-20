// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! Git environment variables.

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
pub fn get(allocator: Allocator, name: []const u8) !?[]u8 {
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
