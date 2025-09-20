// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! Package for helper, common, or utility functions.

pub const hash = @import("helpers/hash.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
