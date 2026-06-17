const std = @import("std");

pub const Segment = struct {
    /// Borrows from the input passed to `parse`.
    value: []const u8,
    type: Type,

    pub const Type = enum {
        default,
        escaped,
        quoted,
    };
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

const State = union(enum) {
    default: usize,
    quotedSingle: usize,
    quotedDouble: struct {
        start: usize,
        escaped: bool,
    },
    escaped,
};

const Parser = struct {
    allocator: std.mem.Allocator,

    input: []const u8,
    state: State = .{ .default = 0 },

    i: usize = 0,

    tokens: std.ArrayList(Token) = .empty,
    segments: std.ArrayList(Segment) = .empty,

    fn deinit(self: *Parser) void {
        for (self.tokens.items) |token| self.allocator.free(token.parts);

        self.tokens.deinit(self.allocator);
        self.segments.deinit(self.allocator);
    }

    fn parse(self: *Parser) !ParsedLine {
        while (self.i < self.input.len) : (self.i += 1) {
            switch (self.state) {
                .default => |start_pos| try self.handleDefault(start_pos),
                .quotedSingle => |start_pos| try self.handleSingleQuoted(start_pos),
                .quotedDouble => |state| try self.handleDoubleQuoted(state.start, state.escaped),
                .escaped => {
                    try self.appendSegment(self.i, self.i + 1, .escaped);
                    self.state = .{ .default = self.i + 1 };
                },
            }
        }

        switch (self.state) {
            .quotedSingle, .quotedDouble => return error.UnclosedQuote,
            .escaped => return error.UnclosedEscape,
            else => {},
        }

        try self.appendSegment(self.state.default, self.input.len, .default);
        try self.appendToken();

        const tokens = try self.tokens.toOwnedSlice(self.allocator);
        self.tokens = .empty;
        return .{ .tokens = tokens };
    }

    fn handleDefault(self: *Parser, start_pos: usize) !void {
        switch (self.input[self.i]) {
            else => return,

            ' ', '\t' => {
                try self.appendSegment(start_pos, self.i, .default);
                self.state = .{ .default = self.i + 1 };

                return try self.appendToken();
            },

            '\'' => self.state = .{ .quotedSingle = self.i + 1 },
            '"' => self.state = .{ .quotedDouble = .{ .start = self.i + 1, .escaped = false } },

            '\\' => self.state = .escaped,
        }

        try self.appendSegment(start_pos, self.i, .default);
    }

    fn handleSingleQuoted(self: *Parser, start_pos: usize) !void {
        if (self.input[self.i] == '\'') {
            try self.appendSegment(start_pos, self.i, .quoted);
            self.state = .{ .default = self.i + 1 };
        }
    }

    fn handleDoubleQuoted(self: *Parser, start_pos: usize, escaped: bool) !void {
        if (escaped) {
            switch (self.input[self.i]) {
                '"' => {
                    try self.appendSegment(self.i, self.i + 1, .quoted);
                    self.state = .{ .quotedDouble = .{ .start = self.i + 1, .escaped = false } };
                },
                '\\' => {
                    try self.appendSegment(self.i, self.i + 1, .quoted);
                    self.state = .{ .quotedDouble = .{ .start = self.i + 1, .escaped = false } };
                },
                else => {
                    self.state = .{ .quotedDouble = .{ .start = start_pos, .escaped = false } };
                },
            }
        } else {
            switch (self.input[self.i]) {
                '"' => {
                    try self.appendSegment(start_pos, self.i, .quoted);
                    self.state = .{ .default = self.i + 1 };
                },
                '\\' => {
                    try self.appendSegment(start_pos, self.i, .quoted);
                    self.state = .{ .quotedDouble = .{ .start = self.i, .escaped = true } };
                },
                else => {},
            }
        }
    }

    fn appendSegment(self: *Parser, from: usize, to: usize, segment_type: Segment.Type) !void {
        if (from > to) return;
        if (from == to and segment_type == .default) return;

        const segment = self.input[from..to];
        try self.segments.append(self.allocator, .{
            .value = segment,
            .type = segment_type,
        });
    }

    fn appendToken(self: *Parser) !void {
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
    type: Segment.Type,
};

fn expectToken(token: Token, expected: []const ExpectedSegment) !void {
    try testing.expectEqual(expected.len, token.parts.len);

    for (expected, token.parts) |expected_part, actual_part| {
        try testing.expectEqualSlices(u8, expected_part.value, actual_part.value);
        try testing.expectEqual(expected_part.type, actual_part.type);
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
        .{ .value = "echo", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .type = .default },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "sen", .type = .default },
    });
}

