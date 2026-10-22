//! Owned, bounded server diagnostics. No SQL, message or parameter data retained.
const std = @import("std");
pub const Diagnostic = struct {
    sqlstate: ?[5]u8 = null,
    cached_query_invalid: bool = false,
};

/// PostgreSQL ErrorResponse fields may occur in any order and span read buffers.
pub const Parser = struct {
    diagnostic: Diagnostic = .{},
    field: ?u8 = null,
    value: [32]u8 = undefined,
    length: usize = 0,
    overflow: bool = false,
    finished: bool = false,

    pub fn feed(self: *Parser, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.finished) return;
            if (self.field == null) {
                if (byte == 0) {
                    self.finished = true;
                } else {
                    self.field = byte;
                    self.length = 0;
                    self.overflow = false;
                }
            } else if (byte == 0) {
                if (!self.overflow) {
                    const value = self.value[0..self.length];
                    if (self.field.? == 'C' and value.len == 5) {
                        for (value) |cp| {
                            if (!std.ascii.isDigit(cp) and !std.ascii.isUpper(cp)) break;
                        } else self.diagnostic.sqlstate = value[0..5].*;
                    } else if (self.field.? == 'R') {
                        self.diagnostic.cached_query_invalid = std.mem.eql(u8, value, "RevalidateCachedQuery");
                    }
                }
                self.field = null;
            } else if (self.length < self.value.len) {
                self.value[self.length] = byte;
                self.length += 1;
            } else self.overflow = true;
        }
    }
};
