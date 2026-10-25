//! OpenSSL 3 TLS with memory BIOs. Zig owns all socket I/O and cancellation.
//! CA files use bounded Zig I/O and PEM memory BIOs; socket work is always Zig I/O.
//! The library is process-owned; SSL_CTX and SSL/BIOs have explicit lifetimes.
//! ABI: https://docs.openssl.org/3.0/man3/SSL_set_bio/
//! Error ordering: https://docs.openssl.org/3.0/man3/SSL_get_error/
const std = @import("std");
const Io = std.Io;
const A = std.mem.Allocator;
const P = *opaque {};
const enabled = @import("postgres_options").tls;
pub const Options = struct {
    mode: enum { disable, verify_full } = .verify_full,
    ca_file: []const u8 = "/etc/ssl/certs/ca-certificates.crt",
    server_name: ?[]const u8 = null,
};
pub const Api = struct {
    TLS_server_method: *const fn () callconv(.c) P,
    SSL_CTX_use_certificate_chain_file: *const fn (P, [*:0]const u8) callconv(.c) c_int,
    SSL_CTX_use_PrivateKey_file: *const fn (P, [*:0]const u8, c_int) callconv(.c) c_int,
    SSL_set_accept_state: *const fn (P) callconv(.c) void,
    SSL_CTX_get_cert_store: *const fn (P) callconv(.c) P,
    BIO_new_mem_buf: *const fn ([*]const u8, c_int) callconv(.c) ?P,
    BIO_free: *const fn (P) callconv(.c) c_int,
    PEM_read_bio_X509_AUX: *const fn (P, ?*P, ?*anyopaque, ?*anyopaque) callconv(.c) ?P,
    X509_STORE_add_cert: *const fn (P, P) callconv(.c) c_int,
    X509_free: *const fn (P) callconv(.c) void,
    TLS_client_method: *const fn () callconv(.c) P,
    SSL_CTX_new: *const fn (P) callconv(.c) ?P,
    SSL_CTX_free: *const fn (P) callconv(.c) void,
    SSL_CTX_set_verify: *const fn (P, c_int, ?*anyopaque) callconv(.c) void,
    SSL_CTX_ctrl: *const fn (P, c_int, c_long, ?*anyopaque) callconv(.c) c_long,
    SSL_CTX_get0_param: *const fn (P) callconv(.c) P,
    SSL_CTX_set_cipher_list: *const fn (P, [*:0]const u8) callconv(.c) c_int,
    SSL_CTX_set_alpn_protos: *const fn (P, [*]const u8, c_uint) callconv(.c) c_int,
    SSL_CTX_load_verify_locations: *const fn (P, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    X509_VERIFY_PARAM_set_flags: *const fn (P, c_ulong) callconv(.c) c_int,
    X509_VERIFY_PARAM_set1_ip_asc: *const fn (P, [*:0]const u8) callconv(.c) c_int,
    SSL_new: *const fn (P) callconv(.c) ?P,
    SSL_free: *const fn (P) callconv(.c) void,
    SSL_set0_rbio: *const fn (P, P) callconv(.c) void,
    SSL_set0_wbio: *const fn (P, P) callconv(.c) void,
    SSL_set_connect_state: *const fn (P) callconv(.c) void,
    SSL_set1_host: *const fn (P, [*:0]const u8) callconv(.c) c_int,
    SSL_set_hostflags: *const fn (P, c_uint) callconv(.c) void,
    SSL_get0_param: *const fn (P) callconv(.c) P,
    SSL_ctrl: *const fn (P, c_int, c_long, ?*anyopaque) callconv(.c) c_long,
    SSL_do_handshake: *const fn (P) callconv(.c) c_int,
    SSL_read_ex: *const fn (P, [*]u8, usize, *usize) callconv(.c) c_int,
    SSL_write_ex: *const fn (P, [*]const u8, usize, *usize) callconv(.c) c_int,
    SSL_get_error: *const fn (P, c_int) callconv(.c) c_int,
    BIO_s_mem: *const fn () callconv(.c) P,
    BIO_new: *const fn (P) callconv(.c) ?P,
    BIO_read: *const fn (P, [*]u8, c_int) callconv(.c) c_int,
    BIO_write: *const fn (P, [*]const u8, c_int) callconv(.c) c_int,
    BIO_ctrl: *const fn (P, c_int, c_long, ?*anyopaque) callconv(.c) c_long,
    BIO_ctrl_pending: *const fn (P) callconv(.c) usize,
    ERR_clear_error: *const fn () callconv(.c) void,
    OpenSSL_version: *const fn (c_int) callconv(.c) [*:0]const u8,
};
var library_lock: Io.Mutex = .init;
var api: ?Api = null;
// Deliberately never unload: OpenSSL has process/thread state, and other job
// contexts or thread teardown may still reference its code.
var library: ?std.DynLib = null;
pub fn load(io: Io) !*const Api {
    if (comptime !enabled) return error.TlsUnavailable;
    if (!@import("builtin").link_libc) @compileError("PostgreSQL TLS requires libc for the system OpenSSL 3 loader");
    try library_lock.lock(io);
    defer library_lock.unlock(io);
    if (api == null) {
        var lib = std.DynLib.open("libssl.so.3") catch return error.OpenSslUnavailable;
        errdefer lib.close();
        var functions: Api = undefined;
        inline for (@typeInfo(Api).@"struct".field_names) |name| {
            @field(functions, name) = lib.lookup(@FieldType(Api, name), name) orelse return error.OpenSslSymbolMissing;
        }
        library = lib;
        api = functions;
    }
    return &api.?;
}
pub fn version(io: Io) ![]const u8 {
    return std.mem.span((try load(io)).OpenSSL_version(0));
}
pub const Context = struct {
    api: *const Api,
    handle: P,
    pub fn init(a: A, io: Io, ca_file: []const u8) !Context {
        const f = try load(io);
        f.ERR_clear_error();
        const ctx = f.SSL_CTX_new(f.TLS_client_method()) orelse return error.OutOfMemory;
        errdefer f.SSL_CTX_free(ctx);
        f.SSL_CTX_set_verify(ctx, 1, null); // SSL_VERIFY_PEER
        if (f.SSL_CTX_ctrl(ctx, 123, 0x303, null) != 1) return error.SSLError; // TLS 1.2 minimum
        if (f.X509_VERIFY_PARAM_set_flags(f.SSL_CTX_get0_param(ctx), 0x8000) != 1) return error.SSLError; // TRUSTED_FIRST, Python 3.12
        if (f.SSL_CTX_set_cipher_list(ctx, "@SECLEVEL=2:ECDH+AESGCM:ECDH+CHACHA20:ECDH+AES:DHE+AES:!aNULL:!eNULL:!aDSS:!SHA1:!AESCCM") != 1) return error.SSLError;
        if (std.mem.indexOfScalar(u8, ca_file, 0) != null) return error.InvalidTrustPath;
        const pem = try Io.Dir.cwd().readFileAlloc(io, ca_file, a, .limited(4 * 1024 * 1024));
        defer a.free(pem);
        const input = f.BIO_new_mem_buf(pem.ptr, @intCast(pem.len)) orelse return error.OutOfMemory;
        defer _ = f.BIO_free(input);
        var certificates: usize = 0;
        while (f.PEM_read_bio_X509_AUX(input, null, null, null)) |cert| {
            defer f.X509_free(cert);
            if (f.X509_STORE_add_cert(f.SSL_CTX_get_cert_store(ctx), cert) != 1) return error.InvalidTrustStore;
            certificates += 1;
        }
        f.ERR_clear_error();
        if (certificates == 0) return error.InvalidTrustStore;
        return .{ .api = f, .handle = ctx };
    }
    pub fn deinit(self: *Context) void {
        self.api.SSL_CTX_free(self.handle);
    }
};
pub const Session = struct {
    api: *const Api,
    handle: P,
    input: P,
    output: P,
    stream: Io.net.Stream,
    io: Io,
    pub fn init(ctx: *const Context, a: A, io: Io, stream: Io.net.Stream, host: []const u8) !Session {
        const f = ctx.api;
        const ssl = f.SSL_new(ctx.handle) orelse return error.OutOfMemory;
        errdefer f.SSL_free(ssl);
        const input = f.BIO_new(f.BIO_s_mem()) orelse return error.OutOfMemory;
        f.SSL_set0_rbio(ssl, input); // SSL owns this immediately, including error cleanup.
        const output = f.BIO_new(f.BIO_s_mem()) orelse return error.OutOfMemory;
        f.SSL_set0_wbio(ssl, output);
        _ = f.BIO_ctrl(input, 130, -1, null); // BIO_C_SET_BUF_MEM_EOF_RETURN
        const name = try a.dupeSentinel(u8, host, 0);
        defer a.free(name);
        if (Io.net.IpAddress.parse(host, 0)) |_| {
            if (f.X509_VERIFY_PARAM_set1_ip_asc(f.SSL_get0_param(ssl), name) != 1) return error.SSLError;
        } else |_| {
            f.SSL_set_hostflags(ssl, 4); // NO_PARTIAL_WILDCARDS
            if (f.SSL_set1_host(ssl, name) != 1) return error.SSLError;
            if (f.SSL_ctrl(ssl, 55, 0, name.ptr) != 1) return error.SSLError; // SNI host_name
        }
        f.SSL_set_connect_state(ssl);
        var self: Session = .{ .api = f, .handle = ssl, .input = input, .output = output, .stream = stream, .io = io };
        try self.handshake();
        return self;
    }
    /// Explicit handshake for borrowed-socket server adapters and client setup.
    pub fn handshake(self: *Session) !void {
        const f = self.api;
        while (true) {
            f.ERR_clear_error();
            const rc = f.SSL_do_handshake(self.handle);
            const code = if (rc == 1) 0 else f.SSL_get_error(self.handle, rc);
            try self.flush();
            if (rc == 1) return;
            try self.advance(code);
        }
    }
    pub fn deinit(self: *Session) void {
        // No blocking close_notify during cancellation or pool eviction. Socket
        // ownership remains with the enclosing PostgreSQL connection.
        self.api.SSL_free(self.handle);
    }
    fn operate(self: *Session, operation: Io.Operation) !Io.Operation.Result {
        var storage: [1]Io.Operation.Storage = undefined;
        var batch: Io.Batch = .init(&storage);
        defer batch.cancel(self.io);
        batch.addAt(0, operation);
        try batch.awaitConcurrent(self.io, .none);
        return batch.next().?.result;
    }
    fn flush(self: *Session) !void {
        var bytes: [16 * 1024]u8 = undefined;
        while (self.api.BIO_ctrl_pending(self.output) != 0) {
            const n = self.api.BIO_read(self.output, &bytes, bytes.len);
            if (n <= 0) return error.TlsIoError;
            var rest = bytes[0..@intCast(n)];
            while (rest.len != 0) {
                const result = try self.operate(.{ .net_write = .{ .socket_handle = self.stream.socket.handle, .header = rest, .data = &.{""}, .splat = 1 } });
                const written = try result.net_write;
                if (written == 0) return error.TlsIoError;
                rest = rest[written..];
            }
        }
    }
    fn advance(self: *Session, code: c_int) !void {
        switch (code) {
            2 => { // SSL_ERROR_WANT_READ
                var bytes: [16 * 1024]u8 = undefined;
                var buffers: [1][]u8 = .{&bytes};
                const result = try self.operate(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &buffers } });
                const n = (try result.net_read).data_len;
                if (n == 0) return error.EndOfStream;
                if (self.api.BIO_write(self.input, &bytes, @intCast(n)) != @as(c_int, @intCast(n))) return error.TlsIoError;
            },
            3 => {}, // SSL_ERROR_WANT_WRITE: output was drained before this call.
            6 => return error.EndOfStream,
            else => return error.TlsVerificationOrProtocolError,
        }
    }
    pub fn read(self: *Session, bytes: []u8) !usize {
        while (true) {
            self.api.ERR_clear_error();
            var n: usize = 0;
            const rc = self.api.SSL_read_ex(self.handle, bytes.ptr, bytes.len, &n);
            const code = if (rc == 1) 0 else self.api.SSL_get_error(self.handle, rc);
            try self.flush();
            if (rc == 1) return n;
            try self.advance(code);
        }
    }
    pub fn write(self: *Session, bytes: []const u8) !usize {
        const part = bytes[0..@min(bytes.len, 16 * 1024)];
        while (true) {
            self.api.ERR_clear_error();
            var n: usize = 0;
            const rc = self.api.SSL_write_ex(self.handle, part.ptr, part.len, &n);
            const code = if (rc == 1) 0 else self.api.SSL_get_error(self.handle, rc);
            try self.flush();
            if (rc == 1) return n;
            try self.advance(code);
        }
    }
};
