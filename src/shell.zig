const std = @import("std");
const Parser = @import("parser.zig");
const Expander = @import("expander.zig");
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

            const parsed = Parser.parse(allocator, input) catch |err| switch (err) {
                error.UnclosedQuote => {
                    try stdout.print("shell: unclosed quote\n", .{});
                    continue :repl;
                },
                error.UnclosedEscape => {
                    try stdout.print("shell: unclosed escape\n", .{});
                    continue :repl;
                },
                else => return err,
            };
            defer parsed.deinit(allocator);

            const expanded = Expander.expandCommand(allocator, self.env_home, parsed.tokens) catch |err| switch (err) {
                error.MissingRedirectTarget => {
                    try stdout.print("shell: expected a file after redirection\n", .{});
                    continue :repl;
                },
                else => return err,
            };
            defer expanded.deinit(allocator);

            if (expanded.argv.len == 0) continue :repl;
            self.execute(allocator, stdout, expanded.argv, expanded.stdout_path) catch |err| switch (err) {
                error.ShellExit => return,
                else => return err,
            };
        }
    }

    fn execute(
        self: *Shell,
        allocator: std.mem.Allocator,
        terminal_stdout: *std.Io.Writer,
        argv: []const []const u8,
        stdout_path: ?[]const u8,
    ) !void {
        if (stdout_path) |path| {
            const file = try std.Io.Dir.cwd().createFile(self.proc_init.io, path, .{});
            defer file.close(self.proc_init.io);

            var file_writer = file.writer(self.proc_init.io, &.{});
            defer file_writer.interface.flush() catch {};

            return self.dispatch(allocator, terminal_stdout, &file_writer.interface, file, argv);
        }

        return self.dispatch(allocator, terminal_stdout, terminal_stdout, null, argv);
    }

    fn dispatch(
        self: *Shell,
        allocator: std.mem.Allocator,
        terminal_stdout: *std.Io.Writer,
        command_stdout: *std.Io.Writer,
        stdout_file: ?std.Io.File,
        argv: []const []const u8,
    ) !void {
        const command = argv[0];

        if (Builtin.fromString(command)) |builtin| {
            try builtin.execute(self, allocator, command_stdout, argv);
        } else if (try Exec.findInPath(allocator, self.proc_init.io, self.env_path, command)) |_| {
            try Exec.spawn(self, terminal_stdout, argv, stdout_file);
        } else {
            try terminal_stdout.print("{s}: command not found\n", .{command});
        }
    }
};
