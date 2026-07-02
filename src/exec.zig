const std = @import("std");

const Shell = @import("shell.zig").Shell;

pub fn findInPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    cmd: []const u8,
) !?[]const u8 {
    var paths = std.mem.splitScalar(u8, path, ':');
    while (paths.next()) |dir| {
        if (dir.len == 0) continue;

        {
            var dir_handle = std.Io.Dir.openDirAbsolute(io, dir, .{}) catch continue;
            defer dir_handle.close(io);

            const stat = dir_handle.statFile(io, cmd, .{
                .follow_symlinks = true,
            }) catch continue;

            if (stat.kind != .file) continue;

            dir_handle.access(io, cmd, .{
                .execute = true,
                .follow_symlinks = true,
            }) catch continue;

            return try std.fs.path.join(allocator, &.{ dir, cmd });
        }
    }

    return null;
}

pub fn spawn(
    shell: *Shell,
    stdout: anytype,
    argv: []const []const u8,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
) !void {
    const spawn_options: std.process.SpawnOptions = .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = if (stdout_file) |file| .{ .file = file } else .inherit,
        .stderr = if (stderr_file) |file| .{ .file = file } else .inherit,
    };

    // TODO: `spawnPath` is not currently supported in zig 0.16, should switch
    // once it becomes available, for now just rely on spawn doing PATH lookup
    //
    // const dirname = std.fs.path.dirname(path).?;
    // var dir = try std.Io.Dir.openDirAbsolute(init.io, dirname, .{});
    // defer dir.close(init.io);
    //
    // var child = try std.process.spawnPath(init.io, dir, spawn_options);

    var child = std.process.spawn(shell.proc_init.io, spawn_options) catch |err| switch (err) {
        error.FileNotFound => {
            return try stdout.print("{s}: command not found\n", .{argv[0]});
        },
        error.PermissionDenied, error.AccessDenied => {
            return try stdout.print("{s}: permission denied\n", .{argv[0]});
        },
        error.InvalidExe => {
            return try stdout.print("{s}: invalid executable\n", .{argv[0]});
        },
        error.FileBusy => {
            return try stdout.print("{s}: file busy\n", .{argv[0]});
        },
        error.SymLinkLoop => {
            return try stdout.print("{s}: too many levels of symbolic links\n", .{argv[0]});
        },
        else => return err,
    };

    _ = try child.wait(shell.proc_init.io);
}
