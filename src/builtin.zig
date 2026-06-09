const std = @import("std");

const Shell = @import("shell.zig").Shell;
const Exec = @import("exec.zig");

pub const Builtin = enum {
    exit,
    echo,
    pwd,
    cd,
    type,

    pub fn fromString(str: []const u8) ?Builtin {
        return std.meta.stringToEnum(Builtin, str);
    }

    pub fn execute(
        self: Builtin,
        shell: *Shell,
        allocator: std.mem.Allocator,
        stdout: anytype,
        argv: []const []const u8,
    ) !void {
        switch (self) {
            .exit => return error.ShellExit,
            .echo => {
                for (argv[1..], 0..) |arg, i| {
                    if (i != 0) try stdout.print(" ", .{});
                    try stdout.print("{s}", .{arg});
                }

                try stdout.print("\n", .{});
            },
            .pwd => {
                const cwd = try std.Io.Dir.cwd().realPathFileAlloc(shell.proc_init.io, ".", allocator);
                try stdout.print("{s}\n", .{cwd});
            },
            .cd => {
                if (argv.len > 2) {
                    return try stdout.print("Too many arguments for cd command\n", .{});
                }

                var path: []const u8 = "~";
                if (argv.len == 2) path = argv[1];

                const resolved_path = resolveHome(
                    allocator,
                    path,
                    shell.env_home,
                ) catch |err| switch (err) {
                    error.HomeNotSet => {
                        return try stdout.print("cd: HOME not set\n", .{});
                    },
                    else => return err,
                };

                chdir(shell.proc_init.io, resolved_path) catch {
                    try stdout.print("cd: {s}: No such file or directory\n", .{path});
                };
            },
            .type => {
                for (argv[1..]) |arg| {
                    if (Builtin.fromString(arg) != null) {
                        try stdout.print("{s} is a shell builtin\n", .{arg});
                    } else if (try Exec.findInPath(
                        allocator,
                        shell.proc_init.io,
                        shell.env_path,
                        arg,
                    )) |path| {
                        try stdout.print("{s} is {s}\n", .{ arg, path });
                    } else {
                        try stdout.print("{s}: not found\n", .{arg});
                    }
                }
            },
        }
    }
};

fn resolveHome(
    allocator: std.mem.Allocator,
    path: []const u8,
    home_path: []const u8,
) ![]const u8 {
    return if (std.mem.eql(u8, path, "~")) {
        if (home_path.len == 0) return error.HomeNotSet;
        return home_path;
    } else if (std.mem.startsWith(u8, path, "~/")) {
        if (home_path.len == 0) return error.HomeNotSet;

        return try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ home_path, path[1..] },
        );
    } else path;
}

fn chdir(io: std.Io, path: []const u8) !void {
    const dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return error.DirNotFound;
    std.process.setCurrentDir(io, dir) catch return error.DirNotFound;
}
