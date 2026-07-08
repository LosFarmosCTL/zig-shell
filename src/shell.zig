const std = @import("std");
const Parser = @import("parser.zig");
const Expander = @import("expander.zig");
const Builtin = @import("builtin.zig").Builtin;
const Exec = @import("exec.zig");
const Autocomplete = @import("autocomplete.zig");

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

        var stdout_writer = std.Io.File.stdout().writerStreaming(io, &.{});
        const stdout = &stdout_writer.interface;
        defer stdout.flush() catch {};

        var stderr_writer = std.Io.File.stderr().writerStreaming(io, &.{});
        const stderr = &stderr_writer.interface;
        defer stderr.flush() catch {};

        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
        const stdin = &stdin_reader.interface;
        const interactive = try std.Io.File.stdin().isTty(io);

        repl: while (true) {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            try stdout.print("$ ", .{});
            const input = (try self.readLine(allocator, stdin, stdout, interactive)) orelse return;

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
            self.execute(
                allocator,
                stdout,
                stderr,
                expanded.argv,
                expanded.stdout_path,
                expanded.stderr_path,
                expanded.stdout_append,
                expanded.stderr_append,
            ) catch |err| switch (err) {
                error.ShellExit => return,
                else => return err,
            };
        }
    }

    fn readLine(
        self: *Shell,
        allocator: std.mem.Allocator,
        stdin: *std.Io.Reader,
        stdout: *std.Io.Writer,
        interactive: bool,
    ) !?[]const u8 {
        var original_termios: ?std.posix.termios = null;
        if (interactive) {
            const fd = std.Io.File.stdin().handle;
            const original = try std.posix.tcgetattr(fd);
            var raw = original;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            try std.posix.tcsetattr(fd, .NOW, raw);
            original_termios = original;
        }
        defer if (original_termios) |original| {
            std.posix.tcsetattr(std.Io.File.stdin().handle, .NOW, original) catch {};
        };

        var input = std.ArrayList(u8).empty;
        defer input.deinit(allocator);
        var tab_pending = false;

        while (true) {
            const byte = stdin.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    if (input.items.len == 0) return null;
                    return try input.toOwnedSlice(allocator);
                },
                else => return err,
            };

            if (byte != '\t') tab_pending = false;

            switch (byte) {
                '\r', '\n' => {
                    if (interactive) try stdout.print("\n", .{});
                    return try input.toOwnedSlice(allocator);
                },
                '\t' => {
                    const completion = try Autocomplete.find(
                        allocator,
                        self.proc_init.io,
                        self.env_path,
                        input.items,
                    );
                    defer completion.deinit(allocator);

                    switch (completion) {
                        .match => |command| {
                            const suffix = command[input.items.len..];
                            try input.appendSlice(allocator, suffix);
                            try input.append(allocator, ' ');
                            if (interactive) try stdout.print("{s} ", .{suffix});
                            tab_pending = false;
                        },
                        .none => if (interactive) try stdout.print("\x07", .{}),
                        .multiple => |commands| {
                            const common_prefix = Autocomplete.longestCommonPrefix(commands);
                            if (common_prefix.len > input.items.len) {
                                const suffix = common_prefix[input.items.len..];
                                try input.appendSlice(allocator, suffix);
                                if (interactive) try stdout.print("{s}", .{suffix});
                                tab_pending = false;
                                continue;
                            }

                            if (!tab_pending) {
                                if (interactive) try stdout.print("\x07", .{});
                                tab_pending = true;
                                continue;
                            }

                            if (interactive) {
                                try stdout.print("\n", .{});
                                for (commands, 0..) |command, i| {
                                    if (i != 0) try stdout.print("  ", .{});
                                    try stdout.print("{s}", .{command});
                                }
                                try stdout.print("\n$ {s}", .{input.items});
                            }
                            tab_pending = false;
                        },
                    }
                },
                0x7f, 0x08 => {
                    if (input.items.len > 0) {
                        _ = input.pop();
                        if (interactive) try stdout.print("\x08 \x08", .{});
                    }
                },
                0x04 => {
                    if (input.items.len == 0) return null;
                },
                else => {
                    try input.append(allocator, byte);
                    if (interactive) try stdout.print("{c}", .{byte});
                },
            }
        }
    }

    fn execute(
        self: *Shell,
        allocator: std.mem.Allocator,
        terminal_stdout: *std.Io.Writer,
        terminal_stderr: *std.Io.Writer,
        argv: []const []const u8,
        stdout_path: ?[]const u8,
        stderr_path: ?[]const u8,
        stdout_append: bool,
        stderr_append: bool,
    ) !void {
        const io = self.proc_init.io;
        var stdout_file: ?std.Io.File = null;
        defer if (stdout_file) |file| file.close(io);
        var stderr_file: ?std.Io.File = null;
        defer if (stderr_file) |file| file.close(io);

        if (stdout_path) |path| stdout_file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = !stdout_append,
        });
        if (stderr_path) |path| stderr_file = try std.Io.Dir.cwd().createFile(io, path, .{
            .truncate = !stderr_append,
        });

        var stdout_writer: ?std.Io.File.Writer = if (stdout_file) |file| file.writerStreaming(io, &.{}) else null;
        defer if (stdout_writer) |*writer| writer.interface.flush() catch {};
        var stderr_writer: ?std.Io.File.Writer = if (stderr_file) |file| file.writerStreaming(io, &.{}) else null;
        defer if (stderr_writer) |*writer| writer.interface.flush() catch {};

        if (stdout_append) {
            if (stdout_writer) |*writer| try writer.seekTo((try stdout_file.?.stat(io)).size);
        }
        if (stderr_append) {
            if (stderr_writer) |*writer| try writer.seekTo((try stderr_file.?.stat(io)).size);
        }

        const command_stdout = if (stdout_writer) |*writer| &writer.interface else terminal_stdout;
        const command_stderr = if (stderr_writer) |*writer| &writer.interface else terminal_stderr;

        return self.dispatch(
            allocator,
            command_stdout,
            command_stderr,
            stdout_file,
            stderr_file,
            argv,
        );
    }

    fn dispatch(
        self: *Shell,
        allocator: std.mem.Allocator,
        command_stdout: *std.Io.Writer,
        command_stderr: *std.Io.Writer,
        stdout_file: ?std.Io.File,
        stderr_file: ?std.Io.File,
        argv: []const []const u8,
    ) !void {
        const command = argv[0];

        if (Builtin.fromString(command)) |builtin| {
            try builtin.execute(self, allocator, command_stdout, command_stderr, argv);
        } else if (try Exec.findInPath(allocator, self.proc_init.io, self.env_path, command)) |_| {
            try Exec.spawn(self, command_stderr, argv, stdout_file, stderr_file);
        } else {
            try command_stderr.print("{s}: command not found\n", .{command});
        }
    }
};
