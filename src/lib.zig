// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! This package is the entry-point for the library.

pub const file = @import("lib/helpers.zig").file;
pub const hash = @import("lib/helpers.zig").hash;

pub const model = @import("lib/model.zig");
pub const index = @import("lib/index.zig");
pub const storage = @import("lib/storage.zig");

pub const LooseObject = @import("lib/LooseObject.zig");
pub const ObjectStore = @import("lib/object_store.zig").ObjectStore;
pub const Repository = @import("lib/repository.zig").Repository;

const objects = @import("lib/objects.zig");
pub const hashObject = objects.hashObject;
pub const readObject = objects.readObject;
pub const readTypeAndSize = objects.readTypeAndSize;
pub const readEncodedData = objects.readEncodedData;

const files = @import("lib/files.zig");
pub const File = files.File;
pub const ListFilesOptions = files.ListFilesOptions;
pub const listFiles = files.listFiles;

test {
    @import("std").testing.refAllDecls(@This());
}
