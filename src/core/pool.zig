//! Connection pool (Phase 2/3: configuration container).
//!
//! Owns origin identity + per-pool config (TLS, version, timeouts). Phase 4
//! grows this into the real pool with idle/busy lists, FIFO waiters, and
//! TTL eviction.
//!
//! Trust anchors are loaded into ``tls.zig``'s process-level cache before
//! the pool is created, so the pool itself doesn't carry CA bundle data.

const std = @import("std");

pub const Pool = struct {
    allocator: std.mem.Allocator,
    host: []u8, // owned copy
    port: u16,
    tls: bool,
    version: u8,
    pool_size: u32,
    ttl_seconds: u32,
    timeout_ms: u32,

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
            .pool_size = opts.pool_size,
            .ttl_seconds = opts.ttl_seconds,
            .timeout_ms = opts.timeout_ms,
        };
        return self;
    }

    pub fn destroy(self: *Pool) void {
        const allocator = self.allocator;
        allocator.free(self.host);
        allocator.destroy(self);
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
}
