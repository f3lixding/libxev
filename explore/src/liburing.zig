//! This is the same example as raw.zig. Except this is using libruing
//! In Zig liburing is packaged in LibUring

const std = @import("std");
const linux = std.os.linux;
const IoUring = linux.IoUring;

const BLOCK_SZ: u64 = 1024;

const ExampleError = error{
    IoUringSetupError,
    IoUringSubmitError,
    IoUringReadError,
};

/// This is user data used in this example
/// User data is attached to submission and copied onto the completion when it
/// is done. The purpose of user data is to serve as task context that way
/// whatever logic you write to wrap io_uring would be able to understand what
/// to do next
const FileInfo = struct {
    file_size: u64,
    buffer: []u8,
    fd: std.posix.fd_t,

    pub fn create(
        alloc: std.mem.Allocator,
        file_size: u64,
        fd: std.posix.fd_t,
    ) !*FileInfo {
        const self = try alloc.create(FileInfo);
        errdefer alloc.destroy(self);

        const buffer = try alloc.alloc(u8, @intCast(file_size));

        self.file_size = file_size;
        self.buffer = buffer;
        self.fd = fd;

        return self;
    }

    pub fn destroy(self: *FileInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.buffer);
        std.posix.close(self.fd);
        alloc.destroy(self);
    }

    pub fn printToStdout(self: *FileInfo) void {
        const to_print = self.buffer;
        std.debug.print("{s}\n", .{to_print});
    }
};

fn getCompletionAndPrint(alloc: std.mem.Allocator, ring: *IoUring) !void {
    const cqe = try ring.copy_cqe();
    if (cqe.res < 0)
        return error.IoUringReadError;

    const file_info: *FileInfo = @ptrFromInt(cqe.user_data);
    defer file_info.destroy(alloc);

    file_info.printToStdout();
}

fn submitReadRequest(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    ring: *IoUring,
) !void {
    // We don't want to actually read the file here (we want to use the io_uring to do it)
    // So here all we are doing is opening the file to get its metadata
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(file_path, &out_buf);
    const file = try std.fs.openFileAbsolute(real_path, .{});

    const file_size = (try file.stat()).size;
    const file_info = try FileInfo.create(alloc, file_size, file.handle);
    const buffer = file_info.buffer;

    _ = try ring.read(
        @intFromPtr(file_info),
        file.handle,
        .{ .buffer = buffer },
        0,
    );

    if (try ring.submit() == 0) {
        return error.IoUringSubmitError;
    }
}

fn testEntryPoint(
    alloc: std.mem.Allocator,
    file_path: []const u8,
) !void {
    var ring = try IoUring.init(1, 0);
    defer ring.deinit();

    try submitReadRequest(alloc, file_path, &ring);

    try getCompletionAndPrint(alloc, &ring);
}

test "io uring lib uring example" {
    const alloc = std.testing.allocator;
    testEntryPoint(alloc, "build.zig") catch unreachable;
}
