const std = @import("std");
const commit = @import("commit.zig");

const c = @cImport({
    @cInclude("zlib.h");
});

const tree = @import("tree.zig");

pub const ObjectKind = enum {
    tree,
    blob,
    commit,
};

pub const ObjectContent = union(ObjectKind) {
    tree: []tree.Entry,
    blob: []const u8,
    commit: commit.Commit,
};

pub const Object = struct {
    // type: ObjectKind,
    size: usize,
    content: ObjectContent,
};

pub fn writeGitObject(allocator: std.mem.Allocator, type_name: []const u8, content: []const u8) ![20]u8 {
    const size = content.len;
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "{s} {d}\x00",
        .{ type_name, size },
    );

    var digest: [20]u8 = undefined;
    const data = try std.mem.concat(
        allocator,
        u8,
        &[_][]const u8{ header, content },
    );
    defer allocator.free(data);

    hashData(data, &digest);

    var hex_digest: [40]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = try std.fmt.bufPrint(hex_digest[i * 2 ..], "{x:0>2}", .{b});
    }

    const folder_name = hex_digest[0..2];
    const file_name = hex_digest[2..];

    const cwd = std.fs.cwd();

    var dir_buf: [64]u8 = undefined;
    const object_dir = try std.fmt.bufPrint(
        &dir_buf,
        ".git/objects/{s}",
        .{folder_name},
    );

    cwd.makePath(object_dir) catch |err| {
        // It's okay if it exists
        std.log.err("{}", .{err});
    };

    var path_buf: [128]u8 = undefined;
    const object_path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}",
        .{ object_dir, file_name },
    );

    // Check if exists to avoid rewriting? Git usually overwrites or ignores.
    // We'll write it.

    var object_file = try cwd.createFile(object_path, .{});
    defer object_file.close();

    var object_file_buffer: [4096]u8 = undefined;
    var object_writer = object_file.writer(&object_file_buffer);
    const object_out = &object_writer.interface;

    const compressed_data = try compressZlib(allocator, &.{data});
    defer allocator.free(compressed_data);

    try object_out.writeAll(compressed_data);

    try object_out.flush();
    return digest;
}

pub fn hashData(data: []const u8, digest: *[std.crypto.hash.Sha1.digest_length]u8) void {
    var hasher = std.crypto.hash.Sha1.init(.{});

    hasher.update(data);
    hasher.final(digest);
}

pub fn compressZlib(allocator: std.mem.Allocator, data: []const []const u8) ![]u8 {
    var strm: c.z_stream = undefined;
    strm.zalloc = null;
    strm.zfree = null;
    strm.@"opaque" = null;

    if (c.deflateInit(&strm, c.Z_DEFAULT_COMPRESSION) != c.Z_OK) {
        return error.ZlibInitFailed;
    }
    defer _ = c.deflateEnd(&strm);

    // Get length for upper bound
    var total_len: usize = 0;
    for (data) |part| {
        total_len += part.len;
    }

    // deflateBound gives an upper bound on compressed size
    // Adding some padding just in case, as zlib bound might be tight and we've had issues before
    const bound = c.deflateBound(&strm, @intCast(total_len)) + 64;
    const out_mem = try allocator.alloc(u8, @intCast(bound));
    errdefer allocator.free(out_mem);

    // crucial: init output ptrs
    strm.avail_out = @intCast(bound);
    strm.next_out = out_mem.ptr;
    // Loop through the parts
    for (data, 0..) |part, i| {
        strm.next_in = @constCast(part.ptr);
        strm.avail_in = @intCast(part.len);

        // crucial
        // if this is the LAST part, say z_finish
        // if not, say z_no_flush to keep stream open
        const flush_mode = if (i == data.len - 1) c.Z_FINISH else c.Z_NO_FLUSH;

        const ret = c.deflate(&strm, flush_mode);

        // error check
        if (ret == c.Z_STREAM_ERROR) {
            return error.ZlibCompressionFailed;
        }
    }

    const compressed_size = bound - strm.avail_out;
    // Resize to actual size used
    if (allocator.resize(out_mem, @intCast(compressed_size))) {
        return out_mem[0..@intCast(compressed_size)];
    } else {
        // Fallback if resize fails (unlikely to shrink in place but possible)
        const result = try allocator.dupe(
            u8,
            out_mem[0..@intCast(compressed_size)],
        );
        allocator.free(out_mem);
        return result;
    }
}

pub fn readHashObject(allocator: std.mem.Allocator, hash_data: []const u8) ![]u8 {
    var fmt_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&fmt_buf, ".git/objects/{s}/{s}", .{ hash_data[0..2], hash_data[2..] });
    const file = try std.fs.cwd().openFile(path, .{});

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const decompressed_content = try decompressZlib(allocator, content);
    // defer allocator.free(decompressed_content);

    // NOTE: test decompressed content output
    // 313452bbb2ff3e71420c695dcf7e19a4181c6011
    //
    // const print_len = @min(decompressed_content.len, 50);
    // std.debug.print("decompressed_content: {s}", .{decompressed_content[0..print_len]});

    return decompressed_content;
}

fn decompressZlib(allocator: std.mem.Allocator, compressed_data: []const u8) ![]u8 {
    var strm: c.z_stream = undefined;
    strm.zalloc = null;
    strm.zfree = null;
    strm.@"opaque" = null;
    strm.next_in = @constCast(compressed_data.ptr);
    strm.avail_in = @intCast(compressed_data.len);

    if (c.inflateInit(&strm) != c.Z_OK) {
        return error.ZlibInitFailed;
    }
    defer _ = c.inflateEnd(&strm);

    var decompressed = try std.ArrayList(u8).initCapacity(allocator, 1024);
    errdefer decompressed.deinit(allocator);

    var buf: [4098]u8 = undefined;

    while (true) {
        strm.next_out = &buf;
        strm.avail_out = buf.len;

        const ret = c.inflate(&strm, c.Z_NO_FLUSH);

        if (ret != c.Z_OK and ret != c.Z_STREAM_END) {
            return error.ZlibDecompressFailed;
        }

        const have = buf.len - strm.avail_out;
        try decompressed.appendSlice(allocator, buf[0..have]);

        if (ret == c.Z_STREAM_END) {
            break;
        }
    }

    return decompressed.toOwnedSlice(allocator);
}
