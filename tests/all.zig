const std = @import("std");

pub const parser_test = @import("parser_test.zig");
pub const expander_test = @import("expander_test.zig");

comptime {
    std.testing.refAllDecls(@This());
}
