// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! This package is the entry-point for the library.

pub const file = @import("lib/helpers.zig").file;
pub const hash = @import("lib/helpers.zig").hash;

pub const model = @import("lib/model.zig");
pub const index = @import("lib/index.zig");
pub const storage = @import("lib/storage.zig");

pub const LooseObject = @import("lib/LooseObject.zig");
pub const ObjectStore = @import("lib/ObjectStore.zig");
pub const Repository = @import("lib/Repository.zig");

pub const hashObject = @import("lib/object-write.zig").hashObject;

const object_read = @import("lib/object-read.zig");
pub const readObject = object_read.readObject;
pub const readTypeAndSize = object_read.readTypeAndSize;
pub const readEncodedData = object_read.readEncodedData;

const cache = @import("lib/cache.zig");
pub const listFiles = cache.listFiles;
pub const File = cache.File;
pub const ListFilesOptions = cache.ListFilesOptions;

test {
    @import("std").testing.refAllDecls(@This());
}
