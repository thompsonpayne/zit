const std = @import("std");
const index_mod = @import("index.zig");
const blob_mod = @import("blob.zig");
const object_mod = @import("object.zig");
const FileKind = std.fs.File.Kind;

pub const Entry = struct {
    name: []const u8,
    hash: [20]u8,
    kind: std.fs.File.Kind,
    mode: []const u8,
};

pub const Tree = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Tree {
        return Tree{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        _ = self;
    }

    // pub fn constructEntry(data: []const u8) !Entry {}

    pub fn write(self: *Tree, dir: *std.fs.Dir) ![20]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        var entries = try std.ArrayList(Entry).initCapacity(allocator, 1024);
        defer {
            entries.deinit(allocator);
        }

        var dir_iter = dir.iterate();
        while (try dir_iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".zig-cache") or
                std.mem.startsWith(u8, entry.name, ".git") or
                std.mem.eql(u8, entry.name, "."))
            {
                continue;
            }

            switch (entry.kind) {
                .file => {
                    const hash = try blob_mod.writeBlob(self.allocator, dir, entry.name);
                    // std.debug.print("hased file: {s}\n", .{entry.name});
                    try entries.append(
                        allocator,
                        Entry{
                            .name = try allocator.dupe(u8, entry.name),
                            .hash = hash,
                            .kind = .file,
                            .mode = "100644",
                        },
                    );
                },
                .directory => {
                    var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
                    defer sub_dir.close();
                    const hash = try self.write(&sub_dir);
                    // std.debug.print("hashed dir: {s}\n", .{entry.name});

                    try entries.append(
                        allocator,
                        Entry{
                            .name = try allocator.dupe(u8, entry.name),
                            .hash = hash,
                            .kind = .directory,
                            .mode = "40000",
                        },
                    );
                },
                else => continue,
            }
        }

        // Sort entries
        std.sort.block(Entry, entries.items, {}, lessThan);

        // Build content
        var content = try std.ArrayList(u8).initCapacity(allocator, 4096);
        defer content.deinit(allocator);

        for (entries.items) |entry| {
            try content.print(allocator, "{s} {s}\x00", .{ entry.mode, entry.name });
            try content.appendSlice(allocator, &entry.hash);
        }

        return object_mod.writeGitObject(self.allocator, "tree", content.items);
    }

    pub fn writeFromIndex(self: *Tree, index_entries: []const index_mod.IndexEntry) ![20]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        var root = try DirNode.init(allocator);

        for (index_entries) |ie| {
            try root.addIndexEntry(allocator, ie);
        }

        // var iter = root.subdirs.iterator();
        // while (iter.next()) |sub_dir| {
        //     std.debug.print("key: {s}\n", .{sub_dir.key_ptr.*});
        //     for (sub_dir.value_ptr.*.files.items) |value| {
        //         std.debug.print("file: {s}\n", .{value.name});
        //     }
        // }

        return try self.writeDirNode(allocator, &root);
    }

    pub fn writeDirNode(self: *Tree, allocator: std.mem.Allocator, node: *DirNode) ![20]u8 {
        // collect this directory's entries:
        // files as-is
        // subdirs as (mode 40000, kind directory, hash = written subtree)

        var entries = try std.ArrayList(Entry).initCapacity(
            allocator,
            node.files.items.len + node.subdirs.count(),
        );
        defer entries.deinit(allocator);

        for (node.files.items) |item| {
            try entries.append(allocator, item);
        }

        var sub_iter = node.subdirs.iterator();
        while (sub_iter.next()) |entry| {
            std.debug.print("Entry? {s}\n", .{entry.value_ptr.*.name});
            const child = entry.value_ptr.*;
            const child_hash = try self.writeDirNode(allocator, child);

            try entries.append(
                allocator,
                Entry{
                    .hash = child_hash,
                    .name = child.name,
                    .kind = .directory,
                    .mode = "40000",
                },
            );
        }

        std.sort.block(
            Entry,
            entries.items,
            {},
            lessThan,
        );

        var content = try std.ArrayList(u8).initCapacity(allocator, 4096);
        defer content.deinit(allocator);

        for (entries.items) |entry| {
            try content.print(allocator, "{s} {s}\x00", .{ entry.mode, entry.name });
            try content.appendSlice(allocator, &entry.hash);
        }

        return object_mod.writeGitObject(
            allocator,
            "tree",
            content.items,
        );
    }
};

