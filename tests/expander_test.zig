const std = @import("std");
const Shell = @import("shell");
const Parser = Shell.Parser;
const Expander = Shell.Expander;

const testing = std.testing;

fn expectExpanded(input: []const u8, home_path: []const u8, expected: []const []const u8) !void {
    const parsed = try Parser.parse(testing.allocator, input);
    defer parsed.deinit(testing.allocator);

    const expanded = try Expander.expand(testing.allocator, home_path, parsed.tokens);
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
    const expanded = try Expander.expand(testing.allocator, "/Users/tester", &.{});
    defer expanded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), expanded.argv.len);
}

test "expander handles empty-part tokens from direct API use" {
    const tokens = [_]Parser.Token{
        .{ .parts = &.{} },
    };

    const expanded = try Expander.expand(testing.allocator, "/Users/tester", &tokens);
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

        const result = Expander.expand(allocator, "/Users/tester", parsed.tokens);
        if (result) |expanded| {
            expanded.deinit(allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }

        try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
    }
}
