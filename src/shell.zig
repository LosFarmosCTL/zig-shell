const std = @import("std");
const Parser = @import("parser.zig");
const Builtin = @import("builtin.zig").Builtin;
const Exec = @import("exec.zig");

pub const Shell = struct {
    proc_init: std.process.Init,
    env_path: []const u8,
    env_home: []const u8,

    pub fn init(proc_init: std.process.Init) Shell {
        const env_path = proc_init.minimal.environ.getPosix("PATH") orelse "";
        const env_home = proc_init.minimal.environ.getPosix("HOME") orelse "";

        return Shell{
            .proc_init = proc_init,
            .env_path = env_path,
            .env_home = env_home,
        };
    }

    pub fn run(self: *Shell) !void {
        const io = self.proc_init.io;

        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        const stdout = &stdout_writer.interface;
        defer stdout.flush() catch {};

        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const stdin = &stdin_reader.interface;

        repl: while (true) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            try stdout.print("$ ", .{});
            const input = (try stdin.takeDelimiter('\n')) orelse continue;

            const argv = try Parser.parseArgv(allocator, input);

            if (argv.len == 0) continue :repl;
            const command = argv[0];

            if (Builtin.fromString(command)) |builtin| {
                builtin.execute(self, allocator, stdout, argv) catch |err| switch (err) {
                    error.ShellExit => return,
                    else => return err,
                };
            } else if (try Exec.findInPath(allocator, io, self.env_path, command)) |_| {
                try Exec.spawn(self, stdout, argv);
            } else {
                try stdout.print("{s}: command not found\n", .{command});
            }
        }
    }
};
