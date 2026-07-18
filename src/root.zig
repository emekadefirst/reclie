//! reclie native engine — C-ABI bridge (Phase: skeleton).
//!
//! This is the boundary between CPython and the Zig core. It deliberately
//! does *not* pull in `Python.h` through translate-c: `Python.h` is a maze of
//! macros that C translators choke on, and we only need a dozen genuinely
//! ABI-stable C-API *functions*. So we hand-declare those `extern fn`
//! signatures and link against libpython (`python3.lib` on Windows — the
//! Py_LIMITED_API import library).
//!
//! What works today:
//!   * `pool_create(...)`  — builds a real `Pool` and hands it back wrapped
//!                           in a PyCapsule whose destructor frees it.
//!   * `submit(...)`       — callable; raises NotImplementedError (the HTTP
//!                           I/O path lands in the next phase).
//!   * `read_body(...)`    — callable; raises NotImplementedError.
//!
//! The module-def / PyInit plumbing lives in `py_module.c`; this file only
//! exports the `reclie_module_methods` table it references.

const std = @import("std");
const Pool = @import("core/pool.zig").Pool;
const http = @import("core/http.zig");
const transport = @import("core/transport.zig");
const Dispatch = @import("core/dispatch.zig").Dispatch;

// ---------------------------------------------------------------------------
// Minimal CPython C-API surface (Py_LIMITED_API, all ABI-stable functions).
//
// We only declare functions — never data symbols like `PyExc_*` or `Py_None`,
// because imported *data* on Windows needs `__declspec(dllimport)` thunking
// that Zig externs don't emit cleanly. Exception types are fetched at runtime
// from the `builtins` module instead (see `setError`).
// ---------------------------------------------------------------------------

/// Opaque CPython object handle. We never inspect its layout.
const PyObject = opaque {};

