//! This is a zig rewrite of the example shown in
//! https://unixism.net/loti/low_level.html The overall procedure is as
//! follows:
//! - Set up the io_uring
//! - Submit the job
//! - Wait for the job to complete
//! - Read from the completion queue
//!
//! Std lib in zig does have its own io_uring wrapper neatly packaged in
//! std.os.linux.IoUring But for the sake of learning the low level nitty
//! gritty, we shall follow along the tutorial which does all the set up on our
//! own
//!
//! Setting up the job is somewhat more involved than submitting them. And they
//! are roughly the following:
//! - Set up buffers for indirection submission ring
//! buffer, actual submission ring buffer, and completion ring buffer
//! - Map memory into shared space for indirect submission queue
//! - Map memory into shared space for actual submission queue
//! - Map memory into shared space for completion queue
//! - Note down all the important offset and pointers for the aforementioned
//!   steps for look up later
//!
//! Submitting jobs is somewhat dependent on the operation you are asking of
//! the kernal. In this example (reading a file and catting it), you would need
//! to perform the following: - Open the file - Calculate the chunk read sizes
//! (i.e. use of iovecs) - Add the SQE to the tail of the SQE ring - Submit the
//! job and block until I/O is completed via `io_uring_enter` (see more details
//! for this api
//! [here](https://man7.org/linux/man-pages/man2/io_uring_enter.2.html))

const std = @import("std");
const explore = @import("explore");
const linux = std.os.linux;
const print = std.debug.print;

const Iovec = std.posix.iovec;
const Cqe = linux.io_uring_cqe;
const IoUringParams = linux.io_uring_params;
const IoUringSqe = linux.io_uring_sqe;
const io_uring_setup = linux.io_uring_setup;

// There is a "raw" version of mmap (std.linux.mmap) that is less compatible
// with idiomatic zig so we will use this version instead
const mmap = std.posix.mmap;

const IORING_OFF_SQ_RING = @as(i64, linux.IORING_OFF_SQ_RING);
const IORING_OFF_CQ_RING = @as(i64, linux.IORING_OFF_CQ_RING);
const QUEUE_DEPTH: u32 = 1;
const BLOCK_SZ: u64 = 1024;

/// Ring buffer for submission queue
/// The fields are pointer to u32, which is owned by the kernal.
const AppIoSqRing = struct {
    /// Consumer position. Points to the next entry to be consumed (by the kernal)
    head: *u32,

    /// Producer position. Points to the next slot to write into (by the user)
    tail: *u32,

    /// Used to wrap the ring buffer (because this is more efficient than modulo)
    ring_mask: *u32,

    /// Size of the ring buffer
    ring_entries: *u32,

    /// Flags for io_uring
    flags: *u32,

    /// An indirect array that indexes into the actual submission buffer
    array: [*]u32,
};

/// Ring buffer for completion queue
/// The fields are pointer to u32, which is owned by the kernal
const AppIoCqRing = struct {
    /// Consumer position. Points to the next entry to be consumed (by the user)
    head: *u32,

    /// Producer position. Points to the next slot to write into (by the kernal)
    tail: *u32,

    /// Used to wrap the ring buffer (because this is more efficient than modulo)
    ring_mask: *u32,

    /// Size of the ring buffer
    ring_entries: *u32,

    /// The actual buffer for completion queue (completion queue does not need
    /// an indirect queue)
    cqes: [*]Cqe,
};

const Submitter = struct {
    /// Ring file descriptor. This is used to identify the queue sets this
    /// submitter is associated with
    ring_fd: i32,

    /// Associated ring buffer for submission queue
    sq_ring: AppIoSqRing,

    /// Associated ring buffer for completion queue (this one contains the
    /// index into the sqes array
    cq_ring: AppIoCqRing,

    /// Submission queue entries array (this one contains the actual submission
    /// entries)
    sqes: [*]IoUringSqe,
};

/// This is user data used in this example
/// User data is attached to submission and copied onto the completion when it
/// is done. The purpose of user data is to serve as task context that way
/// whatever logic you write to wrap io_uring would be able to understand what
/// to do next
const FileInfo = struct {
    file_size: u64,
    iovecs: []std.posix.iovec,

    pub fn create(
        alloc: std.mem.Allocator,
        file_size: u64,
        iovec_len: usize,
    ) !*FileInfo {
        const self = try alloc.create(FileInfo);
        errdefer alloc.destroy(self);

        const iovecs = try alloc.alloc(std.posix.iovec, iovec_len);
        self.* = .{ .file_size = file_size, .iovecs = iovecs };

        return self;
    }

    pub fn destroy(self: *FileInfo, alloc: std.mem.Allocator) void {
        // Free each buffer that the iovecs point to
        // The buffers were allocated with BLOCK_SZ alignment, so we need to preserve that
        for (self.iovecs) |iov| {
            const buf: []align(BLOCK_SZ) u8 = @as([*]align(BLOCK_SZ) u8, @ptrCast(@alignCast(iov.base)))[0..BLOCK_SZ];
            alloc.free(buf);
        }
        alloc.free(self.iovecs);
        alloc.destroy(self);
    }
};