test "parser ignores repeated leading and trailing whitespace around tokens" {
    const parsed = try parse(testing.allocator, "  echo   for\t\t sen  ");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for", .type = .default },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "sen", .type = .default },
    });
}

test "parser preserves whitespace inside quotes" {
    const parsed = try parse(testing.allocator, "echo \"for sen\" 'for\tsen'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "for sen", .type = .quoted },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "for\tsen", .type = .quoted },
    });
}

test "parser treats opposite quote characters as literals" {
    const parsed = try parse(testing.allocator, "\"it's fine\" 'say \"hi\"'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "it's fine", .type = .quoted },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "say \"hi\"", .type = .quoted },
    });
}

test "parser handles escaped characters outside quotes" {
    const parsed = try parse(testing.allocator, "foo\\ bar foo\\\"bar foo\\\\bar \\~ \\*");
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
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "~", .type = .escaped },
    });
    try expectToken(parsed.tokens[4], &[_]ExpectedSegment{
        .{ .value = "*", .type = .escaped },
    });
}

test "parser preserves backslashes inside single quotes" {
    const parsed = try parse(testing.allocator, "'a\\b \"x\"'");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "a\\b \"x\"", .type = .quoted },
    });
}

test "parser handles escaped quote and backslash inside double quotes" {
    const parsed = try parse(testing.allocator, "\"foo\\\"bar\" \"foo\\\\bar\"");
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
    const parsed = try parse(testing.allocator, "\"foo\\a\" \"foo\\ bar\"");
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
    const parsed = try parse(
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
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "~", .type = .quoted },
    });
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
    const parsed = try parse(testing.allocator, "echo \"\" '' a\"\"b");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "echo", .type = .default },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
    });
    try expectToken(parsed.tokens[2], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
    });
    try expectToken(parsed.tokens[3], &[_]ExpectedSegment{
        .{ .value = "a", .type = .default },
        .{ .value = "", .type = .quoted },
        .{ .value = "b", .type = .default },
    });
}

test "parser preserves standalone and adjacent empty quoted arguments" {
    const parsed = try parse(testing.allocator, "\"\" '' \"\"\"\" ''\"\"");
    defer parsed.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), parsed.tokens.len);
    try expectToken(parsed.tokens[0], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
    });
    try expectToken(parsed.tokens[1], &[_]ExpectedSegment{
        .{ .value = "", .type = .quoted },
    });
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
    const parsed = try parse(testing.allocator, "\"a\"b a\"b\" \"a\"\"b\"");
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

test "parser rejects trailing escapes" {
    try testing.expectError(
        error.UnclosedEscape,
        parse(testing.allocator, "foo\\"),
    );

    try testing.expectError(
        error.UnclosedEscape,
        parse(testing.allocator, "\\"),
    );
}

test "parser handles allocation failures without leaks" {
    for (0..32) |fail_index| {
        var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const allocator = failing_allocator.allocator();

        const result = parse(allocator, "echo \\\"for\\\" sen \"\" tail foo\\ bar \"a\\\"b\"");
        if (result) |parsed| {
            parsed.deinit(allocator);
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }

        try testing.expectEqual(failing_allocator.allocated_bytes, failing_allocator.freed_bytes);
    }
}
