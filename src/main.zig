// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const builtin = @import("builtin");
const std = @import("std");
const zit = @import("zit");

const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [1024]u8 = undefined;
    const stdout_file: std.Io.File = .stdout();
    var stdout_w = stdout_file.writerStreaming(io, &out_buf);
    const stdout = &stdout_w.interface;

    var err_buf: [1024]u8 = undefined;
    const stderr_file: std.Io.File = .stderr();
    var stderr_w = stderr_file.writerStreaming(io, &err_buf);
    const stderr = &stderr_w.interface;

    var arg_iter = try std.process.Args.iterateAllocator(
        init.minimal.args,
        init.arena.allocator(),
    );
    defer arg_iter.deinit();

    _ = arg_iter.next(); // skip program name

    const command_name = arg_iter.next() orelse {
        try cli.printGlobalUsage(stderr);
        try stderr.flush();
        return;
    };

    cli.dispatchCommand(
        io,
        gpa,
        stdout,
        stderr,
        command_name,
        &arg_iter,
        init.environ_map,
    ) catch |err| {
        std.log.debug("Failed to run command: {s}", .{@errorName(err)});
        cli.fail(stdout, stderr);
    };

    try stdout.flush();
    try stderr.flush();
}
