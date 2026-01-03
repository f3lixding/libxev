# Sources 

[Welcome to the lord of io uring](https://unixism.net/loti/)

# Mental Model

[source](https://unixism.net/loti/what_is_io_uring.html#the-mental-model)

- There are 2 ring buffers, one for submission of requests (submission queue or
  SQ) and the other that informs you about completion of those requests
  (completion queue or CQ).
- These ring buffers are shared between kernel and user space. You set these up
  with io_uring_setup() and then mapping them into user space with 2 mmap(2)
  calls.
- You tell io_uring what you need to get done (read or write a file, accept
  client connections, etc), which you describe as part of a submission queue
  entry (SQE) and add it to the tail of the submission ring buffer.
- You then tell the kernel via the io_uring_enter() system call that you’ve
  added an SQE to the submission queue ring buffer. You can add multiple SQEs
  before making the system call as well.
- Optionally, io_uring_enter() can also wait for a number of requests to be
  processed by the kernel before it returns so you know you’re ready to read
  off the completion queue for results.
- The kernel processes requests submitted and adds completion queue events
  (CQEs) to the tail of the completion queue ring buffer.
- You read CQEs off the head of the completion queue ring buffer. There is one
  CQE corresponding to each SQE and it contains the status of that particular
  request.
- You continue adding SQEs and reaping CQEs as you need.
- There is a polling mode available, in which the kernel polls for new entries
  in the submission queue. This avoids the system call overhead of calling
  io_uring_enter() every time you submit entries for processing.
