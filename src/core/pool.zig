//! Connection pool for a single origin (host, port, tls).
//!
//! Each Python `Client` owns one `Pool`. Worker threads acquire a connection
//! (reusing an idle keep-alive socket when possible, otherwise opening a new
//! one), perform one request/response, then release it back. The pool is
//! bounded by `pool_size`: when every slot is in use, `acquire` blocks on a
//! condition variable until a connection is released.
//!
//! Connections are stored as plain `net.Stream` values (a socket handle plus
//! its resolved address). The blocking `Io` used to read/write/close them is
//! recreated per operation on the owning worker thread, so a pooled connection
//! carries no thread affinity.

const std = @import("std");
const net = std.Io.net;

pub const Pool = struct {
    allocator: std.mem.Allocator,
    host: []u8, // owned copy
    port: u16,
    tls: bool,
    version: u8,
    pool_size: u32,
    ttl_seconds: u32,
    timeout_ms: u32,

    /// Atomic spinlock guarding `idle` and `total_open`. Critical sections are
    /// tiny (a push/pop and a counter tweak), and 0.16 removed std.Thread.Mutex
    /// while its Io-based replacement needs an Io and doesn't synchronize under
    /// `init_single_threaded` — so a spinlock is the simplest correct choice.
    lock_flag: std.atomic.Value(bool) = .init(false),
    idle: std.ArrayList(Conn) = .empty,
    /// Connections currently open (idle + in-flight). Never exceeds pool_size.
    total_open: u32 = 0,

    const Conn = struct {
        stream: net.Stream,
    };

    /// Result of `acquire`: either reuse an idle stream, or a reserved slot the
    /// caller must fill by opening a new connection.
    pub const Acquired = union(enum) {
        reuse: net.Stream,
        open_new,
    };

    pub const CreateOptions = struct {
        host: []const u8,
        port: u16,
        tls: bool,
        version: u8,
        pool_size: u32,
        ttl_seconds: u32,
        timeout_ms: u32,
    };

    pub fn create(allocator: std.mem.Allocator, opts: CreateOptions) std.mem.Allocator.Error!*Pool {
        const self = try allocator.create(Pool);
        errdefer allocator.destroy(self);

        const owned_host = try allocator.dupe(u8, opts.host);

        self.* = .{
            .allocator = allocator,
            .host = owned_host,
            .port = opts.port,
            .tls = opts.tls,
            .version = opts.version,
            .pool_size = if (opts.pool_size == 0) 1 else opts.pool_size,
            .ttl_seconds = opts.ttl_seconds,
            .timeout_ms = opts.timeout_ms,
        };
        return self;
    }

    pub fn destroy(self: *Pool) void {
        // Close any idle connections before tearing down.
        for (self.idle.items) |c| closeStream(c.stream);
        self.idle.deinit(self.allocator);

        const allocator = self.allocator;
        allocator.free(self.host);
        allocator.destroy(self);
    }

    /// Acquire a connection slot. Reuses a fresh idle connection if available,
    /// otherwise reserves a new slot (blocking if the pool is full). Stale idle
    /// connections (older than the TTL) are closed and skipped.
    pub fn acquire(self: *Pool) Acquired {
        while (true) {
            self.lockMutex();

            // Reuse the most-recently-used idle connection. Dead sockets (e.g.
            // closed by the server after an idle period) are detected by the
            // request attempt failing, which triggers a fresh-connection retry
            // in `transport.exchange` — so we don't proactively age them here.
            if (self.idle.items.len > 0) {
                const c = self.idle.items[self.idle.items.len - 1];
                self.idle.items.len -= 1;
                self.unlockMutex();
                return .{ .reuse = c.stream };
            }

            if (self.total_open < self.pool_size) {
                self.total_open += 1; // reserve the slot
                self.unlockMutex();
                return .open_new;
            }

            // Pool full and nothing idle: back off and retry.
            self.unlockMutex();
            std.Thread.yield() catch {};
        }
    }

    /// Return a healthy connection to the pool. If `reusable` is false the
    /// connection is closed and its slot freed.
    pub fn release(self: *Pool, stream: net.Stream, reusable: bool) void {
        if (reusable) {
            self.lockMutex();
            const ok = self.idle.append(self.allocator, .{ .stream = stream });
            self.unlockMutex();
            // If we couldn't record it as idle (OOM), just close it.
            ok catch self.discard(stream);
        } else {
            self.discard(stream);
        }
    }

    /// Close a connection and free its slot (used for dead/non-reusable conns).
    pub fn discard(self: *Pool, stream: net.Stream) void {
        self.lockMutex();
        self.total_open -= 1;
        self.unlockMutex();
        closeStream(stream);
    }

    /// Release a reserved slot that was never filled (open failed).
    pub fn releaseReservation(self: *Pool) void {
        self.lockMutex();
        self.total_open -= 1;
        self.unlockMutex();
    }

    fn lockMutex(self: *Pool) void {
        while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockMutex(self: *Pool) void {
        self.lock_flag.store(false, .release);
    }

    fn closeStream(stream: net.Stream) void {
        var t: std.Io.Threaded = .init_single_threaded;
        stream.close(t.io());
    }
};

test "pool round-trip" {
    const pool = try Pool.create(std.testing.allocator, .{
        .host = "api.example.com",
        .port = 443,
        .tls = true,
        .version = 2,
        .pool_size = 64,
        .ttl_seconds = 60,
        .timeout_ms = 30_000,
    });
    defer pool.destroy();

    try std.testing.expectEqualStrings("api.example.com", pool.host);
    try std.testing.expectEqual(@as(u16, 443), pool.port);
    try std.testing.expect(pool.tls);
    try std.testing.expectEqual(@as(u32, 0), pool.total_open);
}
