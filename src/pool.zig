//! Thread-safe PostgreSQL connection pool using std.Io synchronization.
const std = @import("std");
const Allocator = std.mem.Allocator;
const client_mod = @import("client.zig");
const deadline = @import("deadline.zig");
pub const AcquireOptions = struct { deadline: ?std.Io.Timestamp = null };
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
};

pub const Pool = struct {
    allocator: Allocator,
    io: std.Io,
    config: PoolConfig,
    clients: []?*PgClient,
    in_use: []bool,
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,

    pub fn init(allocator: Allocator, io: std.Io, config: PoolConfig) !*Pool {
        const pool = try initLazy(allocator, io, config);
        errdefer pool.deinit();
        for (pool.clients) |*slot| slot.* = try pool.connect(null);
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

        pool.* = .{
            .allocator = allocator,
            .io = io,
            .config = config,
            .clients = clients,
            .in_use = in_use,
            .mutex = .init,
            .cond = .init,
        };

        return pool;
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        for (self.clients) |c| if (c) |client| client.close();
        self.allocator.free(self.clients);
        self.allocator.free(self.in_use);
        self.mutex.unlock(self.io);
        self.allocator.destroy(self);
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
            for (self.clients, 0..) |c, i| {
                if (!self.in_use[i]) {
                    self.in_use[i] = true;
                    self.mutex.unlock(self.io);
                    if (c) |client| return client;
                    // Connect outside the mutex: one stalled slot must not
                    // prevent another borrower from using a ready connection.
                    const client = self.connect(options.deadline) catch |err| {
                        self.mutex.lockUncancelable(self.io);
                        self.in_use[i] = false;
                        self.cond.signal(self.io);
                        self.mutex.unlock(self.io);
                        return err;
                    };
                    self.mutex.lockUncancelable(self.io);
                    self.clients[i] = client;
                    self.mutex.unlock(self.io);
                    return client;
                }
            }
            self.cond.wait(self.io, &self.mutex) catch |err| {
                self.mutex.unlock(self.io);
                return err;
            };
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

    pub fn healthCheck(self: *Pool) bool {
        const client = self.acquire() catch return false;
        defer self.release(client);

        var res = client.query("SELECT 1") catch return false;
        defer res.deinit();
        return res.rows.len > 0;
    }
};
