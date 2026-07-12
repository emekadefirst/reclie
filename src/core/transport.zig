//! Blocking HTTP/1.1 transport with connection pooling (plain HTTP) and TLS
//! (HTTPS).
//!
//! Uses the std.Io.Threaded blocking backend so it runs everywhere (Windows
//! included) today; the io_uring/kqueue/IOCP drivers slot in behind the same
//! `exchange` seam later.
//!
//! Both plain HTTP and HTTPS reuse pooled keep-alive connections. For TLS, the
//! whole session (socket + `tls.Client` + its buffers) is kept alive in a
//! heap-allocated `TlsConn` with stable addresses, so the handshake happens
//! once per connection rather than once per request. The request send +
//! response framing is shared by both paths via `sendAndFrame`, operating on
//! generic `Io.Reader`/`Io.Writer`, which for TLS are the plaintext streams
//! exposed by `std.crypto.tls.Client`.

const std = @import("std");
const net = std.Io.net;
const tls = std.crypto.tls;
const Pool = @import("pool.zig").Pool;

pub const Error = error{
    Resolve,
    Connect,
    Send,
    Recv,
    Protocol,
    Tls,
    OutOfMemory,
};

const Framed = struct {
    raw: []u8,
    reusable: bool,
};

/// Perform one request against `pool`'s origin, returning the raw response
/// bytes (owned by `alloc`).
pub fn exchange(pool: *Pool, alloc: std.mem.Allocator, request_bytes: []const u8) Error![]u8 {
    if (pool.tls) return exchangeTls(pool, alloc, request_bytes);

    // Plain HTTP: reuse a pooled connection, retrying once if a reused socket
    // turns out to have been closed by the server.
    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var reused = false;
        var stream: net.Stream = undefined;
        switch (pool.acquire()) {
            .reuse => |s| {
                stream = s;
                reused = true;
            },
            .open_new => {
                stream = openStream(pool.host, pool.port) catch |e| {
                    pool.releaseReservation();
                    return e;
                };
            },
        }

        const framed = onePlainRequest(alloc, stream, request_bytes) catch |e| {
            pool.discard(stream);
            if (reused and attempt == 0) continue;
            return e;
        };

        pool.release(stream, framed.reusable);
        return framed.raw;
    }
}

/// A pooled, persistent TLS connection. Heap-allocated so the reader/writer and
/// `tls.Client` (which reference each other by pointer via `@fieldParentPtr`)
/// keep stable addresses across requests. The TLS handshake runs once, in
/// `openTlsConn`; subsequent requests reuse `client.reader`/`client.writer`.
const TlsConn = struct {
    alloc: std.mem.Allocator,
    threaded: std.Io.Threaded,
    stream: net.Stream,
    net_wbuf: []u8,
    net_rbuf: []u8,
    tls_wbuf: []u8,
    tls_rbuf: []u8,
    net_writer: net.Stream.Writer,
    net_reader: net.Stream.Reader,
    client: tls.Client,
};

/// HTTPS: reuse a pooled TLS session, retrying once on a fresh one if a reused
/// connection turns out to have been closed by the server.
fn exchangeTls(pool: *Pool, alloc: std.mem.Allocator, request_bytes: []const u8) Error![]u8 {
    // Register how the pool should close a TLS connection it evicts.
    pool.tls_destroy = destroyTlsConn;

    var attempt: u8 = 0;
    while (true) : (attempt += 1) {
        var reused = false;
        var conn: *TlsConn = undefined;
        switch (pool.acquireTls()) {
            .reuse => |ptr| {
                conn = @ptrCast(@alignCast(ptr));
                reused = true;
            },
            .open_new => {
                conn = openTlsConn(pool, alloc) catch |e| {
                    pool.releaseReservation();
                    return e;
                };
            },
        }

        // client.writer.flush() drains ciphertext into the net writer's buffer;
        // the net writer then needs its own flush to push it onto the socket.
        const framed = sendAndFrame(
            alloc,
            &conn.client.writer,
            &conn.client.reader,
            request_bytes,
            &conn.net_writer.interface,
        ) catch |e| {
            pool.discardTls(conn);
            if (reused and attempt == 0) continue;
            return e;
        };

        pool.releaseTls(conn, framed.reusable);
        return framed.raw;
    }
}

/// Open a TCP connection and perform the TLS handshake once.
fn openTlsConn(pool: *Pool, alloc: std.mem.Allocator) Error!*TlsConn {
    const conn = alloc.create(TlsConn) catch return error.OutOfMemory;
    errdefer alloc.destroy(conn);

    conn.alloc = alloc;
    conn.threaded = .init_single_threaded;
    const io = conn.threaded.io();

    conn.stream = try connectTo(io, pool.host, pool.port);
    errdefer conn.stream.close(io);

    const buf_len = tls.Client.min_buffer_len;
    conn.net_wbuf = alloc.alloc(u8, buf_len) catch return error.OutOfMemory;
    errdefer alloc.free(conn.net_wbuf);
    conn.net_rbuf = alloc.alloc(u8, buf_len) catch return error.OutOfMemory;
    errdefer alloc.free(conn.net_rbuf);
    conn.tls_wbuf = alloc.alloc(u8, buf_len) catch return error.OutOfMemory;
    errdefer alloc.free(conn.tls_wbuf);
    conn.tls_rbuf = alloc.alloc(u8, buf_len) catch return error.OutOfMemory;
    errdefer alloc.free(conn.tls_rbuf);

    conn.net_writer = conn.stream.writer(io, conn.net_wbuf);
    conn.net_reader = conn.stream.reader(io, conn.net_rbuf);

    var entropy: [tls.Client.Options.entropy_len]u8 = undefined;
    io.random(&entropy);

    conn.client = tls.Client.init(&conn.net_reader.interface, &conn.net_writer.interface, .{
        .host = .{ .explicit = pool.host },
        .ca = .{ .bundle = .{
            .gpa = alloc,
            .io = io,
            .lock = &pool.ca_lock,
            .bundle = &pool.ca_bundle,
        } },
        .write_buffer = conn.tls_wbuf,
        .read_buffer = conn.tls_rbuf,
        .entropy = &entropy,
        .realtime_now = std.Io.Clock.real.now(io),
    }) catch return error.Tls;

    return conn;
}

