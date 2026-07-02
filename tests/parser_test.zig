const std = @import("std");
const Parser = @import("shell").Parser;

const testing = std.testing;

const ExpectedSegment = struct {
    value: []const u8,
    type: Parser.Segment.Type,
};

fn expectToken(token: Parser.Token, expected: []const ExpectedSegment) !void {
    try testing.expectEqual(expected.len, token.parts.len);

    for (expected, token.parts) |expected_part, actual_part| {
        try testing.expectEqualSlices(u8, expected_part.value, actual_part.value);
        try testing.expectEqual(expected_part.type, actual_part.type);
    }
}

test "parser ignores empty input and unquoted whitespace" {
    {
        const parsed = try Parser.parse(testing.allocator, "");
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), parsed.tokens.len);
    }

    {
        const parsed = try Parser.parse(testing.allocator, "  \t   \t");
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), parsed.tokens.len);
    }
}

test "parser splits unquoted words on spaces and tabs" {
    const parsed = try Parser.parse(testing.allocator, "echo for\tsen");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "echo", .type = .default }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "for", .type = .default }});
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{.{ .value = "sen", .type = .default }});
}

test "parser ignores repeated leading and trailing whitespace around tokens" {
    const parsed = try Parser.parse(testing.allocator, "  echo   for\t\t sen  ");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "echo", .type = .default }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "for", .type = .default }});
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{.{ .value = "sen", .type = .default }});
}

test "parser preserves whitespace inside quotes" {
    const parsed = try Parser.parse(testing.allocator, "echo \"for sen\" 'for\tsen'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "echo", .type = .default }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "for sen", .type = .quoted }});
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{.{ .value = "for\tsen", .type = .quoted }});
}

test "parser treats opposite quote characters as literals" {
    const parsed = try Parser.parse(testing.allocator, "\"it's fine\" 'say \"hi\"'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "it's fine", .type = .quoted }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "say \"hi\"", .type = .quoted }});
}

test "parser handles escaped characters outside quotes" {
    const parsed = try Parser.parse(testing.allocator, "foo\\ bar foo\\\"bar foo\\\\bar \\~ \\*");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .default },
        .{ .value = " ", .type = .escaped },
        .{ .value = "bar", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .default },
        .{ .value = "\"", .type = .escaped },
        .{ .value = "bar", .type = .default },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .default },
        .{ .value = "\\", .type = .escaped },
        .{ .value = "bar", .type = .default },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{.{ .value = "~", .type = .escaped }});
    try expectToken(parsed.tokens[4], &[_]ExpectedSegment{.{ .value = "*", .type = .escaped }});
}

test "parser preserves backslashes inside single quotes" {
    const parsed = try Parser.parse(testing.allocator, "'a\\b \"x\"'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "a\\b \"x\"", .type = .quoted }});
}

test "parser handles escaped quote and backslash inside double quotes" {
    const parsed = try Parser.parse(testing.allocator, "\"foo\\\"bar\" \"foo\\\\bar\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .quoted },
        .{ .value = "\"", .type = .quoted },
        .{ .value = "bar", .type = .quoted },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .quoted },
        .{ .value = "\\", .type = .quoted },
        .{ .value = "bar", .type = .quoted },
    });
}

test "parser preserves non-special backslash escapes inside double quotes" {
    const parsed = try Parser.parse(testing.allocator, "\"foo\\a\" \"foo\\ bar\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .quoted },
        .{ .value = "\\a", .type = .quoted },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "foo", .type = .quoted },
        .{ .value = "\\ bar", .type = .quoted },
    });
}

test "parser preserves mixed quoted and unquoted segments in one token" {
    const parsed = try Parser.parse(
        testing.allocator,
        "some/\"*\"/path for\"~\"sen \"~\" ~/\"~\" \"forsen\"\"for\"\"sen\"\"~\"for",
    );
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "some/", .type = .default },
        .{ .value = "*", .type = .quoted },
        .{ .value = "/path", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .type = .default },
        .{ .value = "~", .type = .quoted },
        .{ .value = "sen", .type = .default },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{.{ .value = "~", .type = .quoted }});
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "~/", .type = .default },
        .{ .value = "~", .type = .quoted },
    });
    try expectToken(parsed.tokens[4], &[_]ExpectedSegment{
        .{ .value = "forsen", .type = .quoted },
        .{ .value = "for", .type = .quoted },
        .{ .value = "sen", .type = .quoted },
        .{ .value = "~", .type = .quoted },
        .{ .value = "for", .type = .default },
    });
}

