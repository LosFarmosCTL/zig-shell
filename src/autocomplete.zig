const std = @import("std");

const commands = [_][]const u8{ "echo", "exit" };

pub const Completion = union(enum) {
    none,
    ambiguous,
    match: []const u8,
};

/// Finds one unique executable command matching `prefix`. The matched string
/// is owned by `allocator`.
pub fn find(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    prefix: []const u8,
) !Completion {
    if (prefix.len == 0) return .ambiguous;

    var match: ?[]u8 = null;
    errdefer if (match) |value| allocator.free(value);

    for (commands) |command| {
        if (std.mem.startsWith(u8, command, prefix)) {
            if (try addMatch(allocator, &match, command)) {
                allocator.free(match.?);
                match = null;
                return .ambiguous;
            }
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

            if (try addMatch(allocator, &match, entry.name)) {
                allocator.free(match.?);
                match = null;
                return .ambiguous;
            }
        }
    }

    return if (match) |value| .{ .match = value } else .none;
}

fn openPathDir(io: std.Io, path: []const u8) ?std.Io.Dir {
    const options: std.Io.Dir.OpenOptions = .{ .iterate = true };
    if (path.len == 0) return std.Io.Dir.cwd().openDir(io, ".", options) catch null;
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, options) catch null;
    }
    return std.Io.Dir.cwd().openDir(io, path, options) catch null;
}

/// Returns true when `candidate` makes the result ambiguous.
fn addMatch(
    allocator: std.mem.Allocator,
    match: *?[]u8,
    candidate: []const u8,
) !bool {
    if (match.*) |existing| {
        return !std.mem.eql(u8, existing, candidate);
    }
    match.* = try allocator.dupe(u8, candidate);
    return false;
}

pub fn hasMatchingBuiltin(prefix: []const u8) bool {
    for (commands) |command| {
        if (std.mem.startsWith(u8, command, prefix)) return true;
    }
    return false;
}

/// Returns the only builtin command beginning with `prefix`, or null when
/// there is no match or the prefix is ambiguous.
pub fn builtinForPrefix(prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return null;

    var match: ?[]const u8 = null;
    for (commands) |command| {
        if (!std.mem.startsWith(u8, command, prefix)) continue;
        if (match != null) return null;
        match = command;
    }
    return match;
}
