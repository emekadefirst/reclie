//! Blocking HTTP/1.1 transport with connection pooling and keep-alive.
//!
//! Uses the std.Io.Threaded blocking backend so it runs everywhere (Windows
//! included) today; the io_uring/kqueue/IOCP drivers slot in behind the same
//! `exchange` seam later. `exchange` borrows a connection from the pool (reusing
//! an idle keep-alive socket when possible), sends one request, reads exactly
//! one response using Content-Length / chunked framing, and returns the socket
//! to the pool if it stays reusable.

const std = @import("std");
const net = std.Io.net;
const Pool = @import("pool.zig").Pool;

pub const Error = error{
    Resolve,
    Connect,
    Send,
    Recv,
    Protocol,
    OutOfMemory,
};

const Framed = struct {
    raw: []u8,
    reusable: bool,
};

/// Perform one request against `pool`'s origin, returning the raw response
/// bytes (owned by `alloc`). Reuses a pooled connection when available and, if
/// a reused connection turns out to be dead, retries once on a fresh one.
pub fn exchange(pool: *Pool, alloc: std.mem.Allocator, request_bytes: []const u8) Error![]u8 {
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

        const framed = oneRequest(alloc, stream, request_bytes) catch |e| {
            pool.discard(stream);
            // A pooled keep-alive socket may have been closed by the server
            // between requests; that failure isn't the caller's fault, so retry
            // once on a brand-new connection.
            if (reused and attempt == 0) continue;
            return e;
        };

        pool.release(stream, framed.reusable);
        return framed.raw;
    }
}

/// Resolve + connect a new TCP stream. The transient `Io` is only needed during
/// the call; the returned stream is just a socket handle and outlives it.
fn openStream(host: []const u8, port: u16) Error!net.Stream {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();
    const addr = net.IpAddress.resolve(io, host, port) catch return error.Resolve;
    return net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch return error.Connect;
}

/// Send `request_bytes` and read exactly one HTTP/1.1 response.
fn oneRequest(alloc: std.mem.Allocator, stream: net.Stream, request_bytes: []const u8) Error!Framed {
    var t: std.Io.Threaded = .init_single_threaded;
    const io = t.io();

    // Send.
    var wbuf: [8 * 1024]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    sw.interface.writeAll(request_bytes) catch return error.Send;
    sw.interface.flush() catch return error.Send;

    // Receive one framed response.
    var rbuf: [64 * 1024]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const r = &sr.interface;

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
            // "HTTP/1.0 ..." defaults to close unless keep-alive is requested.
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
                // Trailer section: read until the terminating blank line.
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
        // No framing info: body runs to EOF, connection can't be reused.
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
