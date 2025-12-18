// These are our subcommands.
const SubCommands = enum {
    help,
    init,
    status,
    commit,
    hash_object,
    cat_file,
    write_tree,
    open,
    add,
};

const main_parsers = .{
    .command = clap.parsers.enumeration(SubCommands),
};

// The parameters for `main`. Parameters for the subcommands are specified further down.
const main_params = clap.parseParamsComptime(
    \\-h, --help  Display this help and exit.
    \\<command>
    \\
);

pub fn main() !void {
    var alloc = std.heap.DebugAllocator(.{}){};
    const allocator = alloc.allocator();
    defer {
        if (alloc.deinit() == .leak) {
            std.log.err("Leaking\n", .{});
        }
    }

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &main_params,
        main_parsers,
        &iter,
        .{
            .diagnostic = &diag,
            .allocator = allocator,

            // Terminate the parsing of arguments after parsing the first positional (0 is passed
            // here because parsed positionals are, like slices and arrays, indexed starting at 0).
            //
            // This will terminate the parsing after parsing the subcommand enum and leave `iter`
            // not fully consumed. It can then be reused to parse the arguments for subcommands.
            .terminating_positional = 0,
        },
    ) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        std.debug.print("--help\n", .{});

    const command = res.positionals[0] orelse return error.MissingCommand;
    switch (command) {
        .help => std.debug.print("--help\n", .{}),
        .status => std.debug.print("--status\n", .{}),
        .init => {
            repo_mod.initDirs() catch |err| {
                std.log.err("error init git: {}\n", .{err});
            };
        },
        .hash_object => {
            initHashObjects(allocator, &iter) catch |err| {
                std.log.err("error hashing object: {}\n", .{err});
            };
        },
        // .cat_file => {
        //     try catFile(allocator, &iter);
        // },
        .commit => {
            try writeCommit(allocator, &iter);
        },
        .open => {
            try repo_mod.open(allocator);
        },
        .write_tree => {
            _ = try writeTree(allocator);
        },
        .cat_file => {
            try repo_mod.readAllFile(allocator);
        },
        .add => {
            // var cwd = std.fs.cwd();

            var paths = try std.ArrayList([]const u8).initCapacity(allocator, 512);
            defer paths.deinit(allocator);

            var any_files = false;

            while (iter.next()) |arg| {
                if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                    std.debug.print("usage: zit add <path>...\n", .{});
                    return;
                }

                any_files = true;
                try paths.append(allocator, arg);
            }

            if (!any_files) {
                std.debug.print("Nothing specified, nothing added.\n", .{});
                return;
            }

            var index = index_mod.Index.read(allocator) catch |err| switch (err) {
                // if there is no existing index yet, start with an empty one.
                error.FileNotFound => try index_mod.Index.init(allocator),
                else => return err,
            };
            defer index.deinit();

            // var dir = std.fs.cwd();
            try walkDirs(allocator, &index, paths.items, "");

            try index.write();
        },
    }
}

const WalkDirsTaskCtx = struct {
    /// Thread-safe allocator for temporary work done by worker threads (hashing/compression).
    tmp_allocator: std.mem.Allocator,

    index: *index_mod.Index,

    /// One mutex guarding both index mutations and the shared error slot.
    mutex: *std.Thread.Mutex,
    // first_err: *?anyerror,
};

fn walkDirsTask(ctx: *WalkDirsTaskCtx, path: []const u8) void {
    addFileMt(ctx.tmp_allocator, ctx.index, ctx.mutex, path) catch |err| {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        std.debug.print("error: {}\n", .{err});
        return;
        // if (ctx.first_err.* == null) ctx.first_err.* = err;
    };
}

fn collectFiles(
    allocator: std.mem.Allocator,
    out_files: *std.ArrayList([]u8),
    paths: []const []const u8,
    dir_path: []const u8,
) !void {
    for (paths) |leaf_path| {
        const dir = std.fs.cwd();
        const full_path = try std.fs.path.join(
            allocator,
            &[_][]const u8{ dir_path, leaf_path },
        );
        defer allocator.free(full_path);

        const stat_file = try dir.statFile(full_path);
        if (stat_file.kind == .directory) {
            var sub_dir = dir.openDir(
                full_path,
                .{ .iterate = true },
            ) catch |err| {
                std.debug.print("error opening dir: {s}\n", .{full_path});
                return err;
            };
            defer sub_dir.close();

            var sub_iter = sub_dir.iterate();
            while (try sub_iter.next()) |entry| {
                // NOTE: `entry.name` is only valid until the next `next()` call.
                // We only use it to build `full_path` within this call, so it's safe.
                try collectFiles(
                    allocator,
                    out_files,
                    &[_][]const u8{entry.name},
                    full_path,
                );
            }
        } else {
            // Store an owned copy so worker threads can read the slice safely.
            const owned_path = try allocator.dupe(u8, full_path);
            errdefer allocator.free(owned_path);
            try out_files.append(allocator, owned_path);
        }
    }
}

