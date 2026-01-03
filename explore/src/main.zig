test {
    const std = @import("std");
    std.testing.refAllDecls(@This());

    inline for (.{
        @import("raw.zig"),
        @import("liburing.zig"),
    }) |source_file| std.testing.refAllDeclsRecursive(source_file);
}
