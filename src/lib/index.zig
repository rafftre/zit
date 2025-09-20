// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: LGPL-3.0-or-later

//! Package for the handling of the index file format.

pub const FileMode = @import("index/file_mode.zig").FileMode;

pub const Index = @import("index/index.zig").Index;
pub const IndexSha1 = @import("index/index.zig").IndexSha1;
pub const IndexSha256 = @import("index/index.zig").IndexSha256;

pub const Entry = @import("index/index_entry.zig").Entry;
pub const EntrySha1 = @import("index/index_entry.zig").EntrySha1;
pub const EntrySha256 = @import("index/index_entry.zig").EntrySha256;
pub const Flags = @import("index/index_entry.zig").Flags;
pub const MergeStage = @import("index/index_entry.zig").MergeStage;
pub const ExtendedFlags = @import("index/index_entry.zig").ExtendedFlags;

pub const Extension = @import("index/index_extension.zig").Extension;
pub const ExtensionSignature = @import("index/index_extension.zig").Signature;

pub const SparseDirectory = @import("index/SparseDirectory.zig");
pub const UnknownExtension = @import("index/UnknownExtension.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
