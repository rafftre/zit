// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");
const zit = @import("zit");
const build_options = @import("build_options");

const Allocator = std.mem.Allocator;
const Repository = zit.Repository;

const cli = @import("root.zig");

/// The ls-files command.
pub const command = cli.Command{
    .run = run,
    .require_repository = true,
    .name = "ls-files",
    .description = "Show information about files in the index and the working tree",
    .usage_text = std.fmt.comptimePrint(
        \\Usage:
        \\  {s} ls-files [-c|--cached] [-o|--others]
        \\               [-d|--deleted] [-m|--modified]
        \\               [-u|--unmerged] [-k|--killed]
        \\               [-s|--stage] [-z]
        \\
        \\Description:
        \\  This command merges the file listing in the index with the actual working directory list,
        \\  and shows different combinations of the two.
        \\
        \\  Several flags can be used to determine which files are shown,
        \\  and each file may be printed multiple times if there are multiple entries in the index
        \\  or if multiple statuses are applicable for the relevant file selection options.
        \\
        \\  The output is a list of file names unless -s is used, in which case it is:
        \\  [<tag> ]<mode> <object> <stage> <file>
        \\
        \\  Pathnames are reported literally. When using -z, they are terminated with a null byte.
        \\
        \\Options:
        \\  -c
        \\  --cached
        \\    Show all files cached in the index, i.e. all tracked files.
        \\    (This is the default if no -c/-o/-s/-d/-m/-u/-k options are specified.)
        \\
        \\  -o
        \\  --others
        \\    Show other (i.e. untracked) files in the output.
        \\  
        \\  -s
        \\  --stage
        \\    Show staged contents' mode bits, object name and stage number.
        \\  
        \\  -d
        \\  --deleted
        \\    Show files with an unstaged deletion.
        \\  
        \\  -m
        \\  --modified
        \\    Show files with an unstaged modification
        \\    (Note that an unstaged deletion also counts as an unstaged modification.)
        \\  
        \\  -u
        \\  --unmerged
        \\    Show information about unmerged files,
        \\    but do not show any other tracked files (forces --stage, overrides --cached).
        \\  
        \\  -k
        \\  --killed
        \\    Show untracked files on the filesystem that need to be removed due to
        \\    conflicts for tracked files to be able to be written to the filesystem.
        \\
        \\  -z
        \\    Terminate line with \0.
        \\
    , .{build_options.app_name}),
};

fn run(allocator: Allocator, repository: ?Repository, args: []const []const u8) !void {
    const out = std.io.getStdOut().writer();

    var show_cached = false;
    var show_others = false;
    var show_stage_info = false;
    var show_deleted = false;
    var show_modified = false;
    var show_unmerged = false;
    var show_killed = false;
    var zero_terminated = false;

    var positional_args = std.ArrayList([]const u8).init(allocator);
    defer positional_args.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--cached")) {
            show_cached = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--others")) {
            show_others = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stage")) {
            show_stage_info = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--deleted")) {
            show_deleted = true;
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--modified")) {
            show_modified = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unmerged")) {
            show_unmerged = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--killed")) {
            show_killed = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            zero_terminated = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            try out.print("Error: Unknown flag '{s}' for '{s}' command.\n", .{ arg, command.name });
            return;
        } else {
            try positional_args.append(arg);
        }
    }

    // forces stage info when unmerged files are requested
    if (show_unmerged) {
        show_stage_info = true;
    }

    // default to cached when other flags are missing
    if (!show_cached and !show_others and !show_stage_info and
        !show_deleted and !show_modified and !show_unmerged and !show_killed)
    {
        show_cached = true;
    }

    const files = try zit.listCached(allocator, repository);
    defer {
        for (files.items) |f| {
            allocator.free(f.path);
        }
        files.deinit();
    }

    for (files.items) |file| {
        if (show_stage_info and file.merge_stage != null) {
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

// fn showUntrakedFiles(allocator: Allocator, repository: anytype, show_others: bool, show_killed: bool) !void {
//     var files = undefined;

//     files = if (show_others) {
//         try zit.listOthers(allocator, repository);
//     } else{
//         try zit.listOthers(allocator, repository);
//     };

// }