fn walkDirs(allocator: std.mem.Allocator, index: *index_mod.Index, paths: []const []const u8, dir_path: []const u8) !void {
    // First, collect all file paths. This keeps directory traversal single-threaded
    // while allowing file hashing/indexing to run in parallel.
    var files = try std.ArrayList([]u8).initCapacity(allocator, 1024);
    defer {
        for (files.items) |p| allocator.free(p);
        files.deinit(allocator);
    }

    try collectFiles(allocator, &files, paths, dir_path);
    if (files.items.len == 0) return;

    // Use a thread-safe allocator wrapper for tasks executed by the thread pool.
    var tsa = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
    const t_allocator = tsa.allocator();

    var mutex = std.Thread.Mutex{};
    // var first_err: ?anyerror = null;

    var task_ctx: WalkDirsTaskCtx = .{
        .tmp_allocator = t_allocator,
        .index = index,
        .mutex = &mutex,
        // .first_err = &first_err,
    };

    const cpus = std.Thread.getCpuCount() catch |err| blk: {
        std.debug.print("get cpu error: {}\n", .{err});
        break :blk 1;
    };

    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator, .n_jobs = cpus });
    defer pool.deinit();

    var wg: std.Thread.WaitGroup = .{};

    // One task per file. `spawnWg` will call `wg.start()` / `wg.finish()` automatically.
    for (files.items) |path| {
        pool.spawnWg(&wg, walkDirsTask, .{ &task_ctx, path });
    }

    wg.wait();

    // if (first_err) |err| return err;
}

fn addFileMt(
    allocator: std.mem.Allocator,
    index: *index_mod.Index,
    index_mutex: *std.Thread.Mutex,
    path: []const u8,
) !void {
    // get file stats
    var dir = std.fs.cwd();
    const stat = try dir.statFile(path);
    const file = try dir.openFile(path, .{});
    defer file.close();
    const stat_os = try std.posix.fstat(file.handle);

    // hash file as blob (expensive) - do this outside the index lock.
    const blob_hash = try blob_mod.writeBlob(allocator, &dir, path);

    // Create index entry
    const mode: u32 = if (stat.mode & 0o100 != 0) 0o100755 else 0o100644;

    {
        // Index entries own their `path` and will free it using `index.allocator`.
        // Keep ownership consistent: allocate the path with the same allocator.
        index_mutex.lock();
        defer index_mutex.unlock();

        const path_copy = try index.allocator.dupe(u8, path);
        errdefer index.allocator.free(path_copy);

        const entry = index_mod.IndexEntry{
            .ctime_s = @intCast(@divFloor(stat.ctime, std.time.ns_per_s)),
            .ctime_n = @intCast(@mod(stat.ctime, std.time.ns_per_s)),
            .mtime_s = @intCast(@divFloor(stat.mtime, std.time.ns_per_s)),
            .mtime_n = @intCast(@mod(stat.mtime, std.time.ns_per_s)),
            .dev = @intCast(stat_os.dev),
            .ino = @intCast(stat_os.ino),
            .mode = mode,
            .uid = 0, // git doesn't track these on all platforms
            .gid = 0,
            .size = @intCast(stat.size),
            .sha = blob_hash,
            .flags = 0,
            .path = path_copy,
        };

        try index.addEntry(entry);
    }

    // Avoid holding the index mutex while printing.
    std.debug.print("added '{s}'\n", .{path});
}

fn findParentHash(allocator: std.mem.Allocator, dir: *std.fs.Dir) !?[20]u8 {
    const file = dir.readFileAlloc(
        allocator,
        ".git/HEAD",
        1024,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        else => {
            return err;
        },
    };

    defer allocator.free(file);

    const content = std.mem.trimRight(u8, file, "\n\r ");

    // init
    var ref_path: []const u8 = undefined;

    if (std.mem.startsWith(u8, content, "ref: ")) {
        ref_path = content[5..];
    } else {
        // head is detached
        var parent: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&parent, content);
        return parent;
    }

    const ref_path_full = try std.fs.path.join(allocator, &.{ ".git", ref_path });
    defer allocator.free(ref_path_full);

    const ref_content = dir.readFileAlloc(
        allocator,
        ref_path_full,
        1024,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            return null;
        },
        else => {
            return err;
        },
    };
    defer allocator.free(ref_content);

    const ref_content_trimmed = std.mem.trimRight(u8, ref_content, "\n\r ");
    var parent_sha: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&parent_sha, ref_content_trimmed) catch |err| {
        std.log.err("hex error for parent_sha{}\n", .{err});
        return err;
    };
    return parent_sha;
}

