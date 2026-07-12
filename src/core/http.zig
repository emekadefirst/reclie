const std = @import("std");

// ---------------------------------------------------------------------------
// Method
// ---------------------------------------------------------------------------

/// HTTP method ordinals — the contract with `reclie.Method` on the Python
/// side and the C-ABI wire format. Adding methods here means updating
/// `reclie/src/core/http.py::Method` to match.
pub const Method = enum(u8) {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn name(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// ---------------------------------------------------------------------------
// Request writer
// ---------------------------------------------------------------------------

/// Serialize an HTTP/1.1 request into a freshly-allocated byte slice.
///
/// The writer handles the standard required headers automatically:
///   - Host: omitted port for 80/443, included otherwise
///   - Connection: close (Phase 2 has no keep-alive)
///   - Content-Length: added if a body is present and the caller didn't
///     provide one
///   - User-Agent: defaulted to "reclie/0.1" if the caller didn't provide one
pub fn writeRequest(
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    host: []const u8,
    port: u16,
    headers: []const Header,
    body: []const u8,
    keep_alive: bool,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Status line.
    try buf.appendSlice(allocator, method.name());
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, path);
    try buf.appendSlice(allocator, " HTTP/1.1\r\n");

    // Host — required in HTTP/1.1.
    try buf.appendSlice(allocator, "Host: ");
    try buf.appendSlice(allocator, host);
    if (port != 80 and port != 443) {
        var port_buf: [8]u8 = undefined;
        const port_s = std.fmt.bufPrint(&port_buf, ":{d}", .{port}) catch unreachable;
        try buf.appendSlice(allocator, port_s);
    }
    try buf.appendSlice(allocator, "\r\n");

    try buf.appendSlice(allocator, if (keep_alive)
        "Connection: keep-alive\r\n"
    else
        "Connection: close\r\n");

    // Caller headers — track whether they set User-Agent / Content-Length
    // so we don't duplicate them.
    var has_ua = false;
    var has_cl = false;
    for (headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) has_ua = true;
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Length")) has_cl = true;
        try buf.appendSlice(allocator, h.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, h.value);
        try buf.appendSlice(allocator, "\r\n");
    }

    if (!has_ua) try buf.appendSlice(allocator, "User-Agent: reclie/0.1\r\n");
    if (body.len > 0 and !has_cl) {
        var cl_buf: [32]u8 = undefined;
        const cl_s = std.fmt.bufPrint(&cl_buf, "Content-Length: {d}\r\n", .{body.len}) catch unreachable;
        try buf.appendSlice(allocator, cl_s);
    }

    try buf.appendSlice(allocator, "\r\n");
    if (body.len > 0) try buf.appendSlice(allocator, body);

    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Response parser
// ---------------------------------------------------------------------------

pub const ParseError = error{
    Truncated, // headers or body terminated mid-stream
    MalformedStatusLine,
    MalformedHeader,
    InvalidContentLength,
    InvalidChunkSize,
    UnsupportedTransferEncoding,
};

/// A parsed response. All slice fields point into `raw` — keep it alive.
pub const Response = struct {
    /// The complete recv buffer. Owned by the same allocator that parsed it.
    raw: []const u8,
    status_code: u16,
    /// Slices reference `raw`. Header order is preserved; lookup is linear
    /// scan (case-insensitive on the Python side via `RecliHeaders`).
    headers: []const ParsedHeader,
    /// Slice of `raw` containing exactly the body bytes (no terminator).
    body: []const u8,
};

pub const ParsedHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Parse a complete HTTP/1.1 response out of `raw`. The parser does not
/// copy — `Response` borrows offsets into the buffer.
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) !Response {
    const headers_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.Truncated;
    const head = raw[0..headers_end];
    const body_start = headers_end + 4;

    // Status line: `HTTP/1.x SSS REASON`. We tolerate either `\r\n` or `\n`
    // line endings between headers but require `\r\n\r\n` at the boundary.
    const eol1 = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const status_line = head[0..eol1];

    var sl = std.mem.splitScalar(u8, status_line, ' ');
    _ = sl.next() orelse return error.MalformedStatusLine; // version, ignored
    const status_str = sl.next() orelse return error.MalformedStatusLine;
    const status_code = std.fmt.parseInt(u16, status_str, 10) catch
        return error.MalformedStatusLine;

    // Headers.
    var header_list: std.ArrayList(ParsedHeader) = .empty;
    errdefer header_list.deinit(allocator);

    var content_length: ?usize = null;
    var transfer_encoding: ?[]const u8 = null;

    if (eol1 < head.len) {
        var lines = std.mem.splitSequence(u8, head[eol1 + 2 ..], "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse
                return error.MalformedHeader;
            const name = line[0..colon];

            // Skip OWS after the colon (RFC 7230 §3.2.4).
            var val_start = colon + 1;
            while (val_start < line.len and (line[val_start] == ' ' or line[val_start] == '\t')) {
                val_start += 1;
            }
            const value = line[val_start..];

            if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
                content_length = std.fmt.parseInt(usize, value, 10) catch
                    return error.InvalidContentLength;
            } else if (std.ascii.eqlIgnoreCase(name, "Transfer-Encoding")) {
                transfer_encoding = value;
            }

            try header_list.append(allocator, .{ .name = name, .value = value });
        }
    }

    // Body — Phase 2 supports two cases:
    //   1) Content-Length: N → body is exactly the next N bytes
    //   2) No Content-Length, no chunked → body runs to EOF (Connection: close)
    // Phase 3 added: Transfer-Encoding: chunked.
    if (transfer_encoding) |te| {
        if (std.ascii.eqlIgnoreCase(te, "chunked")) {
            const body = try decodeChunked(allocator, raw[body_start..]);
            return .{
                .raw = raw,
                .status_code = status_code,
                .headers = try header_list.toOwnedSlice(allocator),
                .body = body,
            };
        }
        if (!std.ascii.eqlIgnoreCase(te, "identity")) {
            return error.UnsupportedTransferEncoding;
        }
    }

    const remaining = raw[body_start..];
    const body: []const u8 = if (content_length) |cl| blk: {
        if (cl > remaining.len) return error.Truncated;
        break :blk remaining[0..cl];
    } else remaining;

    return .{
        .raw = raw,
        .status_code = status_code,
        .headers = try header_list.toOwnedSlice(allocator),
        .body = body,
    };
}

