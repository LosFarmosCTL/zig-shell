const std = @import("std");

const commands = [_][]const u8{ "echo", "exit" };

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
