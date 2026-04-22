// SPDX-FileCopyrightText: 2025 Raffaele Tretola <rafftre@hey.com>
// SPDX-License-Identifier: MPL-2.0

//! The interface for a command.

const Command = @This();

const std = @import("std");
const build_options = @import("build_options");
const zit = @import("zit");

const Allocator = std.mem.Allocator;
const Sha1 = zit.hash.Sha1;
const usage_prefix = "  ";

pub const Context = struct {
    allocator: Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    env: std.process.EnvMap,
};

run: *const fn (ctx: Context, args: Arguments) anyerror!void,

name: []const u8,
brief: []const u8,
description: []const u8,
usage_lines: ?[]const u8 = null,
parameters: ?[]const Parameter = null,

/// Returns the Option with a short name matching `name` if present.
pub fn getShortOption(self: *const Command, name: u8) ?Option {
    if (self.parameters) |parameters| {
        for (parameters) |param| {
            switch (param) {
                .option => |option| if (option.isShort(name)) return option,
                else => {},
            }
        }
    }

    return null;
}

/// Returns the Option with a long name matching `name` if present.
pub fn getLongOption(self: *const Command, name: []const u8) ?Option {
    if (self.parameters) |parameters| {
        for (parameters) |param| {
            switch (param) {
                .option => |option| if (option.isLong(name)) return option,
                else => {},
            }
        }
    }

    return null;
}

/// Writes to `out` the help message for the command.
/// Text will be prefixed with `indent` string.
pub fn printUsage(self: *const Command, out: *std.Io.Writer, app_name: []const u8) !void {
    try out.print("Usage:\n", .{});
    if (self.usage_lines) |usage_lines| {
        var it = std.mem.splitSequence(u8, usage_lines, "\n");
        while (it.next()) |line| {
            try out.print("{s}{s} {s} {s}\n", .{ usage_prefix, app_name, self.name, line });
        }
    } else {
        try out.print("{s}{s} {s}\n", .{ usage_prefix, app_name, self.name });
    }

    try out.print("\nDescription:\n", .{});
    try printMultilineText(out, usage_prefix, self.description);

    if (self.parameters) |parameters| {
        try out.print("\nParameters:\n", .{});
        for (parameters) |param| {
            switch (param) {
                .option => |option| {
                    if (option.short) |short_name| {
                        try out.print("{s}-{c}\n", .{ usage_prefix, short_name });
                    }
                    if (option.long) |long_name| {
                        try out.print("{s}--{s}\n", .{ usage_prefix, long_name });
                    }
                    try printMultilineText(out, usage_prefix ** 2, option.description);
                },
                .positional => |positional| {
                    try out.print("{s}<{s}>\n", .{ usage_prefix, positional.name });
                    try printMultilineText(out, usage_prefix ** 2, positional.description);
                },
            }
            try out.print("\n", .{});
        }
    } else {
        // add another newline for Windows
        try out.print("\n", .{});
    }
}

fn printMultilineText(out: *std.Io.Writer, indent: []const u8, description: []const u8) !void {
    var it = std.mem.splitSequence(u8, description, "\n");
    while (it.next()) |line| {
        try out.print("{s}{s}\n", .{ indent, line });
    }
}

/// A command parameter.
pub const Parameter = union(enum) {
    option: Option,
    positional: Positional,
};

/// An option that optionally may require a value.
/// An option can have a short name, a long name, or both.
/// Options that have only the short name (i.e. flags) can be combined.
pub const Option = struct {
    short: ?u8 = null,
    long: ?[]const u8 = null,
    description: []const u8,
    require_value: bool = false,

    /// Checks if this option has a short name equal to `name`.
    fn isShort(self: Option, name: u8) bool {
        if (self.short) |opt_short| {
            return opt_short == name;
        }
        return false;
    }

    /// Checks if this option has a long name equal to `name`.
    fn isLong(self: Option, name: []const u8) bool {
        if (self.long) |opt_long| {
            return std.mem.startsWith(u8, name, opt_long);
        }
        return false;
    }
};

/// A positional argument.
pub const Positional = struct {
    name: []const u8,
    description: []const u8,
};