/// Decode an HTTP/1.1 chunked body into a flat byte slice owned by
/// ``allocator``. Stops at the zero-length chunk and ignores any trailers.
fn decodeChunked(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var pos: usize = 0;
    while (pos < src.len) {
        // Chunk size line: hex digits, optional `;extension`, then `\r\n`.
        const line_end = std.mem.indexOfPos(u8, src, pos, "\r\n") orelse return error.Truncated;
        var size_end = line_end;
        // Trim chunk extensions (anything after `;`).
        if (std.mem.indexOfScalarPos(u8, src[0..line_end], pos, ';')) |semi| size_end = semi;
        const size_str = src[pos..size_end];
        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, size_str, " \t"), 16) catch
            return error.InvalidContentLength;

        pos = line_end + 2;

        if (chunk_size == 0) {
            // Last chunk. Skip optional trailers up to the final \r\n.
            return out.toOwnedSlice(allocator);
        }

        if (pos + chunk_size > src.len) return error.Truncated;
        try out.appendSlice(allocator, src[pos .. pos + chunk_size]);
        pos += chunk_size;

        if (pos + 2 > src.len) return error.Truncated;
        if (src[pos] != '\r' or src[pos + 1] != '\n') return error.MalformedHeader;
        pos += 2;
    }

    return error.Truncated;
}

// ---------------------------------------------------------------------------
// Streaming chunked decoder — for SSE / WebSocket bodies that are
// transferred chunked but consumed incrementally rather than all-at-once.
// ---------------------------------------------------------------------------

