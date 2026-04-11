// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! This package is the entry-point for the exported library.

// Utilities

pub const fs = @import("lib/model/util/fs.zig");
pub const hash = @import("lib/model/util/hash.zig");

// Data Model

pub const Identity = @import("lib/model/signature.zig").Identity;
pub const Signature = @import("lib/model/signature.zig").Signature;
pub const Time = @import("lib/model/signature.zig").Time;

pub const Blob = @import("lib/model/blob.zig").Blob;
pub const Tree = @import("lib/model/tree.zig").Tree;
pub const Commit = @import("lib/model/commit.zig").Commit;
pub const Tag = @import("lib/model/tag.zig").Tag;

// Index

pub const SparseDirectory = @import("lib/model/index.zig").SparseDirectory;
pub const UnknownExtension = @import("lib/model/index.zig").UnknownExtension;

// Repository

pub const Repository = @import("lib/repository.zig").Repository;
pub const SetupOptions = @import("lib/repository.zig").SetupOptions;

// Business Logic

pub const file = @import("lib/file.zig");
pub const object = @import("lib/object.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
