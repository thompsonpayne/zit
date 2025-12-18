const std = @import("std");
// const object = @import("object.zig");

pub const IndexEntry = struct {
    // metadata (10 x 4 bytes = 40 bytes)
    ctime_s: u32, // creation time seconds
    ctime_n: u32, // creation time nanoseconds
    mtime_s: u32, // modify time seconds
    mtime_n: u32, // modify time nanoseconds

    dev: u32, // device id
    ino: u32, // inode num
    mode: u32, // File mode (0o100644 or 0o100755)
    uid: u32, // userid
    gid: u32, //group id
    size: u32, // file size in bytes

    // sha 20 bytes
    sha: [20]u8,

    // flags 2 bytes
    flags: u16, // lower 12 bits = path length

    // path (variable, null-terminated + padding to 8-byte boundary)
    path: []const u8,
};

pub const Index = struct {
    entries: std.ArrayList(IndexEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Index {
        return .{
            .allocator = allocator,
            .entries = try std.ArrayList(IndexEntry).initCapacity(allocator, 1024),
        };
    }

    pub fn deinit(self: *Index) void {
        for (self.entries.items) |value| {
            self.allocator.free(value.path);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn addEntry(self: *Index, entry: IndexEntry) !void {
        // find an existing entry with the same path and replace it in-place.
        for (self.entries.items, 0..) |existing, ind| {
            if (std.mem.eql(u8, entry.path, existing.path)) {
                // free the old path buffer and overwrite the entry.
                self.allocator.free(existing.path);
                self.entries.items[ind] = entry;
                return;
            }
        }

        // otherwise, append a new entry and keep the list sorted by path.
        try self.entries.append(self.allocator, entry);
        std.mem.sort(IndexEntry, self.entries.items, {}, lessThanPath);
    }

    // read existing index from .git/index
    pub fn read(allocator: std.mem.Allocator) !Index {
        var index = try Index.init(allocator);
        // ensure we free the allocated array list if this function returns with an error
        // (e.g. when .git/index cannot be opened or is invalid).
        errdefer index.deinit();

        const file = std.fs.cwd().openFile(".git/index", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return err;
            },
            else => return err,
        };
        defer file.close();

        const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(data);

        // signature: 4 bytes ("DIRC" = 0x44495243)
        // version: 4 bytes (usually version 2)
        // entry count: 4 bytes (number of files)
        var pos: usize = 0;

        const signature = readBytes(u32, data, &pos, 4);
        if (signature != 0x44495243) return error.InvalidIndexSignature;

        const version = readBytes(u32, data, &pos, 4);
        _ = version;

        const entry_count = readBytes(u32, data, &pos, 4);

        // parse entries
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            const entry = try parseEntry(allocator, data, &pos);
            try index.entries.append(allocator, entry);
        }

        return index;
    }

    pub fn write(self: *Index) !void {
        // open the index for both writing and reading so we can compute the checksum
        // from the bytes we just wrote.
        const file = try std.fs.cwd().createFile(".git/index", .{ .read = true });
        defer file.close();

        var buff: [8192]u8 = undefined;
        var file_writer = file.writer(&buff);
        const writer = &file_writer.interface;

        // write header
        try writer.writeInt(u32, 0x44495243, .big);
        try writer.writeInt(u32, 2, .big);
        try writer.writeInt(u32, @intCast(self.entries.items.len), .big);

        // write entries
        for (self.entries.items) |entry| {
            try writeEntry(writer, entry);
        }

        try writer.flush();

        // compute checksum
        // jump back to first byte to read after writing a bunch of bytes
        try file.seekTo(0);
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(content);
        var checksum: [20]u8 = undefined;
        sha1.final(&checksum);

        // append checksum
        try file.seekFromEnd(0);
        try writer.writeAll(&checksum);
        try writer.flush();
    }
};

fn readBytes(comptime T: type, bytes: []const u8, pos: *usize, comptime offset: usize) T {
    const slice = bytes[pos.*..][0..offset];
    pos.* += offset;

    var arr: [offset]u8 = undefined;
    @memcpy(arr[0..], slice);
    return std.mem.readInt(T, arr[0..], .big);
}

fn parseEntry(allocator: std.mem.Allocator, data: []const u8, pos: *usize) !IndexEntry {
    // init an IndexEntry
    var entry: IndexEntry = undefined;

    // read 40 bytes of metadata 10xu32
    entry.ctime_s = readBytes(u32, data, pos, 4);
    entry.ctime_n = readBytes(u32, data, pos, 4);
    entry.mtime_s = readBytes(u32, data, pos, 4);
    entry.mtime_n = readBytes(u32, data, pos, 4);
    entry.dev = readBytes(u32, data, pos, 4);
    entry.ino = readBytes(u32, data, pos, 4);
    entry.mode = readBytes(u32, data, pos, 4);
    entry.uid = readBytes(u32, data, pos, 4);
    entry.gid = readBytes(u32, data, pos, 4);
    entry.size = readBytes(u32, data, pos, 4);

    // read sha 20 bytes
    @memcpy(&entry.sha, data[pos.*..][0..20]);
    pos.* += 20;

    // read flags
    entry.flags = readBytes(u16, data, pos, 2);
    const name_len = entry.flags & 0xFFF;

    // read path
    const path_buffer = try allocator.alloc(u8, name_len);
    @memcpy(path_buffer, data[pos.*..][0..name_len]);
    entry.path = path_buffer;
    pos.* += name_len;

    // Skip padding to 8-byte boundary
    const entry_size = 62 + name_len; // 62 = 40 (metadata) + 20 (sha) + 2 (flags)
    const padding = (8 - (entry_size % 8)) % 8;
    pos.* += padding;

    return entry;
}

fn writeEntry(writer: *std.Io.Writer, entry: IndexEntry) !void {
    try writer.writeInt(u32, entry.ctime_s, .big);
    try writer.writeInt(u32, entry.ctime_n, .big);
    try writer.writeInt(u32, entry.mtime_s, .big);
    try writer.writeInt(u32, entry.mtime_n, .big);
    try writer.writeInt(u32, entry.dev, .big);
    try writer.writeInt(u32, entry.ino, .big);
    try writer.writeInt(u32, entry.mode, .big);
    try writer.writeInt(u32, entry.uid, .big);
    try writer.writeInt(u32, entry.gid, .big);
    try writer.writeInt(u32, entry.size, .big);

    // write sha
    try writer.writeAll(&entry.sha);

    // Write flags
    const flags = @as(u16, @intCast(entry.path.len)) & 0xFFF;
    try writer.writeInt(u16, flags, .big);

    // Write path
    try writer.writeAll(entry.path);

    // Write padding
    const entry_size = 62 + entry.path.len;
    const padding = (8 - (entry_size % 8)) % 8;
    var i: usize = 0;
    while (i < padding) : (i += 1) {
        try writer.writeByte(0);
    }
}

fn lessThanPath(_: void, a: IndexEntry, b: IndexEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}