test "parser preserves empty quoted arguments" {
    const parsed = try Parser.parse(testing.allocator, "echo \"\" '' a\"\"b");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "echo", .type = .default }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "", .type = .quoted }});
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{.{ .value = "", .type = .quoted }});
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "a", .type = .default },
        .{ .value = "", .type = .quoted },
        .{ .value = "b", .type = .default },
    });
}

test "parser preserves standalone and adjacent empty quoted arguments" {
    const parsed = try Parser.parse(testing.allocator, "\"\" '' \"\"\"\" ''\"\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{.{ .value = "", .type = .quoted }});
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{.{ .value = "", .type = .quoted }});
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
        .{ .value = "", .type = .quoted },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
        .{ .value = "", .type = .quoted },
    });
}

test "parser preserves simple quoted segment boundaries" {
    const parsed = try Parser.parse(testing.allocator, "\"a\"b a\"b\" \"a\"\"b\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "a", .type = .quoted },
        .{ .value = "b", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "a", .type = .default },
        .{ .value = "b", .type = .quoted },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "a", .type = .quoted },
        .{ .value = "b", .type = .quoted },
    });
}

test "parser identifies stdout redirects without requiring spaces" {
    const parsed = try Parser.parse(testing.allocator, "echo hello>output.txt 1>second.txt");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), parsed.tokens.len);
    try testing.expectEqual(Parser.Token.Kind.word, parsed.tokens[0].kind);
    try testing.expectEqual(Parser.Token.Kind.word, parsed.tokens[1].kind);
    try testing.expectEqual(Parser.Token.Kind.stdout_redirect, parsed.tokens[2].kind);
    try testing.expectEqual(Parser.Token.Kind.word, parsed.tokens[3].kind);
    try testing.expectEqual(Parser.Token.Kind.stdout_redirect, parsed.tokens[4].kind);
    try testing.expectEqual(Parser.Token.Kind.word, parsed.tokens[5].kind);
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{.{ .value = "output.txt", .type = .default }});
    try expectToken(parsed.tokens[5], &[_]ExpectedSegment{.{ .value = "second.txt", .type = .default }});
}

test "parser leaves quoted and escaped redirect characters as words" {
    const parsed = try Parser.parse(testing.allocator, "echo '>' \"1>\" \\>");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    for (parsed.tokens) |token| try testing.expectEqual(Parser.Token.Kind.word, token.kind);
}

test "parser identifies stderr redirects" {
    const parsed = try Parser.parse(testing.allocator, "cat existing missing 2>errors.txt");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), parsed.tokens.len);
    try testing.expectEqual(Parser.Token.Kind.stderr_redirect, parsed.tokens[3].kind);
    try expectToken(parsed.tokens[4], &[_]ExpectedSegment{.{ .value = "errors.txt", .type = .default }});
}

test "parser rejects unclosed quotes" {
    try testing.expectError(error.UnclosedQuote, Parser.parse(testing.allocator, "echo \"unterminated"));
    try testing.expectError(error.UnclosedQuote, Parser.parse(testing.allocator, "echo 'unterminated"));
}

test "parser rejects trailing escapes" {
    try testing.expectError(error.UnclosedEscape, Parser.parse(testing.allocator, "foo\\"));
    try testing.expectError(error.UnclosedEscape, Parser.parse(testing.allocator, "\\"));
}

test "parser handles allocation failures without leaks" {
    for (0..32) |fail_index| {
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const result = Parser.parse(allocator, "echo \\\"for\\\" sen \"\" tail foo\\ bar \"a\\\"b\"");
        if (result) |parsed| {
            parsed.deinit(allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }

        try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
    }
}
