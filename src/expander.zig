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

const testing = std.testing;

fn expectExpanded(input: []const u8, home_path: []const u8, expected: []const []const u8) !void {
    const parsed = try Parser.parse(testing.allocator, input);
    defer parsed.deinit(testing.allocator);

    const expanded = try expand(testing.allocator, home_path, parsed.tokens);
    defer expanded.deinit(testing.allocator);

    try testing.expectEqual(expected.len, expanded.argv.len);

    for (expected, expanded.argv) |expected_arg, actual_arg| {
        try testing.expectEqualSlices(u8, expected_arg, actual_arg);
    }
}

test "expander concatenates token segments into arguments" {
    try expectExpanded(
        "echo for\"~\"sen \"forsen\"\"for\"\"sen\"\"~\"for \"\"",
        "/Users/tester",
        &[_][]const u8{ "echo", "for~sen", "forsenforsen~for", "" },
    );
}

test "expander concatenates escaped parser segments" {
    try expectExpanded(
        "foo\\ bar foo\\\"bar foo\\\\bar",
        "/Users/tester",
        &[_][]const u8{ "foo bar", "foo\"bar", "foo\\bar" },
    );
}

test "expander does not home-expand escaped tildes" {
    try expectExpanded(
        "\\~ \\~/src",
        "/Users/tester",
        &[_][]const u8{ "~", "~/src" },
    );
}

test "expander handles an empty token list" {
    const expanded = try expand(testing.allocator, "/Users/tester", &.{});
    defer expanded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), expanded.argv.len);
}

test "expander handles empty-part tokens from direct API use" {
    const tokens = [_]Parser.Token{
        .{ .parts = &.{} },
    };

    const expanded = try expand(testing.allocator, "/Users/tester", &tokens);
    defer expanded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), expanded.argv.len);
    try testing.expectEqualSlices(u8, "", expanded.argv[0]);
}

test "expander expands home only at the start of an unquoted token" {
    try expectExpanded(
        "~ ~/src ~/\"~\" foo~/bar \"foo\"~/bar \"~\"",
        "/Users/tester",
        &[_][]const u8{
            "/Users/tester",
            "/Users/tester/src",
            "/Users/tester/~",
            "foo~/bar",
            "foo~/bar",
            "~",
        },
    );
}

test "expander expands home before later quoted segments" {
    try expectExpanded(
        "~/\"quoted\"",
        "/Users/tester",
        &[_][]const u8{"/Users/tester/quoted"},
    );
}

test "expander does not expand non-home tilde forms" {
    try expectExpanded(
        "~user ~abc/path",
        "/Users/tester",
        &[_][]const u8{ "~user", "~abc/path" },
    );
}

test "expander replaces home expansions with empty strings when home is unset" {
    try expectExpanded(
        "~ ~/src for\"~\"sen \"~\"",
        "",
        &[_][]const u8{ "", "", "for~sen", "~" },
    );
}

test "expander replaces the whole argument when home is unset before later segments" {
    try expectExpanded(
        "~/\"quoted\"",
        "",
        &[_][]const u8{""},
    );
}

test "expander preserves non-home tokens when home is unset" {
    try expectExpanded(
        "foo bar",
        "",
        &[_][]const u8{ "foo", "bar" },
    );
}

test "expander handles allocation failures without leaks" {
    const parsed = try Parser.parse(testing.allocator, "~ ~/src for\"~\"sen \"\" tail");
    defer parsed.deinit(testing.allocator);

    for (0..32) |fail_index| {
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const result = expand(allocator, "/Users/tester", parsed.tokens);
        if (result) |expanded| {
            expanded.deinit(allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }

        try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
    }
}
