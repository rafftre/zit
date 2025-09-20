// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! Package for the storage of repositories and object databases.
//! Provides utility functions for opening a repository or creating a new one.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Repository = @import("Repository.zig");

pub const FileObjectStore = @import("storage/FileObjectStore.zig");
pub const FileRepository = @import("storage/FileRepository.zig");

/// Opens an existing Git repository.
/// Search the repository on the file-system starting from `start_dir_name`,
/// or from the current directory if not specified.
/// Free with `close`.
pub fn openGitRepository(allocator: Allocator, start_dir_name: ?[]const u8) !Repository {
    var file_repo = try FileRepository.create(allocator, start_dir_name);
    var file_objects = try FileObjectStore.create(allocator, file_repo.git_dir_path);

    var repo = file_repo.interface(file_objects.interface());
    try repo.open();
    return repo;
}

/// Creates an empty Git repository or reinitializes an existing one.
/// The repository will be created on the file-system
/// in the directory `options.name` (or in the current directory when not specified)
/// and with an in initial branch named `options.initial_branch` (or `main` when not specified).
/// Free with `close`.
pub fn createGitRepository(allocator: Allocator, options: FileRepository.SetupOptions) !Repository {
    var file_repo = try FileRepository.setup(allocator, options);
    var file_objects = try FileObjectStore.setup(allocator, file_repo.git_dir_path);

    return file_repo.interface(file_objects.interface());
}

test {
    @import("std").testing.refAllDecls(@This());
}
