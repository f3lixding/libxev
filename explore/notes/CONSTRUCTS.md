# Loop 

The central event loop that manages all I/O operations. It's backend-specific
(io_uring, epoll, kqueue) but provides a unified interface. This means that a
Loop is composed of a concrete backend implementation (see
[Backends](#Backends)).

# Completion 

Represents an operation that will complete asynchronously. This is akin to
future or promise. The structure of which has two main parts: 
- Async op (these are ops that are understood by the kernal, such as file write
  or read) 
- Callback, or work you want to have done by the time the aforementioned async
  op is completed

# Watchers 

High-level abstractions for different types of operations: 
- **Timer**: Schedule callbacks after time delays
- **TCP/UDP**: Network socket operations fh
- **File**: Async file I/O
- **Process**: Process management
- **Async**: Custom async operations

# Callbacks 

Functions that get invoked when operations complete. They return a
_CallbackAction_ (continue, disarm, rearm) to control the watcher's lifecycle.

# Backends 

Platform-specific implementations: 
- **io_uring** (linux) - Modern async I/O interface
- **epoll** (linux) - Traditional I/O multiplexing
- **kqueue** (macOS/BSD) - BSD's event notification system
- **IOCP** (windows) - I/O Completion Ports

# ThreadPool 

For operations that can't be made truly async (like file I/O on some
platforms), work gets dispatched to background threads. 

The key insight is that libxev uses a **proactor pattern** - you submit work
and get callbacks when it's complete , rather than polling for readiness (which
is what tokio-rs is). This makes the API consistent across all platforms, even
though the underlying mechanisms differ significantly. 

