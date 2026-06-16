const std = @import("std");
const builtin = @import("builtin");

pub const Parser = @import("parser.zig");
pub const Expander = @import("expander.zig");

comptime {
    if (builtin.is_test) std.testing.refAllDecls(@This());
}
