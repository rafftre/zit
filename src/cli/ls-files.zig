// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const Command = @import("Command.zig");

const Allocator = std.mem.Allocator;
const GitRepository = zit.storage.GitRepositorySha1;

/// The ls-files command.
pub const command = Command{
    .run = run,
    .name = "ls-files",
    .brief = "Show information about files in the index and the working tree",
    .description =
    \\This command merges the file listing in the index with the actual working
    \\directory list, and shows different combinations of the two.
    \\
    \\Several flags can be used to determine which files are shown, and each
    \\file may be printed multiple times if there are multiple entries in the
    \\index or if multiple statuses are applicable for the relevant file
    \\selection options.
    \\
    \\The output is a list of file names unless -s is used, in which case it is:
    \\[<tag> ]<mode> <object> <stage> <file>
    \\
    \\Pathnames are reported literally. When using -z, they are terminated with
    \\a null byte.
    ,
    .usage_lines =
    \\[-c|--cached] [-o|--others]
    \\[-d|--deleted] [-m|--modified]
    \\[-u|--unmerged] [-k|--killed]
    \\[-s|--stage] [-z]
    ,
    .parameters = &[_]Command.Parameter{
        .{ .option = .{
            .short = 'c',
            .long = "cached",
            .description =
            \\Show all files cached in the index, i.e. all tracked files.
            \\(This is the default if no -c/-o/-s/-d/-m/-u/-k options are specified.)
            ,
        } },
        .{ .option = .{
            .short = 'o',
            .long = "others",
            .description = "Show other (i.e. untracked) files in the output.",
        } },
        .{ .option = .{
            .short = 's',
            .long = "stage",
            .description = "Show staged contents' mode bits, object name and stage number.",
        } },
        .{ .option = .{
            .short = 'd',
            .long = "deleted",
            .description = "Show files with an unstaged deletion.",
        } },
        .{ .option = .{
            .short = 'm',
            .long = "modified",
            .description =
            \\Show files with an unstaged modification.
            \\Note that an unstaged deletion also counts as an unstaged modification.
            ,
        } },
        .{ .option = .{
            .short = 'u',
            .long = "unmerged",
            .description =
            \\Show information about unmerged files, but do not show
            \\any other tracked files (forces --stage, overrides --cached).
            ,
        } },
        .{ .option = .{
            .short = 'k',
            .long = "killed",
            .description =
            \\Show untracked files on the filesystem that need to be removed due to
            \\conflicts for tracked files to be able to be written to the filesystem.
            ,
        } },
        .{ .option = .{
            .short = 'z',
            .description = "Terminate line with \\0.",
        } },
    },
};

fn run(allocator: Allocator, args: Command.Arguments) !void {
    const out = std.io.getStdOut().writer();

    var opts: zit.ListFilesOptions = .{
        .cached = args.parsed.get("cached") != null,
        .others = args.parsed.get("others") != null,
        .stage_info = args.parsed.get("stage") != null,
        .deleted = args.parsed.get("deleted") != null,
        .modified = args.parsed.get("modified") != null,
        .unmerged = args.parsed.get("unmerged") != null,
        .killed = args.parsed.get("killed") != null,
    };
    const zero_terminated = args.parsed.get("z") != null;

    const repository = GitRepository.open(allocator, null) catch |err| switch (err) {
        error.GitDirNotFound => {
            try out.print(
                "Error: Repository not found (cannot find .git in current directory or any of the parents).\n",
                .{},
            );
            return;
        },
        else => return err,
    };
    defer repository.close(allocator);

    const files = try zit.listFiles(allocator, repository.repo, &opts);
    defer {
        for (files.items) |f| {
            allocator.free(f.path);
        }
        files.deinit();
    }

    for (files.items) |file| {
        if (opts.stage_info and file.merge_stage != null) {
            try out.print("{any} {any} {d}\t{s}", .{
                file.mode,
                file.object_id,
                @intFromEnum(file.merge_stage.?),
                file.path,
            });
        } else {
            try out.print("{s}", .{file.path});
        }

        try if (zero_terminated) out.print("\x00", .{}) else out.print("\n", .{});
    }
}