pub const ChunkDecoder = struct {
    state: State = .size_line,
    bytes_remaining: usize = 0,
    /// Accumulator for the chunk-size line (hex digits + optional ext).
    size_line: std.ArrayList(u8) = .empty,
    /// True once we've seen the terminating zero-chunk.
    finished: bool = false,

    pub const State = enum { size_line, chunk_data, after_chunk_crlf };

    pub fn deinit(self: *ChunkDecoder, allocator: std.mem.Allocator) void {
        self.size_line.deinit(allocator);
    }

    /// Feed raw bytes from the wire. Decoded body bytes are appended to
    /// ``out``. Returns once `input` is consumed (or the zero-chunk has
    /// been seen, after which `finished` is true).
    pub fn feed(
        self: *ChunkDecoder,
        allocator: std.mem.Allocator,
        input: []const u8,
        out: *std.ArrayList(u8),
    ) !void {
        var i: usize = 0;
        while (i < input.len and !self.finished) {
            switch (self.state) {
                .size_line => {
                    const b = input[i];
                    i += 1;
                    if (b == '\n') {
                        // End of size line. Strip optional CR and `;ext`.
                        var line = self.size_line.items;
                        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
                        if (std.mem.indexOfScalar(u8, line, ';')) |semi| line = line[0..semi];
                        const size = std.fmt.parseInt(usize, std.mem.trim(u8, line, " \t"), 16) catch
                            return error.InvalidContentLength;
                        self.size_line.clearRetainingCapacity();

                        if (size == 0) {
                            self.finished = true;
                            // We don't bother consuming trailers — the caller
                            // is done after this point.
                            return;
                        }
                        self.bytes_remaining = size;
                        self.state = .chunk_data;
                    } else {
                        try self.size_line.append(allocator, b);
                    }
                },
                .chunk_data => {
                    const take = @min(self.bytes_remaining, input.len - i);
                    try out.appendSlice(allocator, input[i .. i + take]);
                    i += take;
                    self.bytes_remaining -= take;
                    if (self.bytes_remaining == 0) self.state = .after_chunk_crlf;
                },
                .after_chunk_crlf => {
                    // Skip the \r\n that follows each chunk's data.
                    const b = input[i];
                    i += 1;
                    if (b == '\n') self.state = .size_line;
                    // CR is ignored; any other byte is technically malformed
                    // but we tolerate to match server quirks.
                },
            }
        }
    }
};

test "ChunkDecoder: streams across feeds" {
    const allocator = std.testing.allocator;
    var dec: ChunkDecoder = .{};
    defer dec.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    // Two chunks split across feeds.
    try dec.feed(allocator, "5\r\nhel", &out);
    try std.testing.expect(!dec.finished);
    try dec.feed(allocator, "lo\r\n6\r\n wor", &out);
    try dec.feed(allocator, "ld\r\n0\r\n\r\n", &out);
    try std.testing.expect(dec.finished);
    try std.testing.expectEqualStrings("hello world", out.items);
}

// ---------------------------------------------------------------------------
// HTTP/2 type shells (Phase 5)
// ---------------------------------------------------------------------------

pub const Http2Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = false,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65_535,
    max_frame_size: u32 = 16_384,
    max_header_list_size: u32 = std.math.maxInt(u32),
};

pub const Http2Engine = struct {
    arena: *std.heap.ArenaAllocator,
    next_stream_id: u31 = 1,
    window_size_conn: i32 = 65_535,
    settings: Http2Settings = .{},

    pub fn init(arena: *std.heap.ArenaAllocator) Http2Engine {
        return .{ .arena = arena };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "writeRequest: minimal GET" {
    const allocator = std.testing.allocator;
    const out = try writeRequest(allocator, .GET, "/products", "example.com", 443, &.{}, &.{}, false);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "GET /products HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Host: example.com\r\n") != null); // no port for 443
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "User-Agent: reclie/0.1\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
}

test "writeRequest: includes port for non-default" {
    const allocator = std.testing.allocator;
    const out = try writeRequest(allocator, .GET, "/", "localhost", 8080, &.{}, &.{}, false);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Host: localhost:8080\r\n") != null);
}

