pub export fn ghostty_hi() void {
    // Does nothing, but you can see this symbol exists:
    // nm -D --defined-only zig-out/lib/libghostty-vt.so | rg ' T '
    // This is temporary as we figure out the API.
}
