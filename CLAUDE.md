# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

libxev is a cross-platform event loop library written in Zig with a C-compatible API. It provides unified event loop abstraction for non-blocking I/O, timers, TCP/UDP sockets, files, processes, and more across macOS, Linux, Windows, and WebAssembly platforms.

## Build System & Commands

This project uses Zig's build system with Nix for dependency management:

- **Build the library**: `nix build` or `zig build install`
- **Run tests**: `zig build test`
- **Cross-compile tests**: `zig build -Dtarget=<target> -Dinstall-tests`
- **WASI tests**: `zig build test -Dtarget=wasm32-wasi -Dwasmtime`
- **Build examples**: `zig build -Dexample-name=<filename>`
- **Build benchmarks**: `zig build -Demit-bench`
- **Generate man pages**: `zig build -Dman-pages` (requires scdoc)

The project requires Zig 0.15.1 and has no other runtime dependencies.

## Architecture Overview

### Backend System
libxev uses a compile-time backend selection system:

- **Linux**: io_uring (default), epoll (fallback)
- **macOS/iOS**: kqueue
- **FreeBSD**: kqueue  
- **Windows**: IOCP
- **WASI**: wasi_poll

The main API (`src/main.zig`) forwards the default backend for the target platform. Backend-specific implementations are in `src/backend/`.

### Core Components

- **Loop**: Event loop implementation (`src/loop.zig`)
- **Watchers**: High-level abstractions in `src/watcher/` for:
  - TCP/UDP sockets
  - File operations
  - Timers
  - Processes
  - Async operations
- **ThreadPool**: Generic thread pool for blocking operations (`src/ThreadPool.zig`)
- **Dynamic API**: Runtime backend selection (`src/dynamic.zig`)

### API Layers

1. **High-level API**: Platform-agnostic watchers (TCP, UDP, Timer, etc.)
2. **Low-level API**: Platform-specific backends with minimal abstraction
3. **C API**: C-compatible interface (`src/c_api.zig`)

### Key Design Patterns

- **Proactor Pattern**: Operations complete asynchronously, callbacks signal completion
- **Zero Runtime Allocations**: Memory management handled at compile/init time
- **Tree Shaking**: Unused functionality excluded from final binary
- **Completion-based**: Work submitted to loop, completion callbacks fired when done

## Testing

Tests are organized by platform and backend. Use `zig build test` to run all tests for the current platform. Cross-compilation testing is supported for validation on other platforms.

## Documentation

Comprehensive man pages in `docs/` provide detailed API documentation. Examples in `examples/` show both Zig and C usage patterns.