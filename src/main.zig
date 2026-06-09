const std = @import("std");
const Shell = @import("shell.zig").Shell;

pub fn main(init: std.process.Init) !void {
    var shell = Shell.init(init);
    try shell.run();
}
