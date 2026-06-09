const std = @import("std");

pub fn parseArgv(allocator: std.mem.Allocator, input: []const u8) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    var iter = std.mem.tokenizeAny(u8, input, " \t");
    while (iter.next()) |arg| try argv.append(allocator, arg);

    return try argv.toOwnedSlice(allocator);
}