fn writeTree(allocator: std.mem.Allocator) ![20]u8 {
    var tree = tree_mod.Tree.init(allocator) catch |err| {
        std.debug.print("error init tree object: {}\n", .{err});
        return err;
    };
    defer tree.deinit();

    var cwd = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer cwd.close();
    const root_entry = tree.write(&cwd) catch |err| {
        std.debug.print("error write_tree : {}\n", .{err});
        return err;
    };

    std.debug.print(" tree hash: {s}\n", .{root_entry});

    return root_entry;
}

fn writeCommit(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    var commit_msg = try std.ArrayList(u8).initCapacity(allocator, 1024);
    defer commit_msg.deinit(allocator);

    var has_arg = false;
    while (iter.next()) |arg| {
        has_arg = true;
        if (std.mem.eql(u8, "-m", arg)) {
            const message = iter.next();
            if (message) |value| {
                try commit_msg.appendSlice(allocator, value);
            } else {
                std.log.info("message must not be empty", .{});
                return;
            }
        } else {
            std.log.info("message must not be empty", .{});
            return;
        }
    }

    if (!has_arg) {
        std.log.err("commit message is missing \n", .{});
        return;
    }

    var index = index_mod.Index.read(allocator) catch |err| switch (err) {
        // if there is no existing index yet, start with an empty one.
        error.FileNotFound => try index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    var tree = try tree_mod.Tree.init(allocator);
    defer tree.deinit();

    const tree_hash = try tree.writeFromIndex(index.entries.items);

    var cwd = std.fs.cwd();
    const parent_hash: ?[20]u8 = try findParentHash(allocator, &cwd);

    const commit_hash = try commit_mod.writeCommit(
        allocator,
        tree_hash,
        parent_hash,
        "duong.nguyen",
        commit_msg.items,
    );

    const head_file = try std.fs.cwd().createFile(".git/refs/heads/main", .{ .read = true });
    defer head_file.close();

    var buffer: [4096]u8 = undefined;
    var write_wrapper = head_file.writer(&buffer);
    const writer = &write_wrapper.interface;

    const hex_commit: [40]u8 = std.fmt.bytesToHex(commit_hash, .lower);

    try writer.writeAll(&hex_commit);
    try writer.writeAll("\n");
    try writer.flush();
}

fn initHashObjects(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\-w, --write <STR>... write blob 
        \\
    );
    const parser = comptime .{
        .STR = clap.parsers.string,
    };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        parser,
        iter,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
            .assignment_separators = "=:",
        },
    ) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        std.debug.print("--help\n", .{});
    for (res.args.write) |filename| {
        var dir = std.fs.cwd();

        _ = try blob_mod.writeBlob(allocator, &dir, filename);
    }
}

fn catFile(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    // B. Reading Objects (cat-file)
    // Implement git cat-file -p <hash>.
    //
    // Locate: Find the file based on the hash string.
    //
    // Decompress: Read and inflate the Zlib stream.
    //
    // Parse: Split the header (blob 12\0) from the body.
    //
    // Output: Print the body to stdout.
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\-p, --parse <STR> write blob 
        \\
    );
    const parser = comptime .{
        .STR = clap.parsers.string,
    };
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(
        clap.Help,
        &params,
        parser,
        iter,
        .{
            .diagnostic = &diag,
            .allocator = allocator,
            .assignment_separators = "=:",
        },
    ) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        std.debug.print("--help\n", .{});
    if (res.args.parse) |hash| {
        // hash: []const u8
        object_mod.readHashObject(allocator, hash) catch |err| {
            std.log.err("{}\n", .{err});
        };
    }
}

const std = @import("std");
const clap = @import("clap");

const blob_mod = @import("blob.zig");
const object_mod = @import("object.zig");
const repo_mod = @import("repo.zig");
const tree_mod = @import("tree.zig");
const commit_mod = @import("commit.zig");
const index_mod = @import("index.zig");
