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
