// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

const builtin = @import("builtin");
const std = @import("std");

const Allocator = std.mem.Allocator;

const cli = @import("cli/root.zig");

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

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        try cli.printUsage(std.io.getStdOut().writer());
        return;
    }

    const command_name = args[1];
    const command_args = args[2..];

    try cli.run(gpa, command_name, command_args);
}
