// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for the handling of the index file format.

pub const Index = @import("index/index.zig").Index;

pub const MergeStage = @import("index/index_entry.zig").MergeStage;
pub const Flags = @import("index/index_entry.zig").Flags;
pub const ExtendedFlags = @import("index/index_entry.zig").ExtendedFlags;

pub const Extension = @import("index/index_extension.zig").Extension;
pub const ExtensionSignature = @import("index/index_extension.zig").Signature;

pub const SparseDirectory = @import("index/SparseDirectory.zig");
pub const UnknownExtension = @import("index/UnknownExtension.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
