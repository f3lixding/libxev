# Cancellation

This is very different from how it is done in reactor land. And thus it is
worth documenting.

In io_uring backend, the loop cancel is done with
[IORING_OP_ASYNC_CANCEL](https://man7.org/linux/man-pages/man2/io_uring_enter.2.html)

Cancel impl (io_uring): [src/backend/io_uring.zig] L565

For usage, take a look at the same file but on L1727. This is a test but
it should suffice to show how the api is used.

From the man page, it stated that the location of the target submission is done
via user data. User data is made known to the kernal via passing a pointer.
Therefore you would need to pass the pointer of the user data to the cancel api
as well. 
In this library, this pointer is `Completion`, and it is passed to the kernal on L559.
