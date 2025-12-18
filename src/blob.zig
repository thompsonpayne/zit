const std = @import("std");

const object = @import("object.zig");

pub fn writeBlob(allocator: std.mem.Allocator, dir: *std.fs.Dir, filename: []const u8) ![20]u8 {
    const file = dir.openFile(filename, .{}) catch |err| {
        std.log.err("{}", .{err});
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB limit
    defer allocator.free(content);

    return object.writeGitObject(allocator, "blob", content);
}