/// Close and free a pooled TLS connection (the pool's `tls_destroy` callback).
fn destroyTlsConn(ptr: *anyopaque) void {
    const conn: *TlsConn = @ptrCast(@alignCast(ptr));
    const io = conn.threaded.io();
    conn.client.end() catch {}; // best-effort close_notify
    conn.stream.close(io);
    const a = conn.alloc;
    a.free(conn.net_wbuf);
    a.free(conn.net_rbuf);
    a.free(conn.tls_wbuf);
    a.free(conn.tls_rbuf);
    a.destroy(conn);
}

/// Connect a TCP stream to `host:port`. Fast-paths IP literals; otherwise does
/// a DNS lookup through the OS resolver (`HostName.connect`), which works on
/// Windows unlike the literal-only `IpAddress.resolve`.
fn connectTo(io: std.Io, host: []const u8, port: u16) Error!net.Stream {
    if (net.IpAddress.parse(host, port)) |addr| {
        return net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.Connect;
    } else |_| {}

    const hn = net.HostName.init(host) catch return error.Resolve;
    return hn.connect(io, port, .{ .mode = .stream }) catch return error.Connect;
}

/// Connect a new plain TCP stream (own transient Io).
fn openStream(host: []const u8, port: u16) Error!net.Stream {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    return connectTo(io, host, port);
}

fn onePlainRequest(alloc: std.mem.Allocator, stream: net.Stream, request_bytes: []const u8) Error!Framed {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    return sendAndFrame(alloc, &sw.interface, &sr.interface, request_bytes, null);
}

/// Send `request_bytes` on `w` and read exactly one HTTP/1.1 response from `r`.
/// `w.flush()` is expected to push all the way to the socket (true for both the
/// net stream writer and the TLS client writer, whose flush drains its output).
fn sendAndFrame(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    r: *std.Io.Reader,
    request_bytes: []const u8,
    /// When `w` is a layered writer (TLS), the underlying transport writer that
    /// also needs flushing to actually push bytes onto the socket.
    transport_w: ?*std.Io.Writer,
) Error!Framed {
    w.writeAll(request_bytes) catch return error.Send;
    w.flush() catch return error.Send;
    if (transport_w) |tw| tw.flush() catch return error.Send;

    var raw: std.ArrayList(u8) = .empty;
    errdefer raw.deinit(alloc);

    var content_length: ?usize = null;
    var chunked = false;
    var conn_close = false;
    var conn_keep_alive = false;
    var http_1_0 = false;
    var first_line = true;

    // Status line + header block, up to the blank line.
    while (true) {
        const line = try takeLine(r);
        try raw.appendSlice(alloc, line);
        const trimmed = trimCRLF(line);

        if (first_line) {
            first_line = false;
            if (std.mem.startsWith(u8, trimmed, "HTTP/1.0")) http_1_0 = true;
        }

        if (trimmed.len == 0) break;

        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const name = trimmed[0..colon];
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch return error.Protocol;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                if (containsIgnoreCase(value, "chunked")) chunked = true;
            } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
                if (containsIgnoreCase(value, "close")) conn_close = true;
                if (containsIgnoreCase(value, "keep-alive")) conn_keep_alive = true;
            }
        }
    }

    if (http_1_0 and !conn_keep_alive) conn_close = true;

    // Body framing.
    if (chunked) {
        while (true) {
            const size_line = try takeLine(r);
            try raw.appendSlice(alloc, size_line);
            const st = trimCRLF(size_line);
            const end = std.mem.indexOfScalar(u8, st, ';') orelse st.len;
            const size = std.fmt.parseInt(usize, std.mem.trim(u8, st[0..end], " \t"), 16) catch
                return error.Protocol;
            if (size == 0) {
                while (true) {
                    const tline = try takeLine(r);
                    try raw.appendSlice(alloc, tline);
                    if (trimCRLF(tline).len == 0) break;
                }
                break;
            }
            try readExactInto(alloc, r, &raw, size + 2); // data + CRLF
        }
    } else if (content_length) |cl| {
        try readExactInto(alloc, r, &raw, cl);
    } else {
        r.appendRemaining(alloc, &raw, .unlimited) catch return error.Recv;
        conn_close = true;
    }

    return .{ .raw = try raw.toOwnedSlice(alloc), .reusable = !conn_close };
}

fn takeLine(r: *std.Io.Reader) Error![]u8 {
    return r.takeDelimiterInclusive('\n') catch |e| switch (e) {
        error.StreamTooLong => error.Protocol,
        else => error.Recv,
    };
}

fn readExactInto(alloc: std.mem.Allocator, r: *std.Io.Reader, list: *std.ArrayList(u8), n: usize) Error!void {
    const dest = list.addManyAsSlice(alloc, n) catch return error.OutOfMemory;
    r.readSliceAll(dest) catch return error.Recv;
}

fn trimCRLF(line: []const u8) []const u8 {
    var end = line.len;
    if (end > 0 and line[end - 1] == '\n') end -= 1;
    if (end > 0 and line[end - 1] == '\r') end -= 1;
    return line[0..end];
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return needle.len == 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}