/// Actual arguments, i.e. parsed parameters.
pub const Arguments = struct {
    /// A map of parsed arguments that uses parameter names as keys.
    ///
    /// Options are stored with their string values.
    ///
    /// Flags, and options that does not require a value, are stored with
    /// the value setted to the string "true".
    ///
    /// Long names are used as keys when available, otherwise short names.
    parsed: std.StringArrayHashMap([]const u8),
    /// Positional parameters, in the same order of the command line.
    positional: std.ArrayList([]const u8) = .empty,

    /// Initializes this struct.
    /// Free with `deinit`.
    pub fn init(allocator: Allocator) Arguments {
        return .{
            .parsed = std.StringArrayHashMap([]const u8).init(allocator),
        };
    }

    /// Frees referenced resources.
    pub fn deinit(self: *Arguments, allocator: Allocator) void {
        // Free all allocated keys
        var it = self.parsed.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }

        self.parsed.deinit();
        self.positional.deinit(allocator);
    }

    /// Parses command-line arguments according to command specification.
    /// Writes error messages to `stderr`.
    pub fn parse(
        self: *Arguments,
        allocator: Allocator,
        stderr: *std.Io.Writer,
        command: Command,
        iter: *std.process.ArgIterator,
    ) !void {
        if (command.parameters) |_| {
            while (iter.next()) |arg| {
                // Check for long options
                if (std.mem.startsWith(u8, arg, "--")) {
                    try self.parseLongArg(allocator, stderr, command, arg, iter);
                }
                // Check for short options
                else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
                    try self.parseShortArgs(allocator, stderr, command, arg, iter);
                }
                // Positional argument
                else {
                    try self.positional.append(allocator, arg);
                }
            }
        }
    }

    // Parses a single long argument (--option, --option=value, or --option="spaced value").
    fn parseLongArg(
        self: *Arguments,
        allocator: Allocator,
        stderr: *std.Io.Writer,
        command: Command,
        arg: []const u8,
        iter: *std.process.ArgIterator,
    ) !void {
        std.log.debug("Parsing long argument '{s}'", .{arg});

        const long_name = arg[2..];

        if (command.getLongOption(long_name)) |option| {
            const opt_long = option.long.?;

            if (!option.require_value) {
                try self.parsed.put(try allocator.dupe(u8, opt_long), "true");
                return;
            }

            if (long_name.len == opt_long.len) {
                // --option format (value should be next arg)

                const next = iter.next() orelse {
                    try stderr.print("'--{s}' requires a value.\n", .{opt_long});
                    return error.MissingOptionValue;
                };

                const value = try stripQuotes(next);
                try self.parsed.put(try allocator.dupe(u8, opt_long), value);

                return;
            } else if (long_name.len > opt_long.len and long_name[opt_long.len] == '=') {
                // --option=value format

                const value = try stripQuotes(long_name[(opt_long.len + 1)..]);
                try self.parsed.put(try allocator.dupe(u8, opt_long), value);

                return;
            }
        }

        try stderr.print("Unknown option '{s}' for '{s}' command.\n", .{ arg, command.name });
        return error.UnknownOption;
    }

    // Parses a list of short arguments (-x or -xyz).
    fn parseShortArgs(
        self: *Arguments,
        allocator: Allocator,
        stderr: *std.Io.Writer,
        command: Command,
        arg: []const u8,
        iter: *std.process.ArgIterator,
    ) !void {
        std.log.debug("Parsing short argument(s) '{s}'", .{arg});

        var char_idx: usize = 1;
        while (char_idx < arg.len) : (char_idx += 1) {
            const flag_char = arg[char_idx];

            if (command.getShortOption(flag_char)) |option| {
                // Use long name as key if available, otherwise use short name
                const key = if (option.long) |long_name| long_name else &[_]u8{option.short.?};

                if (option.require_value) {
                    if (char_idx != 1 or arg.len > 2) {
                        // Option is combined with other flags, which is not allowed
                        try stderr.print(
                            "'-{c}' requires a value and cannot be combined with other flags.\n",
                            .{flag_char},
                        );
                        return error.OptionCannotBeCombined;
                    }

                    const next = iter.next() orelse {
                        try stderr.print("'-{c}' requires a value.\n", .{flag_char});
                        return error.MissingOptionValue;
                    };

                    const value = try stripQuotes(next);
                    try self.parsed.put(try allocator.dupe(u8, key), value);

                    return;
                } else {
                    try self.parsed.put(try allocator.dupe(u8, key), "true");
                    continue;
                }
            }

            try stderr.print("Unknown flag '-{c}' for '{s}' command.\n", .{ flag_char, command.name });
            return error.UnknownFlag;
        }
    }
};

/// Strip surrounding quotes from a string if present.
fn stripQuotes(s: []const u8) ![]const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1..(s.len - 1)];
        }
    }
    return s;
}
