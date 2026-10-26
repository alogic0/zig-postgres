//! PostgreSQL protocol, connection ownership and transactions. No application SQL.
pub const client = @import("client.zig");
pub const pool = @import("pool.zig");
pub const scram = @import("scram.zig");
pub const diagnostic = @import("diagnostic.zig");
pub const decoding = @import("decode.zig");
pub const cancel = @import("cancel.zig");
pub const transaction = @import("transaction.zig");
pub const protocol = @import("protocol.zig");
pub const Limits = protocol.Limits;
pub const parameters = @import("parameters.zig");
pub const Uuid = parameters.Uuid;
pub const Binary = parameters.Binary;
pub const FiniteFloat = parameters.FiniteFloat;
pub const finiteFloat = parameters.finiteFloat;
pub const ParsedUri = @import("uri.zig").ParsedUri;
pub const commandCount = @import("command.zig").count;
pub const QueryOptions = client.QueryOptions;
pub const ConnectOptions = client.ConnectOptions;
pub const AcquireOptions = pool.AcquireOptions;
pub const HealthCheckOptions = pool.HealthCheckOptions;
pub const streaming = @import("stream.zig");
pub const PgStream = streaming.Stream;
pub const StreamOptions = streaming.Options;
pub const BorrowedRow = streaming.BorrowedRow;
pub const tls = @import("tls.zig");
pub const TlsOptions = tls.Options;
pub const tls_enabled = @import("postgres_options").tls;

pub const PgClient = client.PgClient;
pub const PgError = client.PgError;
pub const PgRow = client.PgRow;
pub const PgResult = client.PgResult;
pub const Pool = pool.Pool;
pub const PoolConfig = pool.PoolConfig;
pub const Transaction = transaction.Transaction;

test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("decode_test.zig");
    _ = @import("uri.zig");
    _ = @import("command.zig");
}