const SetupError = error{
    IoUringSetupError,
    IoUringSubmitError,
    IoUringReadError,
};

/// This is the set up routine. And it should be doing the following:
/// 1. Calls io_uring_setup to obtain the associated fd from the kernal. You
///    need the fd in order for the subseqent mmap calls to understand what to
///    allocate for you.
/// 2. Map memory from user space to pre-allocated memory (done in the previous
///    step) for submission index buffer, submission entry buffer, and completion
///    buffer.
/// 3. Note down important values that is needed for completion retrieval later
///    onto the [Submitter]. These include:
///    - Submission index buffer head and tail offset
///    - Submission index buffer ring mask offset
///    - Submission index buffer ring entries offset (this is referring to
///      number of entries)
///    - Submission index buffer flags offset
///    - Submission index buffer array offset
///    - Completion buffer head and tail offset
///    - Completion buffer ring mask offset
///    - Completion buffer ring entries offset (this is referring to number of
///      entries)
///    - Completion buffer entries offset (this is referring to the actual
///      entries)
///    The offset is used to calculate the pointer in which their respective
///    values are stored based on the pointer returned from mmap. The reason
///    why you would need to retrieve this information during runtime is
///    because these offsets can change with the kernal versions.
fn appSetupRing(submitter: *Submitter) !void {
    // Need to zero this otherwise the call to set up would fail.
    var params = std.mem.zeroes(IoUringParams);
    const sring = &submitter.sq_ring;
    const cring = &submitter.cq_ring;
    const fd = io_uring_setup(QUEUE_DEPTH, &params);

    // Linux syscalls return errors as negative values wrapped in usize
    // Check if the result is an error by casting to isize
    const fd_signed: isize = @bitCast(fd);
    if (fd_signed < 0) {
        return error.IoUringSetupError;
    }

    submitter.ring_fd = @intCast(fd_signed);

    const sring_size_in_bytes = @as(usize, params.sq_off.array) + @as(usize, params.sq_entries) * @sizeOf(u32);
    var cring_size_in_bytes = @as(usize, params.cq_off.cqes) + @as(usize, params.cq_entries) * @sizeOf(Cqe);
    const sqe_size_in_bytes = @as(usize, params.sq_entries) * @as(usize, @sizeOf(IoUringSqe));

    if (params.features & linux.IORING_FEAT_SINGLE_MMAP > 0) {
        if (sring_size_in_bytes > cring_size_in_bytes) {
            cring_size_in_bytes = sring_size_in_bytes;
        }
        cring_size_in_bytes = sring_size_in_bytes;
    }

    // Mapping submission index array
    const sq_ptr = try mmap(
        null,
        sring_size_in_bytes,
        linux.PROT.READ | linux.PROT.WRITE,
        .{ .TYPE = .SHARED, .POPULATE = true },
        submitter.ring_fd,
        linux.IORING_OFF_SQ_RING,
    );

    // Mapping completion entries array
    // Here we would also have to consider the possibility of array
    // consolidation
    var cq_ptr: []u8 = undefined;
    if (params.features & linux.IORING_FEAT_SINGLE_MMAP > 0) {
        cq_ptr = sq_ptr;
    } else {
        cq_ptr = try mmap(
            null,
            cring_size_in_bytes,
            linux.PROT.READ | linux.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            submitter.ring_fd,
            linux.IORING_OFF_CQ_RING,
        );
    }

    // Mapping submission entries array
    const sqe_ptr = try mmap(
        null,
        sqe_size_in_bytes,
        linux.PROT.READ | linux.PROT.WRITE,
        .{ .TYPE = .SHARED, .POPULATE = true },
        submitter.ring_fd,
        linux.IORING_OFF_SQES,
    );

    // Save all the important values so we can recall later
    const sq_ptr_in_int = @intFromPtr(sq_ptr.ptr);
    sring.head = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.head)));
    sring.tail = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.tail)));
    sring.ring_mask = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.ring_mask)));
    sring.ring_entries = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.ring_entries)));
    sring.flags = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.flags)));
    sring.array = @ptrFromInt(sq_ptr_in_int + @as(usize, @intCast(params.sq_off.array)));

    submitter.sqes = @ptrCast(@alignCast(sqe_ptr));

    const cq_ptr_in_int = @intFromPtr(cq_ptr.ptr);
    cring.head = @ptrFromInt(cq_ptr_in_int + @as(usize, @intCast(params.cq_off.head)));
    cring.tail = @ptrFromInt(cq_ptr_in_int + @as(usize, @intCast(params.cq_off.tail)));
    cring.ring_mask = @ptrFromInt(cq_ptr_in_int + @as(usize, @intCast(params.cq_off.ring_mask)));
    cring.ring_entries = @ptrFromInt(cq_ptr_in_int + @as(usize, @intCast(params.cq_off.ring_entries)));
    cring.cqes = @ptrFromInt(cq_ptr_in_int + @as(usize, @intCast(params.cq_off.cqes)));
}

