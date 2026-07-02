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
    kind: Kind = .word,

    pub const Kind = enum {
        word,
        stdout_redirect,
        stderr_redirect,
        stdout_append,
        stderr_append,
    };
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

            '>' => {
                const operator_start = self.i;
                try self.appendSegment(start_pos, self.i, .default);

                const append = self.i + 1 < self.input.len and self.input[self.i + 1] == '>';
                var redirect_kind: Token.Kind = .stdout_redirect;

                // In `1>` and `2>`, the number identifies the stream and is
                // part of the operator rather than an argument.
                if (self.segments.items.len == 1 and
                    self.segments.items[0].type == .default)
                {
                    const descriptor = self.segments.items[0].value;
                    if (std.mem.eql(u8, descriptor, "1")) {
                        self.segments.clearRetainingCapacity();
                    } else if (std.mem.eql(u8, descriptor, "2")) {
                        self.segments.clearRetainingCapacity();
                        redirect_kind = .stderr_redirect;
                    } else {
                        try self.appendToken();
                    }
                } else {
                    try self.appendToken();
                }

                if (append) {
                    redirect_kind = switch (redirect_kind) {
                        .stdout_redirect => .stdout_append,
                        .stderr_redirect => .stderr_append,
                        else => unreachable,
                    };
                    self.i += 1;
                }

                try self.appendSegment(operator_start, self.i + 1, .default);
                try self.appendTokenKind(redirect_kind);
                self.state = .{ .default = self.i + 1 };
                return;
            },
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
        return self.appendTokenKind(.word);
    }

    fn appendTokenKind(self: *Parser, kind: Token.Kind) !void {
        if (self.segments.items.len == 0) return;

        const parts = try self.segments.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(parts);

        try self.tokens.append(self.allocator, Token{ .parts = parts, .kind = kind });
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
