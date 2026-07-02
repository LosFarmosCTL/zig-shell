const std = @import("std");
const Parser = @import("parser.zig");

pub const ExpandedArgv = struct {
    argv: []const []const u8,

    /// Frees the argv array and each owned argument string.
    pub fn deinit(self: ExpandedArgv, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
    }
};

pub const ExpandedCommand = struct {
    argv: []const []const u8,
    stdout_path: ?[]const u8,

    pub fn deinit(self: ExpandedCommand, allocator: std.mem.Allocator) void {
        for (self.argv) |arg| allocator.free(arg);
        allocator.free(self.argv);
        if (self.stdout_path) |path| allocator.free(path);
    }
};

/// Returns an owned argv.
/// The caller must call `deinit()` on the returned value.
pub fn expand(
    allocator: std.mem.Allocator,
    home_path: []const u8,
    tokens: []const Parser.Token,
) !ExpandedArgv {
    var argv = std.ArrayList([]const u8).empty;
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);
    }

    for (tokens) |token| {
        var arg = std.ArrayList(u8).empty;
        defer arg.deinit(allocator);

        parts: for (token.parts, 0..) |part, i| {
            if (part.type != .default or i != 0) {
                try arg.appendSlice(allocator, part.value);
                continue;
            }

            appendHomeResolved(
                allocator,
                &arg,
                part.value,
                home_path,
            ) catch |err| switch (err) {
                // treat the entire argument as an empty string if HOME is not set
                error.HomeNotSet => {
                    arg.clearAndFree(allocator);
                    break :parts;
                },
                else => return err,
            };
        }

        const owned_arg = try arg.toOwnedSlice(allocator);
        errdefer allocator.free(owned_arg);

        try argv.append(allocator, owned_arg);
    }

    const owned_argv = try argv.toOwnedSlice(allocator);
    argv = .empty;
    return .{ .argv = owned_argv };
}

/// Expands command arguments and removes stdout redirection syntax from argv.
/// The word following `>` or `1>` becomes the output path.
pub fn expandCommand(
    allocator: std.mem.Allocator,
    home_path: []const u8,
    tokens: []const Parser.Token,
) !ExpandedCommand {
    var argv = std.ArrayList([]const u8).empty;
    var stdout_path: ?[]const u8 = null;
    defer {
        for (argv.items) |arg| allocator.free(arg);
        argv.deinit(allocator);

        if (stdout_path) |path| allocator.free(path);
    }

    var i: usize = 0;
    while (i < tokens.len) {
        const token = tokens[i];
        if (token.kind == .stdout_redirect) {
            if (i + 1 >= tokens.len or tokens[i + 1].kind != .word) {
                return error.MissingRedirectTarget;
            }

            const path = try expandToken(allocator, home_path, tokens[i + 1]);
            if (stdout_path) |old_path| allocator.free(old_path);
            stdout_path = path;
            i += 2;
            continue;
        }

        const arg = try expandToken(allocator, home_path, token);
        errdefer allocator.free(arg);
        try argv.append(allocator, arg);
        i += 1;
    }

    const owned_argv = try argv.toOwnedSlice(allocator);
    argv = .empty;
    const owned_path = stdout_path;
    stdout_path = null;
    return .{ .argv = owned_argv, .stdout_path = owned_path };
}

fn expandToken(
    allocator: std.mem.Allocator,
    home_path: []const u8,
    token: Parser.Token,
) ![]const u8 {
    var arg = std.ArrayList(u8).empty;
    defer arg.deinit(allocator);

    parts: for (token.parts, 0..) |part, i| {
        if (part.type != .default or i != 0) {
            try arg.appendSlice(allocator, part.value);
            continue;
        }

        appendHomeResolved(allocator, &arg, part.value, home_path) catch |err| switch (err) {
            error.HomeNotSet => {
                arg.clearAndFree(allocator);
                break :parts;
            },
            else => return err,
        };
    }

    return try arg.toOwnedSlice(allocator);
}

fn appendHomeResolved(
    allocator: std.mem.Allocator,
    arg: *std.ArrayList(u8),
    path: []const u8,
    home_path: []const u8,
) !void {
    if (std.mem.eql(u8, path, "~")) {
        if (home_path.len == 0) return error.HomeNotSet;

        try arg.appendSlice(allocator, home_path);
    } else if (std.mem.startsWith(u8, path, "~/")) {
        if (home_path.len == 0) return error.HomeNotSet;

        try arg.appendSlice(allocator, home_path);
        try arg.appendSlice(allocator, path[1..]);
    } else {
        try arg.appendSlice(allocator, path);
    }
}
