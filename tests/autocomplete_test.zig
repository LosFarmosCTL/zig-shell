const std = @import("std");
const Autocomplete = @import("shell").Autocomplete;

const testing = std.testing;

test "autocomplete finds echo and exit from unique prefixes" {
    try testing.expectEqualStrings("echo", Autocomplete.builtinForPrefix("ech").?);
    try testing.expectEqualStrings("exit", Autocomplete.builtinForPrefix("exi").?);
    try testing.expectEqualStrings("echo", Autocomplete.builtinForPrefix("echo").?);
}

test "autocomplete rejects unknown and ambiguous prefixes" {
    try testing.expectEqual(@as(?[]const u8, null), Autocomplete.builtinForPrefix("nope"));
    try testing.expectEqual(@as(?[]const u8, null), Autocomplete.builtinForPrefix("e"));
    try testing.expectEqual(@as(?[]const u8, null), Autocomplete.builtinForPrefix(""));
}

test "autocomplete distinguishes invalid prefixes from ambiguous ones" {
    try testing.expect(!Autocomplete.hasMatchingBuiltin("xyz"));
    try testing.expect(Autocomplete.hasMatchingBuiltin("e"));
    try testing.expect(Autocomplete.hasMatchingBuiltin("ech"));
}

test "PATH completion skips missing directories" {
    const result = try Autocomplete.find(
        testing.allocator,
        testing.io,
        "/path/that/does/not/exist",
        "ech",
    );

    switch (result) {
        .match => |command| {
            defer testing.allocator.free(command);
            try testing.expectEqualStrings("echo", command);
        },
        else => return error.TestUnexpectedResult,
    }
}
