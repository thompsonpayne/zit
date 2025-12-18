const std = @import("std");
const object = @import("object.zig");
const tree = @import("tree.zig");
const commit = @import("commit.zig");

pub fn initDirs() !void {
    const stdout_struct = std.fs.File.stdout();
    var buffer: [4098]u8 = undefined;
    var writer = stdout_struct.writer(&buffer);
    const stdout = &writer.interface;

    const cwd = std.fs.cwd();

    // Create subdirectories: .git/objects, .git/refs, .git/refs/heads.
    const paths = [_][]const u8{ ".git/objects", ".git/refs/heads" };
    for (paths) |path| {
        _ = cwd.makePath(path) catch |err| {
            try stdout.print("Path already exist: {s}\n", .{path});
            return err;
        };
        try stdout.print("Path created: {s}\n", .{path});
    }

    const head_file = try std.fs.cwd().createFile(".git/HEAD", .{});
    defer head_file.close();

    var head_buffer: [1024]u8 = undefined;
    var head_writer = head_file.writer(&head_buffer);
    const header_out = &head_writer.interface;

    try header_out.writeAll("ref: refs/heads/main\n");

    try stdout.flush();
    try header_out.flush();
}

pub fn open(allocator: std.mem.Allocator) !void {
    try walk(allocator);
}

pub fn walk(allocator: std.mem.Allocator) !void {
    const absolute_path: []const u8 = try std.process.getCwdAlloc(allocator);
    defer allocator.free(absolute_path);

    var cwd: []const u8 = absolute_path;
    std.debug.print("cwd {s}\n", .{cwd});

    const final_path: ?[]const u8 = while (true) {
        const path_with_git = try std.fs.path.join(allocator, &.{ cwd, ".git" });
        defer allocator.free(path_with_git);
        var dir = std.fs.openDirAbsolute(path_with_git, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                // walk up
                if (std.fs.path.dirname(cwd)) |parent| {
                    cwd = parent;
                    continue;
                } else {
                    break null;
                }
            },
            else => return err,
        };

        dir.close();
        break cwd;
    } else null;

    if (final_path) |found| {
        std.debug.print("found the .git folder: {s}\n", .{found});
    } else {
        std.debug.print("not found .git", .{});
    }
}

pub fn readAllFile(allocator: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();
    const path = try std.fs.path.join(allocator, &.{ ".git", "objects" });
    defer allocator.free(path);

    var git_dir = cwd.openDir(path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("Not in a git directory\n", .{});
            return err;
        },
        else => {
            std.log.err("error: {}\n", .{err});
            return err;
        },
    };
    defer git_dir.close();

    var git_iter = git_dir.iterate();
    while (try git_iter.next()) |entry| {
        const sub_path = try std.fs.path.join(allocator, &.{ ".git", "objects", entry.name });
        defer allocator.free(sub_path);

        var sub_dir = try cwd.openDir(sub_path, .{ .iterate = true });
        defer sub_dir.close();

        var sub_iter = sub_dir.iterate();

        while (try sub_iter.next()) |sub_entry| {
            const full_hash = try std.mem.concat(allocator, u8, &.{ entry.name, sub_entry.name });
            defer allocator.free(full_hash);

            const content = try object.readHashObject(allocator, full_hash);
            defer allocator.free(content);

            const parsed_content: object.Object = parseContent(allocator, content) catch |err| {
                std.debug.print("error parsing content: {}\n", .{err});
                return err;
            };
            defer {
                if (parsed_content.content == .tree) {
                    allocator.free(parsed_content.content.tree);
                }
            }

            switch (parsed_content.content) {
                .tree => {},
                // .tree => |entries| {
                //     for (entries) |value| {
                //         std.debug.print("\n", .{});
                //         std.debug.print("   name: {s}\n", .{value.name});
                //         std.debug.print("   kind: {s}\n", .{@tagName(value.kind)});
                //         std.debug.print("   content: {s}\n", .{value.mode});
                //         std.debug.print("   hash: {s}\n", .{value.hash});
                //     }
                // },
                .commit => |value| {
                    std.debug.print("tree: {s}\n", .{value.tree});
                    std.debug.print("parent: {s}\n", .{value.parent});
                    std.debug.print("author: {s}\n", .{value.author});
                    std.debug.print("message: {s}\n", .{value.message});
                },
                .blob => {
                    // std.debug.print("blob content: {s}\n", .{value[0..@min(50, value.len)]});
                },
            }
            // var new_content = std.mem.splitScalar(u8, content, 0);
            // while (new_content.next()) |part| {
            //     std.debug.print("part = {s}\n", .{part});
            // }

            // std.debug.print("   {s}\n", .{sub_entry.name});
            // std.debug.print("   content: \n", .{});
            // std.debug.print("     {s}: \n", .{content[0..@min(100, content.len)]});
        }
    }
}

pub fn parseContent(allocator: std.mem.Allocator, content: []const u8) !object.Object {
    // NOTE: content structure: <type> <size><null terminator><actual content>
    const type_ind = std.mem.indexOfScalar(u8, content, ' ');
    if (type_ind) |ind| {
        const type_slice = content[0..ind];
        const body = content[ind + 1 ..];

        // std.debug.print("➡️➡️➡️ body: {s}\n", .{body[0..@min(100, body.len)]});

        // const object_type = std.meta.stringToEnum(object.ObjectKind, type_slice);
        const size_ind = std.mem.indexOfScalar(u8, body, '\x00');
        if (size_ind) |size_i| {
            const size = body[0..size_i];
            const object_type = std.meta.stringToEnum(object.ObjectKind, type_slice) orelse return error.InvalidObjectType;
            const actual_content = body[size_i + 1 ..];

            switch (object_type) {
                .tree => {
                    // tree <size>\0
                    // 100644 file1.txt\0<20-byte hash>
                    // 100644 main.c\0<20-byte hash>
                    // 40000 src\0<20-byte hash>

                    const tree_entries = try tree.parseTreeContent(allocator, actual_content);

                    return .{
                        .size = try std.fmt.parseInt(usize, size, 10),
                        .content = .{ .tree = tree_entries },
                    };
                },
                .commit => {
                    return try commit.readCommit(actual_content);
                },
                .blob => {
                    return .{
                        .size = try std.fmt.parseInt(usize, size, 10),
                        .content = .{ .blob = content },
                    };
                },
            }

            // if (object_type) |o_type| {
            //     switch (o_type) {
            //         .tree => {
            //             std.debug.print("tree content snippet: {s}\n", .{actual_content[0..@min(50, actual_content.len)]});
            //         },
            //         else => {},
            //     }
            //
            //     return .{
            //         .content = actual_content,
            //         .size = try std.fmt.parseInt(usize, size, 10),
            //         .type = o_type,
            //     };
            // }
        } else {
            std.debug.print("error finding content size\n", .{});
        }

        // if (object_type) |value| {
        //     switch (value) {
        //         .commit => {
        //             return try commit.readCommit(allocator, content);
        //         },
        //         .tree => {
        //             return .{ .content = content, .size = 420, .type = .tree };
        //         },
        //         .blob => {
        //             return .{ .content = content, .size = 420, .type = .blob };
        //         },
        //     }
        // }
    }
    return error.ParseError;
}