test "writeRequest: keep-alive sends the keep-alive header" {
    const allocator = std.testing.allocator;
    const out = try writeRequest(allocator, .GET, "/", "example.com", 443, &.{}, &.{}, true);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: keep-alive\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Connection: close\r\n") == null);
}

test "writeRequest: POST with JSON body adds Content-Length" {
    const allocator = std.testing.allocator;
    const headers = [_]Header{.{ .name = "Content-Type", .value = "application/json" }};
    const body = "{\"a\":1}";
    const out = try writeRequest(allocator, .POST, "/items", "api.example.com", 443, &headers, body, false);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "POST /items HTTP/1.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Type: application/json\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Content-Length: 7\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, body));
}

test "writeRequest: respects caller's User-Agent and Content-Length" {
    const allocator = std.testing.allocator;
    const headers = [_]Header{
        .{ .name = "User-Agent", .value = "custom/1.0" },
        .{ .name = "Content-Length", .value = "0" },
    };
    const out = try writeRequest(allocator, .POST, "/", "h", 80, &headers, "ignored-body", false);
    defer allocator.free(out);

    // Default User-Agent should NOT be added when caller already set one.
    try std.testing.expect(std.mem.indexOf(u8, out, "User-Agent: custom/1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "User-Agent: reclie/0.1") == null);
    // Default Content-Length should NOT override the caller's.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "Content-Length:"));
}

test "parseResponse: 200 with Content-Length body" {
    const allocator = std.testing.allocator;
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: 13\r\n" ++
        "\r\n" ++
        "{\"hello\":1}\r\n";

    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    const resp = try parseResponse(allocator, buf);
    defer allocator.free(resp.headers);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 2), resp.headers.len);
    try std.testing.expectEqualStrings("Content-Type", resp.headers[0].name);
    try std.testing.expectEqualStrings("application/json", resp.headers[0].value);
    try std.testing.expectEqual(@as(usize, 13), resp.body.len);
}

test "parseResponse: 404 with empty body" {
    const allocator = std.testing.allocator;
    const raw = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";

    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    const resp = try parseResponse(allocator, buf);
    defer allocator.free(resp.headers);

    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    try std.testing.expectEqual(@as(usize, 0), resp.body.len);
}

test "parseResponse: connection-close body runs to EOF" {
    const allocator = std.testing.allocator;
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "\r\n" ++
        "raw payload";

    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    const resp = try parseResponse(allocator, buf);
    defer allocator.free(resp.headers);

    try std.testing.expectEqualStrings("raw payload", resp.body);
}

test "parseResponse: chunked transfer encoding" {
    const allocator = std.testing.allocator;
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5\r\n" ++ "hello" ++ "\r\n" ++
        "6\r\n" ++ " world" ++ "\r\n" ++
        "0\r\n" ++
        "\r\n";

    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    const resp = try parseResponse(allocator, buf);
    defer allocator.free(resp.headers);
    defer allocator.free(resp.body);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("hello world", resp.body);
}

test "parseResponse: chunked with extensions" {
    const allocator = std.testing.allocator;
    const raw =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "\r\n" ++
        "5;name=value\r\n" ++ "first" ++ "\r\n" ++
        "0\r\n" ++
        "\r\n";

    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);

    const resp = try parseResponse(allocator, buf);
    defer allocator.free(resp.headers);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("first", resp.body);
}

test "parseResponse: chunked is not yet supported" {
    // Old test repurposed: with an UNKNOWN transfer-encoding the parser
    // still rejects.
    const allocator = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: weird\r\n\r\n";
    const buf = try allocator.dupe(u8, raw);
    defer allocator.free(buf);
    try std.testing.expectError(error.UnsupportedTransferEncoding, parseResponse(allocator, buf));
}

test "Http2Engine: type shell still compiles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const engine = Http2Engine.init(&arena);
    try std.testing.expect(engine.next_stream_id % 2 == 1);
}
