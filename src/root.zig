//! PostgreSQL protocol, connection ownership and transactions. No application SQL.
pub const client = @import("client.zig");
pub const pool = @import("pool.zig");
pub const scram = @import("scram.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const cancel = @import("cancel.zig");
pub const transaction = @import("transaction.zig");

pub const PgClient = client.PgClient;
pub const PgError = client.PgError;
pub const PgRow = client.PgRow;
pub const PgResult = client.PgResult;
pub const Pool = pool.Pool;
pub const PoolConfig = pool.PoolConfig;
pub const Transaction = transaction.Transaction;

test {
    @import("std").testing.refAllDecls(@This());
}
