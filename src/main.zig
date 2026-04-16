// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        if (builtin.target.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug => .{ debug_allocator.allocator(), true },
            .ReleaseFast,
            .ReleaseSafe,
            .ReleaseSmall,
            => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var out_buf: [1024]u8 = undefined;
    const stdout_file: std.fs.File = .stdout();
    var stdout_w = stdout_file.writerStreaming(&out_buf);
    const stdout = &stdout_w.interface;

    var err_buf: [1024]u8 = undefined;
    const stderr_file: std.fs.File = .stderr();
    var stderr_w = stderr_file.writerStreaming(&err_buf);
    const stderr = &stderr_w.interface;

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        try cli.printGlobalUsage(stderr);
        try stderr.flush();
        return;
    }

    const command_name = args[1];
    const command_args = args[2..];

    cli.dispatchCommand(gpa, stdout, stderr, command_name, command_args) catch |err| {
        std.log.debug("Failed to run command: {s}", .{@errorName(err)});
        cli.fail(stdout, stderr);
    };

    try stdout.flush();
    try stderr.flush();
}
