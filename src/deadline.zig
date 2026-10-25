//! Joined, cancelable work with one absolute awake-clock budget. Tasks return
//! void; resource results live in caller-owned contexts until joining completes.
const std = @import("std");
const Io = std.Io;
pub fn check(io: Io, end: ?Io.Timestamp) !void {
    try io.checkCancel();
    if (end) |at| if (Io.Timestamp.now(io, .awake).nanoseconds >= at.nanoseconds) return error.Timeout;
}
pub fn minimum(a: ?Io.Timestamp, b: ?Io.Timestamp) ?Io.Timestamp {
    if (a) |x| {
        if (b) |y| return if (x.nanoseconds < y.nanoseconds) x else y;
        return x;
    }
    return b;
}
pub fn after(io: Io, ms: ?u32) ?Io.Timestamp {
    return if (ms) |n| Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(n)) else null;
}
fn wait(io: Io, end: Io.Timestamp) Io.Cancelable!void {
    const now = Io.Timestamp.now(io, .awake);
    if (now.nanoseconds < end.nanoseconds) try io.sleep(now.durationTo(end), .awake);
}
pub fn run(io: Io, end: ?Io.Timestamp, comptime function: anytype, arguments: anytype) !void {
    try check(io, end);
    const at = end orelse return @call(.auto, function, arguments);
    const Done = union(enum) { work: anyerror!void, timeout: Io.Cancelable!void };
    var storage: [2]Done = undefined;
    var select = Io.Select(Done).init(io, &storage);
    defer select.cancelDiscard();
    const Worker = struct {
        fn execute(task_io: Io, args: @TypeOf(arguments)) anyerror!void {
            const protection = task_io.swapCancelProtection(.unblocked);
            defer _ = task_io.swapCancelProtection(protection);
            try @call(.auto, function, args);
        }
    };
    try select.concurrent(.work, Worker.execute, .{ io, arguments });
    try select.concurrent(.timeout, wait, .{ io, at });
    return switch (try select.await()) {
        .work => |value| value,
        .timeout => error.Timeout,
    };
}
