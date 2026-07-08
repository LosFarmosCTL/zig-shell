const std = @import("std");

const builtin_commands = [_][]const u8{ "echo", "exit" };

pub const Completion = union(enum) {
    none,
    match: []const u8,
    multiple: []const []const u8,

    pub fn deinit(self: Completion, allocator: std.mem.Allocator) void {
        switch (self) {
            .none => {},
            .match => |command| allocator.free(command),
            .multiple => |commands| {
                for (commands) |command| allocator.free(command);
                allocator.free(commands);
            },
        }
    }
};

pub fn longestCommonPrefix(matches: []const []const u8) []const u8 {
    if (matches.len == 0) return "";

    const first = matches[0];
    var prefix_len = first.len;
    for (matches[1..]) |command| {
        prefix_len = @min(prefix_len, command.len);
        var i: usize = 0;
        while (i < prefix_len and first[i] == command[i]) : (i += 1) {}
        prefix_len = i;
    }
    return first[0..prefix_len];
}

/// Finds executable commands matching `prefix`. Returned strings and slices
/// are owned by `allocator`.
pub fn find(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    prefix: []const u8,
) !Completion {
    if (prefix.len == 0) return .none;

    var matches = std.ArrayList([]const u8).empty;
    defer {
        for (matches.items) |command| allocator.free(command);
        matches.deinit(allocator);
    }

    for (builtin_commands) |command| {
        if (std.mem.startsWith(u8, command, prefix)) {
            try addMatch(allocator, &matches, command);
        }
    }

    var paths = std.mem.splitScalar(u8, path, ':');
    while (paths.next()) |path_entry| {
        var dir = openPathDir(io, path_entry) orelse continue;
        defer dir.close(io);

        var iterator = dir.iterateAssumeFirstIteration();
        while (iterator.next(io) catch break) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

            const stat = dir.statFile(io, entry.name, .{
                .follow_symlinks = true,
            }) catch continue;
            if (stat.kind != .file) continue;

            dir.access(io, entry.name, .{
                .execute = true,
                .follow_symlinks = true,
            }) catch continue;

            try addMatch(allocator, &matches, entry.name);
        }
    }

    if (matches.items.len == 0) return .none;
    if (matches.items.len == 1) {
        const command = matches.items[0];
        matches.deinit(allocator);
        matches = .empty;
        return .{ .match = command };
    }

    std.mem.sort([]const u8, matches.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    const owned_matches = try matches.toOwnedSlice(allocator);
    matches = .empty;
    return .{ .multiple = owned_matches };
}

fn openPathDir(io: std.Io, path: []const u8) ?std.Io.Dir {
    const options: std.Io.Dir.OpenOptions = .{ .iterate = true };
    if (path.len == 0) return std.Io.Dir.cwd().openDir(io, ".", options) catch null;
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, options) catch null;
    }
    return std.Io.Dir.cwd().openDir(io, path, options) catch null;
}

fn addMatch(
    allocator: std.mem.Allocator,
    matches: *std.ArrayList([]const u8),
    candidate: []const u8,
) !void {
    for (matches.items) |existing| {
        if (std.mem.eql(u8, existing, candidate)) return;
    }

    const owned_candidate = try allocator.dupe(u8, candidate);
    errdefer allocator.free(owned_candidate);
    try matches.append(allocator, owned_candidate);
}

pub fn hasMatchingBuiltin(prefix: []const u8) bool {
    for (builtin_commands) |command| {
        if (std.mem.startsWith(u8, command, prefix)) return true;
    }
    return false;
}

/// Returns the only builtin command beginning with `prefix`, or null when
/// there is no match or the prefix is ambiguous.
pub fn builtinForPrefix(prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return null;

    var match: ?[]const u8 = null;
    for (builtin_commands) |command| {
        if (!std.mem.startsWith(u8, command, prefix)) continue;
        if (match != null) return null;
        match = command;
    }
    return match;
}
