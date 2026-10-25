//! Logical live allocation bytes; allocator metadata and external resources excluded.
const std = @import("std");
const A = std.mem.Allocator;
pub const Tracker = struct {
    parent: A,
    live: usize = 0,
    peak: usize = 0,
    pub fn allocator(t: *Tracker) A {
        return .{ .ptr = t, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn change(t: *Tracker, before: usize, after: usize) void {
        t.live = t.live - before + after;
        t.peak = @max(t.peak, t.live);
    }
    fn alloc(p: *anyopaque, n: usize, align_: std.mem.Alignment, ra: usize) ?[*]u8 {
        const t: *Tracker = @ptrCast(@alignCast(p));
        const r = t.parent.rawAlloc(n, align_, ra) orelse return null;
        t.change(0, n);
        return r;
    }
    fn resize(p: *anyopaque, b: []u8, align_: std.mem.Alignment, n: usize, ra: usize) bool {
        const t: *Tracker = @ptrCast(@alignCast(p));
        if (!t.parent.rawResize(b, align_, n, ra)) return false;
        t.change(b.len, n);
        return true;
    }
    fn remap(p: *anyopaque, b: []u8, align_: std.mem.Alignment, n: usize, ra: usize) ?[*]u8 {
        const t: *Tracker = @ptrCast(@alignCast(p));
        const r = t.parent.rawRemap(b, align_, n, ra) orelse return null;
        t.change(b.len, n);
        return r;
    }
    fn free(p: *anyopaque, b: []u8, align_: std.mem.Alignment, ra: usize) void {
        const t: *Tracker = @ptrCast(@alignCast(p));
        t.parent.rawFree(b, align_, ra);
        t.change(b.len, 0);
    }
};
