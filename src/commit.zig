const std = @import("std");
const object = @import("object.zig");

pub const Commit = struct {
    tree: [40]u8 = [_]u8{0} ** 40,
    parent: [40]u8 = [_]u8{0} ** 40,
    author: []const u8 = "",
    message: []const u8 = "",
};

pub fn writeCommit(allocator: std.mem.Allocator, tree: [20]u8, parent: ?[20]u8, author: []const u8, message: []const u8) ![20]u8 {
    var content = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer content.deinit(allocator);

    // tree
    var hex_tree = std.fmt.bytesToHex(tree, .lower);
    try content.print(allocator, "tree {s}\n", .{&hex_tree});

    // parent
    if (parent) |parent_hash| {
        var hex_parent = std.fmt.bytesToHex(parent_hash, .lower);
        try content.print(allocator, "parent {s}\n", .{&hex_parent});
    }

    // author
    const time_stamp = std.time.timestamp();
    try content.print(allocator, "author {s} {d}\n", .{ author, time_stamp });

    // message/content
    try content.print(allocator, "\n{s}\n", .{message});

    std.debug.print("  commit info: {s}\n", .{content.items});

    return object.writeGitObject(allocator, "commit", content.items);
}

const Part = enum {
    parent,
    author,
    tree,
    message,

    fn getPartType(data: []const u8) Part {
        if (std.mem.startsWith(u8, data, "tree")) {
            return .tree;
        } else if (std.mem.startsWith(u8, data, "author")) {
            return .author;
        } else if (std.mem.startsWith(u8, data, "parent")) {
            return .parent;
        } else return .message;
    }
};

pub fn readCommit(content: []const u8) !object.Object {
    var commit: Commit = .{};

    var parts_iter = std.mem.splitScalar(u8, content, '\n');

    while (parts_iter.next()) |part| {
        switch (Part.getPartType(part)) {
            .tree => {
                const space_ind = std.mem.indexOfScalar(u8, part, ' ').? + 1;
                @memcpy(&commit.tree, part[space_ind..]);
            },
            .parent => {
                const space_ind = std.mem.indexOfScalar(u8, part, ' ').? + 1;
                @memcpy(&commit.parent, part[space_ind..]);
            },
            .author => {
                const space_ind = std.mem.indexOfScalar(u8, part, ' ').? + 1;
                commit.author = part[space_ind..];
            },
            else => {
                if (part.len != 0) {
                    commit.message = part;
                }
            },
        }
    }

    return .{
        .content = .{ .commit = commit },
        .size = 420,
    };
}