const PyCFunction = *const fn (self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject;
const PyCapsuleDestructor = *const fn (capsule: ?*PyObject) callconv(.c) void;

const METH_VARARGS: c_int = 0x0001;

extern fn PyTuple_Size(o: ?*PyObject) isize;
extern fn PyTuple_GetItem(o: ?*PyObject, index: isize) ?*PyObject;
extern fn PyLong_AsLong(o: ?*PyObject) c_long;
extern fn PyObject_IsTrue(o: ?*PyObject) c_int;
extern fn PyUnicode_AsUTF8AndSize(o: ?*PyObject, size: ?*isize) ?[*:0]const u8;
extern fn PyCapsule_New(pointer: ?*anyopaque, name: ?[*:0]const u8, destructor: ?PyCapsuleDestructor) ?*PyObject;
extern fn PyCapsule_GetPointer(capsule: ?*PyObject, name: ?[*:0]const u8) ?*anyopaque;
extern fn PyErr_Occurred() ?*PyObject;
extern fn PyErr_SetString(exc: ?*PyObject, message: [*:0]const u8) void;
extern fn PyImport_ImportModule(name: [*:0]const u8) ?*PyObject;
extern fn PyObject_GetAttrString(o: ?*PyObject, name: [*:0]const u8) ?*PyObject;
extern fn Py_DecRef(o: ?*PyObject) void;
extern fn Py_IncRef(o: ?*PyObject) void;

// Argument extraction for `submit`.
extern fn PyList_Size(o: ?*PyObject) isize;
extern fn PyList_GetItem(o: ?*PyObject, index: isize) ?*PyObject; // borrowed
extern fn PyBytes_AsStringAndSize(o: ?*PyObject, buffer: *?[*]u8, length: *isize) c_int;

// Object construction for the response.
extern fn PyLong_FromLong(v: c_long) ?*PyObject;
extern fn PyBytes_FromStringAndSize(v: ?[*]const u8, len: isize) ?*PyObject;
extern fn PyUnicode_FromStringAndSize(v: ?[*]const u8, len: isize) ?*PyObject;
extern fn PyUnicode_FromString(v: [*:0]const u8) ?*PyObject;
extern fn PyDict_New() ?*PyObject;
extern fn PyDict_SetItem(dict: ?*PyObject, key: ?*PyObject, value: ?*PyObject) c_int;

// Cross-thread GIL management and the asyncio hand-off.
const PyGILState_STATE = c_int;
extern fn PyGILState_Ensure() PyGILState_STATE;
extern fn PyGILState_Release(state: PyGILState_STATE) void;
extern fn PyObject_CallFunctionObjArgs(callable: ?*PyObject, ...) ?*PyObject;

/// PyMethodDef — layout must match CPython's exactly:
///   { const char *ml_name; PyCFunction ml_meth; int ml_flags; const char *ml_doc; }
const PyMethodDef = extern struct {
    ml_name: ?[*:0]const u8,
    ml_meth: ?PyCFunction,
    ml_flags: c_int,
    ml_doc: ?[*:0]const u8,
};

// ---------------------------------------------------------------------------
// Error helper — set a builtin exception without touching PyExc_* data symbols.
// ---------------------------------------------------------------------------

fn setError(exc_name: [*:0]const u8, message: [*:0]const u8) void {
    const builtins = PyImport_ImportModule("builtins") orelse return;
    defer Py_DecRef(builtins);
    const exc = PyObject_GetAttrString(builtins, exc_name) orelse return;
    defer Py_DecRef(exc);
    PyErr_SetString(exc, message);
}

// ---------------------------------------------------------------------------
// Pool capsule
// ---------------------------------------------------------------------------

const POOL_CAPSULE_NAME: [*:0]const u8 = "reclie.Pool";

/// Called by CPython when the capsule (and thus the Python `Client._pool`
/// reference) is garbage-collected. This is the pool-teardown hook promised
/// in the design.
fn poolCapsuleDestroy(capsule: ?*PyObject) callconv(.c) void {
    const raw = PyCapsule_GetPointer(capsule, POOL_CAPSULE_NAME) orelse return;
    const pool: *Pool = @ptrCast(@alignCast(raw));
    pool.destroy();
}

// ---------------------------------------------------------------------------
// Module methods
// ---------------------------------------------------------------------------

/// pool_create(host, port, tls, version, pool_size, ttl, timeout_ms, ca_bundle)
/// -> capsule wrapping a native Pool.
fn poolCreate(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    _ = self;

    if (PyTuple_Size(args) < 8) {
        setError("TypeError", "pool_create expects 8 arguments");
        return null;
    }

    var host_len: isize = 0;
    const host_c = PyUnicode_AsUTF8AndSize(PyTuple_GetItem(args, 0), &host_len) orelse return null;

    const port = PyLong_AsLong(PyTuple_GetItem(args, 1));
    const tls = PyObject_IsTrue(PyTuple_GetItem(args, 2)) != 0;
    const version = PyLong_AsLong(PyTuple_GetItem(args, 3));
    const pool_size = PyLong_AsLong(PyTuple_GetItem(args, 4));
    const ttl = PyLong_AsLong(PyTuple_GetItem(args, 5));
    const timeout_ms = PyLong_AsLong(PyTuple_GetItem(args, 6));

    // arg 7 is the CA bundle file path (empty string when TLS is disabled).
    var ca_len: isize = 0;
    const ca_c = PyUnicode_AsUTF8AndSize(PyTuple_GetItem(args, 7), &ca_len) orelse return null;

    // Any of the PyLong_AsLong / IsTrue calls above may have set an error.
    if (PyErr_Occurred() != null) return null;

    const host = host_c[0..@intCast(host_len)];
    const pool = Pool.create(std.heap.c_allocator, .{
        .host = host,
        .port = @intCast(port),
        .tls = tls,
        .version = @intCast(version),
        .pool_size = @intCast(pool_size),
        .ttl_seconds = @intCast(ttl),
        .timeout_ms = @intCast(timeout_ms),
        .ca_path = ca_c[0..@intCast(ca_len)],
    }) catch |e| {
        switch (e) {
            error.OutOfMemory => setError("MemoryError", "reclie: failed to allocate connection pool"),
            error.CaBundleLoad => setError("RuntimeError", "reclie: failed to load the TLS CA bundle"),
        }
        return null;
    };

    const capsule = PyCapsule_New(pool, POOL_CAPSULE_NAME, poolCapsuleDestroy) orelse {
        pool.destroy();
        return null;
    };
    return capsule;
}

// ---------------------------------------------------------------------------
// submit: hand a request to a worker thread, settle the Future when done.
// ---------------------------------------------------------------------------

/// Everything the worker thread needs, copied out of Python memory so it does
/// not touch any PyObject (except `future`/`loop`, which it only forwards to
/// `call_soon_threadsafe`) while off the GIL.
const RequestCtx = struct {
    pool: *Pool,
    host: []u8,
    port: u16,
    method: http.Method,
    path: []u8,
    headers: []http.Header, // each name/value owned
    body: []u8,
    future: *PyObject, // owned reference
    loop: *PyObject, // owned reference

    fn destroy(self: *RequestCtx) void {
        const a = std.heap.c_allocator;
        a.free(self.host);
        a.free(self.path);
        for (self.headers) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(self.headers);
        a.free(self.body);
        a.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Global request dispatcher — a small, fixed pool of persistent OS threads,
// started once (lazily, on the first submit()) instead of a thread spawned
// per request. See dispatch.zig for why.
// ---------------------------------------------------------------------------

const RequestDispatch = Dispatch(RequestCtx, worker);

var g_dispatch: ?*RequestDispatch = null;
var g_dispatch_lock: std.atomic.Value(bool) = .init(false);

/// Number of persistent I/O threads. Requests are blocking-socket-bound, not
/// CPU-bound, so this can comfortably exceed the core count — it just bounds
/// how many requests are in flight across *all* Clients/Pools in the process
/// at once. 64 matches `Client`'s default per-origin `pool_size`; tune as
/// needed once there's a benchmark showing a better number.
const default_worker_count: u32 = 64;

/// Returns the shared dispatcher, starting it on first use. Guarded by a
/// spinlock rather than `std.once` (removed in 0.16 alongside Thread.Mutex) —
/// this only runs once in practice, so a spin is irrelevant to steady-state
/// perf.
fn getDispatch() ?*RequestDispatch {
    if (g_dispatch) |d| return d;
    while (g_dispatch_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
    defer g_dispatch_lock.store(false, .release);
    if (g_dispatch) |d| return d; // lost the race to another thread; reuse theirs
    const d = RequestDispatch.start(std.heap.c_allocator, default_worker_count) catch return null;
    g_dispatch = d;
    return d;
}

/// submit(pool, method, path, headers, body, version, timeout_ms, future, loop) -> 0
///
/// Copies the request into a `RequestCtx` and hands it to the shared
/// dispatcher, which runs it on one of its persistent worker threads. Returns
/// immediately. The return value is unused by the Python caller; we return a
/// fresh int rather than reach for the `Py_None` data symbol.
fn submit(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    _ = self;
    const a = std.heap.c_allocator;

    if (PyTuple_Size(args) < 9) {
        setError("TypeError", "submit expects 9 arguments");
        return null;
    }

    const pool_raw = PyCapsule_GetPointer(PyTuple_GetItem(args, 0), POOL_CAPSULE_NAME) orelse
        return null;
    const pool: *Pool = @ptrCast(@alignCast(pool_raw));

    const method_ord = PyLong_AsLong(PyTuple_GetItem(args, 1));
    if (PyErr_Occurred() != null) return null;
    if (method_ord < 0 or method_ord > 6) {
        setError("ValueError", "submit: method ordinal out of range");
        return null;
    }
    const method: http.Method = @enumFromInt(@as(u8, @intCast(method_ord)));

    var path_len: isize = 0;
    const path_c = PyUnicode_AsUTF8AndSize(PyTuple_GetItem(args, 2), &path_len) orelse return null;

    // Body bytes.
    var body_ptr: ?[*]u8 = null;
    var body_len: isize = 0;
    if (PyBytes_AsStringAndSize(PyTuple_GetItem(args, 4), &body_ptr, &body_len) != 0) return null;

    // Build the owned copies. On any failure past here we must free partials.
    const host = a.dupe(u8, pool.host) catch return oom();
    errdefer a.free(host);
    const path = a.dupe(u8, path_c[0..@intCast(path_len)]) catch return oom();
    errdefer a.free(path);
    const body = a.dupe(u8, if (body_ptr) |p| p[0..@intCast(body_len)] else "") catch return oom();
    errdefer a.free(body);

    const headers = buildHeaders(PyTuple_GetItem(args, 3)) catch return oom();
    errdefer freeHeaders(headers);

    const ctx = a.create(RequestCtx) catch return oom();
    errdefer a.destroy(ctx);

    const future = PyTuple_GetItem(args, 7) orelse return null;
    const loop = PyTuple_GetItem(args, 8) orelse return null;
    Py_IncRef(future);
    Py_IncRef(loop);

    ctx.* = .{
        .pool = pool,
        .host = host,
        .port = pool.port,
        .method = method,
        .path = path,
        .headers = headers,
        .body = body,
        .future = future,
        .loop = loop,
    };

    const dispatch = getDispatch() orelse {
        Py_DecRef(future);
        Py_DecRef(loop);
        ctx.destroy();
        setError("RuntimeError", "reclie: failed to start I/O worker pool");
        return null;
    };
    dispatch.push(ctx) catch {
        Py_DecRef(future);
        Py_DecRef(loop);
        ctx.destroy();
        setError("RuntimeError", "reclie: failed to queue request");
        return null;
    };

    return PyLong_FromLong(0);
}

fn oom() ?*PyObject {
    setError("MemoryError", "reclie: out of memory building request");
    return null;
}

/// Convert a Python list of (name, value) str tuples into owned http.Headers.
fn buildHeaders(list: ?*PyObject) error{OutOfMemory}![]http.Header {
    const a = std.heap.c_allocator;
    const n_signed = PyList_Size(list);
    if (n_signed <= 0) return a.alloc(http.Header, 0);
    const n: usize = @intCast(n_signed);

    var out = try a.alloc(http.Header, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |h| {
            a.free(@constCast(h.name));
            a.free(@constCast(h.value));
        }
        a.free(out);
    }

    for (0..n) |i| {
        const pair = PyList_GetItem(list, @intCast(i));
        var name_len: isize = 0;
        var val_len: isize = 0;
        const name_c = PyUnicode_AsUTF8AndSize(PyTuple_GetItem(pair, 0), &name_len) orelse
            return error.OutOfMemory;
        const val_c = PyUnicode_AsUTF8AndSize(PyTuple_GetItem(pair, 1), &val_len) orelse
            return error.OutOfMemory;
        const name = try a.dupe(u8, name_c[0..@intCast(name_len)]);
        errdefer a.free(name);
        const value = try a.dupe(u8, val_c[0..@intCast(val_len)]);
        out[i] = .{ .name = name, .value = value };
        filled = i + 1;
    }
    return out;
}

fn freeHeaders(headers: []http.Header) void {
    const a = std.heap.c_allocator;
    for (headers) |h| {
        a.free(@constCast(h.name));
        a.free(@constCast(h.value));
    }
    a.free(headers);
}

/// Worker thread body: perform blocking I/O off the GIL, then settle.
fn worker(ctx: *RequestCtx) void {
    defer ctx.destroy();
    defer {
        // Release our references (call_soon_threadsafe took its own).
        const g = PyGILState_Ensure();
        Py_DecRef(ctx.future);
        Py_DecRef(ctx.loop);
        PyGILState_Release(g);
    }

    const a = std.heap.c_allocator;

    const req = http.writeRequest(a, ctx.method, ctx.path, ctx.host, ctx.port, ctx.headers, ctx.body, true) catch {
        finishError(ctx, 1, "out of memory building request");
        return;
    };
    defer a.free(req);

    const raw = transport.exchange(ctx.pool, a, req) catch |err| {
        switch (err) {
            error.Resolve => finishError(ctx, 1, "failed to resolve host"),
            error.Connect => finishError(ctx, 1, "connection failed"),
            error.Send => finishError(ctx, 1, "failed to send request"),
            error.Recv => finishError(ctx, 1, "connection reset while reading response"),
            error.Protocol => finishError(ctx, 4, "malformed HTTP response framing"),
            error.Tls => finishError(ctx, 3, "TLS handshake or certificate verification failed"),
            error.OutOfMemory => finishError(ctx, 1, "out of memory reading response"),
        }
        return;
    };
    defer a.free(raw);

    const resp = http.parseResponse(a, raw) catch {
        finishError(ctx, 4, "malformed HTTP response");
        return;
    };
    defer a.free(resp.headers);
    // Chunked bodies are decoded into a separate allocation; connection-close /
    // content-length bodies borrow `raw`. Free only the former.
    const body_borrows_raw = @intFromPtr(resp.body.ptr) >= @intFromPtr(raw.ptr) and
        @intFromPtr(resp.body.ptr) < @intFromPtr(raw.ptr) + raw.len;
    defer if (!body_borrows_raw) a.free(@constCast(resp.body));

    finishSuccess(ctx, resp.status_code, resp.headers, resp.body);
}

/// Schedule `_settle(future, status, headers, body, err_kind, err_msg)` on the
/// event loop. Must be called without the GIL held (it acquires it).
fn finish(
    ctx: *RequestCtx,
    status: c_long,
    headers: []const http.ParsedHeader,
    body: []const u8,
    err_kind: c_long,
    err_msg: [*:0]const u8,
) void {
    const g = PyGILState_Ensure();
    defer PyGILState_Release(g);

    const dict = PyDict_New() orelse return;
    defer Py_DecRef(dict);
    for (headers) |h| {
        const k = PyUnicode_FromStringAndSize(h.name.ptr, @intCast(h.name.len)) orelse continue;
        defer Py_DecRef(k);
        const v = PyUnicode_FromStringAndSize(h.value.ptr, @intCast(h.value.len)) orelse continue;
        defer Py_DecRef(v);
        _ = PyDict_SetItem(dict, k, v);
    }

    const body_obj = PyBytes_FromStringAndSize(body.ptr, @intCast(body.len)) orelse return;
    defer Py_DecRef(body_obj);
    const status_obj = PyLong_FromLong(status) orelse return;
    defer Py_DecRef(status_obj);
    const kind_obj = PyLong_FromLong(err_kind) orelse return;
    defer Py_DecRef(kind_obj);
    const msg_obj = PyUnicode_FromString(err_msg) orelse return;
    defer Py_DecRef(msg_obj);

    const mod = PyImport_ImportModule("reclie.core.http") orelse return;
    defer Py_DecRef(mod);
    const settle_fn = PyObject_GetAttrString(mod, "_settle") orelse return;
    defer Py_DecRef(settle_fn);
    const cst = PyObject_GetAttrString(ctx.loop, "call_soon_threadsafe") orelse return;
    defer Py_DecRef(cst);

    const handle = PyObject_CallFunctionObjArgs(
        cst,
        settle_fn,
        ctx.future,
        status_obj,
        dict,
        body_obj,
        kind_obj,
        msg_obj,
        @as(?*PyObject, null),
    );
    if (handle) |h| Py_DecRef(h);
}

fn finishSuccess(ctx: *RequestCtx, status: u16, headers: []const http.ParsedHeader, body: []const u8) void {
    finish(ctx, @intCast(status), headers, body, 0, "");
}

fn finishError(ctx: *RequestCtx, kind: c_long, msg: [*:0]const u8) void {
    finish(ctx, 0, &.{}, "", kind, msg);
}

/// read_body(ptr, len) -> bytes. Not yet implemented.
fn readBody(self: ?*PyObject, args: ?*PyObject) callconv(.c) ?*PyObject {
    _ = self;
    _ = args;
    setError("NotImplementedError", "reclie: read_body() has no arena to read yet");
    return null;
}

/// Sentinel-terminated method table. `py_module.c` declares this as
/// `extern PyMethodDef reclie_module_methods[]` and installs it in the
/// module def.
export var reclie_module_methods = [_]PyMethodDef{
    .{ .ml_name = "pool_create", .ml_meth = poolCreate, .ml_flags = METH_VARARGS, .ml_doc = "Create a native connection pool for an origin." },
    .{ .ml_name = "submit", .ml_meth = submit, .ml_flags = METH_VARARGS, .ml_doc = "Submit an HTTP request against a pool." },
    .{ .ml_name = "read_body", .ml_meth = readBody, .ml_flags = METH_VARARGS, .ml_doc = "Copy a response body out of the native arena." },
    .{ .ml_name = null, .ml_meth = null, .ml_flags = 0, .ml_doc = null },
};

test "reclie_module_methods is sentinel-terminated" {
    try std.testing.expect(reclie_module_methods[reclie_module_methods.len - 1].ml_name == null);
    try std.testing.expectEqualStrings("pool_create", std.mem.span(reclie_module_methods[0].ml_name.?));
}
