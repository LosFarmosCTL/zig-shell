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
