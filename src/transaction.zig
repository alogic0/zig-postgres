//! One cancelable SQL owner. Caller holds an idle pooled client until deinit.
const std = @import("std");
const Client = @import("client.zig").PgClient;
pub const Transaction = struct {
    client: *Client,
    committed: bool = false,

    pub fn begin(client: *Client) !Transaction {
        var result = try client.query("BEGIN");
        result.deinit();
        return .{ .client = client };
    }
    pub fn commit(self: *Transaction) !void {
        var result = try self.client.query("COMMIT");
        defer result.deinit();
        if (!std.mem.eql(u8, result.command_tag, "COMMIT")) return error.TransactionRolledBack;
        self.committed = true;
    }
    pub fn deinit(self: *Transaction) void {
        if (self.committed or !self.client.reusable) return;
        self.client.rollbackCleanup();
    }
};