fn getChar(entry: Entry, index: usize) ?u8 {
    if (index < entry.name.len) return entry.name[index];
    if (index == entry.name.len and entry.kind == .directory) return '/';
    return null;
}

fn lessThan(context: void, lhs: Entry, rhs: Entry) bool {
    _ = context;
    var i: usize = 0;
    while (true) : (i += 1) {
        const l = getChar(lhs, i);
        const r = getChar(rhs, i);

        if (l == null and r == null) return false;
        if (l == null) return true;
        if (r == null) return false;

        if (l.? < r.?) return true;
        if (l.? > r.?) return false;
    }
}

pub fn parseTreeContent(allocator: std.mem.Allocator, data: []const u8) ![]Entry {
    var tree_entries = try std.ArrayList(Entry).initCapacity(allocator, 1024);
    defer tree_entries.deinit(allocator);

    var pos: usize = 0;
    while (pos < data.len) {
        const space_ind = std.mem.indexOfScalar(u8, data[pos..], ' ').? + pos;

        // 40000 or 100644
        const entry_mode = data[pos..space_ind];

        const name_start = space_ind + 1;
        const null_rel = std.mem.indexOfScalar(u8, data[name_start..], 0).?;
        const null_ind = null_rel + name_start;
        const entry_name = data[name_start..null_ind];

        const hash_start = null_ind + 1;

        if (20 > data[hash_start..].len) {
            return error.MalFormedTree;
        }

        var hash: [20]u8 = undefined;
        @memcpy(&hash, data[hash_start .. hash_start + 20]);

        const kind = if (std.mem.eql(u8, entry_mode, "40000")) FileKind.directory else if (std.mem.eql(u8, entry_mode, "100644")) FileKind.file else FileKind.unknown;

        try tree_entries.append(allocator, .{
            .name = entry_name,
            .hash = hash,
            .kind = kind,
            .mode = entry_mode,
        });

        pos = hash_start + 20;
    }

    return tree_entries.toOwnedSlice(allocator);
}

fn treeModeFromIndexMode(mode: u32) []const u8 {
    if ((mode & 0o111) != 0) return "100755";
    return "100644";
}

const DirNode = struct {
    name: []const u8,
    subdirs: std.StringHashMap(*DirNode),
    files: std.ArrayList(Entry),

    fn init(allocator: std.mem.Allocator) !DirNode {
        return .{
            .name = "",
            .subdirs = std.StringHashMap(*DirNode).init(allocator),
            .files = try std.ArrayList(Entry).initCapacity(allocator, 16),
        };
    }

    fn getOrCreateSubDir(self: *DirNode, allocator: std.mem.Allocator, name: []const u8) !*DirNode {
        if (self.subdirs.get(name)) |existing| return existing;

        const name_copy = try allocator.dupe(u8, name);

        const node_ptr = try allocator.create(DirNode);
        node_ptr.* = try DirNode.init(allocator); // WARN: leak?
        node_ptr.name = name_copy;

        try self.subdirs.put(name_copy, node_ptr);
        return node_ptr;
    }

    fn addIndexEntry(self: *DirNode, allocator: std.mem.Allocator, ie: index_mod.IndexEntry) !void {
        const mode_str = treeModeFromIndexMode(ie.mode);

        // split path into dir part + file name
        // dir_path example: src/test/
        const dir_path = std.fs.path.dirname(ie.path) orelse "/";
        const file_name = std.fs.path.basename(ie.path);

        var cur: *DirNode = self;

        // add subdirs based on dir_path
        if (dir_path.len != 0) {
            var parts = std.mem.splitScalar(
                u8,
                dir_path,
                '/',
            );

            while (parts.next()) |p| {
                if (p.len == 0) continue;
                cur = try cur.getOrCreateSubDir(allocator, p);
            }
        }

        // cur is closest subdir parent -> add file entry
        try cur.files.append(
            allocator,
            Entry{
                .hash = ie.sha,
                .name = try allocator.dupe(u8, file_name),
                .kind = .file,
                .mode = mode_str,
            },
        );
    }
};

test "path_split" {
    const path = "src/test/main.zig";
    // split path into dir part + base name
    const dir_path = std.fs.path.dirname(path) orelse "/";
    const base_name = std.fs.path.basename(path);
    try std.testing.expect(std.mem.eql(u8, "src/test", dir_path));
    try std.testing.expect(std.mem.eql(u8, "main.zig", base_name));
}
