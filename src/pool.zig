//! Thread-safe PostgreSQL connection pool using std.Io synchronization.
const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const deadline = @import("deadline.zig");
pub const AcquireOptions = struct { deadline: ?std.Io.Timestamp = null };
pub const HealthCheckOptions = struct { deadline: std.Io.Timestamp };
pub const PgClient = client_mod.PgClient;
pub const PgRow = client_mod.PgRow;
pub const PgResult = client_mod.PgResult;

pub const PoolConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 5432,
    user: []const u8 = "postgres",
    password: []const u8 = "",
    database: []const u8 = "postgres",
    size: u32 = 5,
    limits: client_mod.Limits = .{},
    connect_timeout_ms: ?u32 = null,
    max_scram_iterations: u32 = 100000,
    tls: @import("tls.zig").Options = .{ .mode = .disable },
};

/// Gauges partition capacity; counters saturate and contain no connection data.
pub const PoolStats = struct {
    capacity: usize = 0,
    idle: usize = 0,
    borrowed: usize = 0,
    connecting: usize = 0,
    empty: usize = 0,
    waiters: usize = 0,
    initial_connections: u64 = 0,
    reconnects: u64 = 0,
    connection_failures: u64 = 0,
    discards: u64 = 0,
};

pub const Pool = struct {
    allocator: Allocator,
    io: std.Io,
    config: PoolConfig,
    clients: []?*PgClient,
    in_use: []bool,
    ever_connected: []bool,
    counters: PoolStats = .{},
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    pub fn init(allocator: Allocator, io: std.Io, config: PoolConfig) !*Pool {
        const pool = try initLazy(allocator, io, config);
        errdefer pool.deinit();
        // Initialization is exclusive until this pool is published.
        for (pool.clients, 0..) |*slot, i| {
            slot.* = try pool.connect(null);
            pool.ever_connected[i] = true;
            pool.counters.initial_connections +|= 1;
        }
        return pool;
    }

    /// Allocate ownership without opening sockets. A failed connection leaves
    /// its slot available for a later request, including permissive startup.
    /// Configuration strings must outlive the pool and its borrowers.
    pub fn initLazy(allocator: Allocator, io: std.Io, config: PoolConfig) !*Pool {
        if (config.size == 0) return error.EmptyPool;
        const pool = try allocator.create(Pool);
        errdefer allocator.destroy(pool);

        const clients = try allocator.alloc(?*PgClient, config.size);
        errdefer allocator.free(clients);
        @memset(clients, null);

        const in_use = try allocator.alloc(bool, config.size);
        errdefer allocator.free(in_use);
        @memset(in_use, false);

        const ever_connected = try allocator.alloc(bool, config.size);
        errdefer allocator.free(ever_connected);
        @memset(ever_connected, false);

        pool.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .clients = clients,
            .in_use = in_use,
            .ever_connected = ever_connected,
            .mutex = .init,
            .cond = .init,
        };

        return pool;
    }

    /// The owner must join borrowers/waiters before destroying the pool.
    pub fn deinit(self: *Pool) void {
        for (self.in_use) |used| std.debug.assert(!used);
        std.debug.assert(self.counters.waiters == 0);
        // No concurrent users remain; closing sockets never holds the mutex.
        for (self.clients) |c| if (c) |client| client.close();
        self.allocator.free(self.clients);
        self.allocator.free(self.in_use);
        self.allocator.free(self.ever_connected);
        self.allocator.destroy(self);
    }

    pub fn stats(self: *Pool) PoolStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var snapshot = self.counters;
        snapshot.capacity = self.clients.len;
        for (self.clients, self.in_use) |client, used| {
            if (client != null) {
                if (used) snapshot.borrowed += 1 else snapshot.idle += 1;
            } else {
                if (used) snapshot.connecting += 1 else snapshot.empty += 1;
            }
        }
        return snapshot;
    }

    pub fn acquire(self: *Pool) !*PgClient {
        return self.acquireOpts(.{});
    }

    const AcquireWork = struct {
        pool: *Pool,
        options: AcquireOptions,
        result: ?*PgClient = null,
        fn run(work: *AcquireWork) !void {
            work.result = try work.pool.acquireInternal(work.options);
        }
    };
    pub fn acquireOpts(self: *Pool, options: AcquireOptions) !*PgClient {
        var work: AcquireWork = .{ .pool = self, .options = options };
        errdefer if (work.result) |client| self.release(client);
        try deadline.run(self.io, options.deadline, AcquireWork.run, .{&work});
        return work.result.?;
    }

    fn acquireInternal(self: *Pool, options: AcquireOptions) !*PgClient {
        try self.mutex.lock(self.io);
        while (true) {
            // A vacant earlier slot must not send a ready borrower through
            // authentication. Reserve new capacity only after checking all
            // already-connected, available slots under this same lock.
            for (self.clients, 0..) |c, i| {
                if (!self.in_use[i]) if (c) |client| {
                    self.in_use[i] = true;
                    self.mutex.unlock(self.io);
                    return client;
                };
            }
            for (self.clients, 0..) |c, i| {
                if (!self.in_use[i] and c == null) {
                    self.in_use[i] = true;
                    self.mutex.unlock(self.io);
                    // Connect outside the mutex: one stalled slot must not
                    // prevent another borrower from using a ready connection.
                    const client = self.connect(options.deadline) catch |err| {
                        self.mutex.lockUncancelable(self.io);
                        self.in_use[i] = false;
                        self.counters.connection_failures +|= 1;
                        self.cond.signal(self.io);
                        self.mutex.unlock(self.io);
                        return err;
                    };
                    self.mutex.lockUncancelable(self.io);
                    self.clients[i] = client;
                    if (self.ever_connected[i]) self.counters.reconnects +|= 1 else self.counters.initial_connections +|= 1;
                    self.ever_connected[i] = true;
                    self.mutex.unlock(self.io);
                    return client;
                }
            }
            self.counters.waiters += 1;
            self.cond.wait(self.io, &self.mutex) catch |err| {
                self.counters.waiters -= 1;
                self.mutex.unlock(self.io);
                return err;
            };
            self.counters.waiters -= 1;
        }
    }

    fn connect(self: *Pool, end: ?std.Io.Timestamp) !*PgClient {
        const client = try PgClient.connectOpts(self.allocator, self.io, .{
            .host = self.config.host,
            .port = self.config.port,
            .user = self.config.user,
            .password = self.config.password,
            .database = self.config.database,
            .deadline = deadline.minimum(end, deadline.after(self.io, self.config.connect_timeout_ms)),
            .max_scram_iterations = self.config.max_scram_iterations,
            .tls = self.config.tls,
        });
        client.limits = self.config.limits;
        return client;
    }

    /// Consume an acquired connection whose protocol state is no longer safe
    /// to reuse. Call instead of release; a later acquire reconnects its slot.
    pub fn discard(self: *Pool, client: *PgClient) void {
        self.mutex.lockUncancelable(self.io);
        for (self.clients, 0..) |c, i| {
            if (c == client) {
                std.debug.assert(self.in_use[i]);
                self.clients[i] = null;
                self.in_use[i] = false;
                self.counters.discards +|= 1;
                self.cond.signal(self.io);
                self.mutex.unlock(self.io);
                client.disconnect();
                return;
            }
        }
        self.mutex.unlock(self.io);
        unreachable;
    }

    pub fn release(self: *Pool, client: *PgClient) void {
        if (!client.reusable or client.transaction_status != .idle) return self.discard(client);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.clients, 0..) |c, i| {
            if (c == client) {
                self.in_use[i] = false;
                self.cond.signal(self.io);
                return;
            }
        }
    }

    /// One absolute budget across the queue, connect and SELECT. Failed query
    /// recovery keeps the driver's separate cleanup allowance; release either
    /// returns a synchronized client or discards it. No health write is retried.
    pub fn healthCheckOpts(self: *Pool, options: HealthCheckOptions) !bool {
        const client = try self.acquireOpts(.{ .deadline = options.deadline });
        defer self.release(client);
        var result = try client.queryOpts("SELECT 1", .{ .deadline = options.deadline });
        defer result.deinit();
        return result.rows.len > 0;
    }

    /// Compatibility wrapper: no operation timeout; errors become false.
    /// Service health endpoints should use healthCheckOpts with their deadline.
    pub fn healthCheck(self: *Pool) bool {
        const client = self.acquire() catch return false;
        defer self.release(client);

        var res = client.query("SELECT 1") catch return false;
        defer res.deinit();
        return res.rows.len > 0;
    }
};
