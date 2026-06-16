const std = @import("std");

pub const Segment = struct {
    /// Borrows from the input passed to `parse`.
    value: []const u8,
    is_quoted: bool,
};

pub const Token = struct {
    parts: []const Segment,
};

pub const ParsedLine = struct {
    tokens: []const Token,

    /// Frees the owned token and segment arrays.
    /// Segment values themselves borrow from the original input.
    pub fn deinit(self: ParsedLine, allocator: std.mem.Allocator) void {
        for (self.tokens) |token| allocator.free(token.parts);

        allocator.free(self.tokens);
    }
};

const State = enum {
    default,
    quotedSingle,
    quotedDouble,
};

const Parser = struct {
    allocator: std.mem.Allocator,

    input: []const u8,
    state: State = .default,

    i: usize = 0,
    segment_start: usize = 0,

    tokens: std.ArrayList(Token) = .empty,
    segments: std.ArrayList(Segment) = .empty,

    fn deinit(self: *Parser) void {
        for (self.tokens.items) |token| self.allocator.free(token.parts);

        self.tokens.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    fn parse(self: *Parser) !ParsedLine {
        while (self.i < self.input.len) : (self.i += 1) {
            const current_char = self.input[self.i];
            switch (self.state) {
                .default => try self.handleDefault(current_char),
                .quotedSingle => try self.handleQuoted('\'', current_char),
                .quotedDouble => try self.handleQuoted('"', current_char),
            }
        }

        if (self.state != .default) return error.UnclosedQuote;

        try self.appendToken();

        const tokens = try self.tokens.toOwnedSlice(self.allocator);
        self.tokens = .empty;
        return .{ .tokens = tokens };
    }

    fn handleDefault(self: *Parser, current_char: u8) !void {
        switch (current_char) {
            else => return,
            ' ', '\t' => {
                return try self.appendToken();
            },

            '\'' => self.state = .quotedSingle,
            '"' => self.state = .quotedDouble,
        }

        try self.appendSegment(false);
    }

    fn handleQuoted(self: *Parser, quote_char: u8, current_char: u8) !void {
        if (current_char == quote_char) {
            try self.appendSegment(true);
            self.state = .default;
        }
    }

    fn appendSegment(self: *Parser, is_quoted: bool) !void {
        const segment_start = self.segment_start;
        self.segment_start = self.i + 1;

        if (segment_start > self.i) return;
        if (!is_quoted and segment_start == self.i) return;

        const segment = self.input[segment_start..self.i];
        try self.segments.append(self.allocator, .{
            .value = segment,
            .is_quoted = is_quoted,
        });
    }

    fn appendToken(self: *Parser) !void {
        try self.appendSegment(false);

        if (self.segments.items.len == 0) return;

        const parts = try self.segments.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(parts);

        try self.tokens.append(self.allocator, Token{ .parts = parts });
    }
};

/// Returns an owned parse result.
/// The caller must call `deinit()` on the returned value.
/// Segment values borrow from `input`, so `input` must remain alive while
/// the parsed result is in use.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) !ParsedLine {
    var parser = Parser{
        .allocator = allocator,
        .input = input,
    };
    defer parser.deinit();

    return try parser.parse();
}

const testing = std.testing;

const ExpectedSegment = struct {
    value: []const u8,
    is_quoted: bool,
};

fn expectToken(token: Token, expected: []const ExpectedSegment) !void {
    try testing.expectEqual(expected.len, token.parts.len);

    for (expected, token.parts) |expected_part, actual_part| {
        try testing.expectEqualSlices(u8, expected_part.value, actual_part.value);
        try testing.expectEqual(expected_part.is_quoted, actual_part.is_quoted);
    }
}

test "parser ignores empty input and unquoted whitespace" {
    {
        const parsed = try parse(testing.allocator, "");
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), parsed.tokens.len);
    }

    {
        const parsed = try parse(testing.allocator, "  \t   \t");
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), parsed.tokens.len);
    }
}

test "parser splits unquoted words on spaces and tabs" {
    const parsed = try parse(testing.allocator, "echo for\tsen");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .is_quoted = false },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "sen", .is_quoted = false },
    });
}

test "parser ignores repeated leading and trailing whitespace around tokens" {
    const parsed = try parse(testing.allocator, "  echo   for\t\t sen  ");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .is_quoted = false },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "sen", .is_quoted = false },
    });
}

test "parser preserves whitespace inside quotes" {
    const parsed = try parse(testing.allocator, "echo \"for sen\" 'for\tsen'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for sen", .is_quoted = true },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "for\tsen", .is_quoted = true },
    });
}

test "parser treats opposite quote characters as literals" {
    const parsed = try parse(testing.allocator, "\"it's fine\" 'say \"hi\"'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "it's fine", .is_quoted = true },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "say \"hi\"", .is_quoted = true },
    });
}

test "parser preserves mixed quoted and unquoted segments in one token" {
    const parsed = try parse(
        testing.allocator,
        "some/\"*\"/path for\"~\"sen \"~\" ~/\"~\" \"forsen\"\"for\"\"sen\"\"~\"for",
    );
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 5), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "some/", .is_quoted = false },
        .{ .value = "*", .is_quoted = true },
        .{ .value = "/path", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .is_quoted = false },
        .{ .value = "~", .is_quoted = true },
        .{ .value = "sen", .is_quoted = false },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "~", .is_quoted = true },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "~/", .is_quoted = false },
        .{ .value = "~", .is_quoted = true },
    });
    try expectToken(parsed.tokens[4], &[_]ExpectedSegment{
        .{ .value = "forsen", .is_quoted = true },
        .{ .value = "for", .is_quoted = true },
        .{ .value = "sen", .is_quoted = true },
        .{ .value = "~", .is_quoted = true },
        .{ .value = "for", .is_quoted = false },
    });
}

test "parser preserves empty quoted arguments" {
    const parsed = try parse(testing.allocator, "echo \"\" '' a\"\"b");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "a", .is_quoted = false },
        .{ .value = "", .is_quoted = true },
        .{ .value = "b", .is_quoted = false },
    });
}

test "parser preserves standalone and adjacent empty quoted arguments" {
    const parsed = try parse(testing.allocator, "\"\" '' \"\"\"\" ''\"\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
        .{ .value = "", .is_quoted = true },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "", .is_quoted = true },
        .{ .value = "", .is_quoted = true },
    });
}

test "parser preserves simple quoted segment boundaries" {
    const parsed = try parse(testing.allocator, "\"a\"b a\"b\" \"a\"\"b\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "a", .is_quoted = true },
        .{ .value = "b", .is_quoted = false },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "a", .is_quoted = false },
        .{ .value = "b", .is_quoted = true },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "a", .is_quoted = true },
        .{ .value = "b", .is_quoted = true },
    });
}

test "parser rejects unclosed quotes" {
    try testing.expectError(
        error.UnclosedQuote,
        parse(testing.allocator, "echo \"unterminated"),
    );

    try testing.expectError(
        error.UnclosedQuote,
        parse(testing.allocator, "echo 'unterminated"),
    );
}

test "parser handles allocation failures without leaks" {
    for (0..32) |fail_index| {
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const result = parse(allocator, "echo \"for\" sen \"\" tail");
        if (result) |parsed| {
            parsed.deinit(allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }

        try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
    }
}