fn readFromCq(submitter: *Submitter) !void {
    const cring = &submitter.cq_ring;
    var head: u32 = 0;
    const mask = submitter.cq_ring.ring_mask.*;

    head = cring.head.*;

    while (true) {
        if (head == cring.tail.*)
            break;

        const cqe = &cring.cqes[head & mask];
        const file_info: *FileInfo = @ptrFromInt(cqe.user_data);

        if (cqe.res < 0)
            return error.IoUringReadError;

        const blocks: u32 = @intCast(try std.math.divCeil(u64, file_info.file_size, BLOCK_SZ));

        for (0..blocks) |i| {
            const index: usize = @intCast(i);
            const buf = file_info.iovecs[index].base;
            const len = file_info.iovecs[index].len;
            const buf_to_print = buf[0..len];
            print("{s}\n", .{buf_to_print});
        }

        head += 1;
    }
}

/// Submit to submission queue
/// In this example the OP is hardcoded to be readv (and so along submitter
/// there is also the path of the file to be read)
/// Specific to this example, this function does the following:
/// 1. Opens a file to get its size
/// 2. Chunk the file and, in accordance to the read segment size, arrange the
///    array needed to complete the read ()
/// 3. Populate the necessary fields on the sqe and assign it to the sqe queue
/// 4. Update metadata fields on submission index buffer (e.g. head, tail)
fn submitToSq(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    submitter: *Submitter,
) !void {
    // We don't want to actually read the file here (we want to use the io_uring to do it)
    // So here all we are doing is opening the file to get its metadata
    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try std.fs.cwd().realpath(file_path, &out_buf);
    const file = try std.fs.openFileAbsolute(real_path, .{});
    defer file.close();

    var bytes_remaining = (try file.stat()).size;
    const file_size = bytes_remaining;
    const sring = &submitter.sq_ring;
    var index: u32 = 0;
    var current_block: u32 = 0;
    var tail: u32 = 0;
    var next_tail: u32 = 0;
    const iovecs_len: usize = @intCast(try std.math.divCeil(u64, file_size, BLOCK_SZ));

    const file_info = try FileInfo.create(alloc, file_size, iovecs_len);
    errdefer file_info.destroy(alloc);

    while (bytes_remaining > 0) {
        const bytes_to_read = @min(bytes_remaining, BLOCK_SZ);

        const buf = try alloc.alignedAlloc(
            u8,
            std.mem.Alignment.fromByteUnits(BLOCK_SZ),
            BLOCK_SZ,
        );

        file_info.iovecs[current_block].len = bytes_to_read;
        file_info.iovecs[current_block].base = buf.ptr;

        current_block += 1;
        bytes_remaining -= bytes_to_read;
    }

    next_tail = sring.tail.*;
    tail = sring.tail.*;
    next_tail += 1;
    index = tail & submitter.sq_ring.ring_mask.*;
    const sqe = &submitter.sqes[index];
    sqe.fd = file.handle;
    sqe.flags = 0;
    sqe.opcode = .READV;
    sqe.addr = @intFromPtr(file_info.iovecs.ptr);
    sqe.len = @intCast(iovecs_len);
    sqe.off = 0;
    sqe.user_data = @intFromPtr(file_info);
    sring.array[index] = index;
    tail = next_tail;

    if (sring.tail.* != tail) {
        sring.tail.* = tail;
    }

    const ret = linux.io_uring_enter(
        submitter.ring_fd,
        1,
        1,
        linux.IORING_ENTER_GETEVENTS,
        null,
    );
    if (ret < 0) {
        return error.IoUringSubmitError;
    }
}

fn testEntryPoint(
    alloc: std.mem.Allocator,
    file_path: []const u8,
) !void {
    var submitter: Submitter = undefined;
    // This is a hack as we are hardcoding the effective length of the queue to
    // 1
    defer {
        const sqes = submitter.sqes;
        const user_data = sqes[0].user_data;
        const file_info: *FileInfo = @ptrFromInt(user_data);
        file_info.destroy(alloc);
    }

    try appSetupRing(&submitter);

    try submitToSq(alloc, file_path, &submitter);

    try readFromCq(&submitter);
}

test "io uring basic example" {
    const alloc = std.testing.allocator;
    testEntryPoint(alloc, "build.zig") catch unreachable;
}
