// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const std = @import("std");

const build_options = @import("build_options");
const zit_exe_rel_path: []const u8 = build_options.zit_path;

// Resolve to an absolute path so it remains valid after chdir to a temp dir.
fn zitExe(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const n = try std.Io.Dir.cwd().realPathFile(io, zit_exe_rel_path, buf);
    return buf[0..n];
}

fn exec(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !std.process.RunResult {
    return std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
}

fn expectExited(expected_code: u8, term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| try std.testing.expectEqual(expected_code, code),
        else => {
            std.debug.print("expected exit {d}, got: {any}\n", .{ expected_code, term });
            return error.UnexpectedTerm;
        },
    }
}

test "init: creates a git-compatible repository" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var zit_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zit = try zitExe(io, &zit_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const r = try exec(allocator, io, &.{ zit, "init" }, tmp_path);
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    try expectExited(0, r.term);

    try tmp.dir.access(io, ".git/objects", .{});
    try tmp.dir.access(io, ".git/refs", .{});
    try tmp.dir.access(io, ".git/HEAD", .{});

    const git_r = try exec(allocator, io, &.{ "git", "status" }, tmp_path);
    defer allocator.free(git_r.stdout);
    defer allocator.free(git_r.stderr);
    try expectExited(0, git_r.term);
}

test "hash-object: output matches git for a plain file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var zit_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zit = try zitExe(io, &zit_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "hello.txt", .data = "hello world\n" });

    const git_r = try exec(allocator, io, &.{ "git", "hash-object", "hello.txt" }, tmp_path);
    defer allocator.free(git_r.stdout);
    defer allocator.free(git_r.stderr);
    try expectExited(0, git_r.term);

    const zit_r = try exec(allocator, io, &.{ zit, "hash-object", "hello.txt" }, tmp_path);
    defer allocator.free(zit_r.stdout);
    defer allocator.free(zit_r.stderr);
    try expectExited(0, zit_r.term);

    try std.testing.expectEqualStrings(git_r.stdout, zit_r.stdout);
}

test "hash-object: output matches git for multiple files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var zit_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zit = try zitExe(io, &zit_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "file a\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.txt", .data = "file b\n" });

    const git_r = try exec(allocator, io, &.{ "git", "hash-object", "a.txt", "b.txt" }, tmp_path);
    defer allocator.free(git_r.stdout);
    defer allocator.free(git_r.stderr);
    try expectExited(0, git_r.term);

    const zit_r = try exec(allocator, io, &.{ zit, "hash-object", "a.txt", "b.txt" }, tmp_path);
    defer allocator.free(zit_r.stdout);
    defer allocator.free(zit_r.stderr);
    try expectExited(0, zit_r.term);

    try std.testing.expectEqualStrings(git_r.stdout, zit_r.stdout);
}

test "hash-object -w: object stored by zit is readable by git cat-file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var zit_buf: [std.fs.max_path_bytes]u8 = undefined;
    const zit = try zitExe(io, &zit_buf);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(tmp_path);

    const git_init = try exec(allocator, io, &.{ "git", "init", tmp_path }, tmp_path);
    defer allocator.free(git_init.stdout);
    defer allocator.free(git_init.stderr);
    try expectExited(0, git_init.term);

    try tmp.dir.writeFile(io, .{ .sub_path = "data.txt", .data = "test content\n" });

    const zit_r = try exec(allocator, io, &.{ zit, "hash-object", "-w", "data.txt" }, tmp_path);
    defer allocator.free(zit_r.stdout);
    defer allocator.free(zit_r.stderr);
    try expectExited(0, zit_r.term);

    const hash = std.mem.trimEnd(u8, zit_r.stdout, "\n");

    const git_r = try exec(allocator, io, &.{ "git", "cat-file", "-t", hash }, tmp_path);
    defer allocator.free(git_r.stdout);
    defer allocator.free(git_r.stderr);
    try expectExited(0, git_r.term);
    try std.testing.expectEqualStrings("blob\n", git_r.stdout);
}
