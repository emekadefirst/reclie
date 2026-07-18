//! Persistent worker-thread pool for running requests off the GIL.
//!
//! `root.zig`'s `submit()` used to call `std.Thread.spawn` for *every single
//! request* and `.detach()` it — a real OS thread-creation call (`clone()` on
//! Linux, `CreateThread` on Windows) plus a fresh stack mapping, on every
//! request, on top of whatever socket work `transport.exchange` does. At any
//! real request rate that dwarfs the cost of the actual I/O and defeats a good
//! chunk of the point of `pool.zig`'s connection reuse: the socket stops being
//! reopened, but the thread doesn't.
//!
//! `Dispatch` spawns a small, fixed number of OS threads ONCE and keeps them
//! parked for the life of the process. `submit()` pushes a job onto a shared
//! queue instead of spawning; whichever worker is free picks it up. No thread
//! is created or torn down per request.
//!
//! Zig 0.16 removed std.Thread.Mutex/Condition/Semaphore (see pool.zig's
//! comment on `lock_flag`); their std.Io.Mutex/Io.Condition replacements need
//! a real multithreaded `Io` to actually synchronize, which nothing on this
//! request path sets up (transport.zig deliberately uses transient
//! `init_single_threaded` Io per socket op). So, like pool.zig, this queue
//! uses a plain atomic spinlock — critical sections are a few pointer writes,
//! so spin contention is not a real concern — and workers back off with
//! `Thread.yield()` when there's nothing to do.

const std = @import("std");

/// `Job` is the payload type; `runJob` is called on a worker thread for each
/// popped job and owns freeing it (matches the previous `worker(ctx)` +
/// `ctx.destroy()` contract in root.zig).
pub fn Dispatch(comptime Job: type, comptime runJob: fn (*Job) void) type {
    return struct {
        const Self = @This();

        const Node = struct {
            job: *Job,
            next: ?*Node = null,
        };

        allocator: std.mem.Allocator,
        lock_flag: std.atomic.Value(bool) = .init(false),
        head: ?*Node = null,
        tail: ?*Node = null,
        threads: []std.Thread,

        /// Spawn `worker_count` persistent threads (min 1) and return the
        /// dispatcher. Threads run for the life of the process — same
        /// lifetime the old detached per-request threads had, just spawned
        /// once instead of per call.
        pub fn start(allocator: std.mem.Allocator, worker_count: u32) std.mem.Allocator.Error!*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{ .allocator = allocator, .threads = &.{} };

            const n = if (worker_count == 0) 1 else worker_count;
            const threads = try allocator.alloc(std.Thread, n);
            var spawned: usize = 0;
            for (threads) |*t| {
                t.* = std.Thread.spawn(.{}, workerLoop, .{self}) catch break;
                spawned += 1;
            }
            // If some threads failed to spawn, keep whichever did — a smaller
            // pool still beats failing the whole client. Only truly fails if
            // *none* spawned.
            if (spawned == 0) {
                allocator.free(threads);
                return error.OutOfMemory;
            }
            self.threads = threads[0..spawned];
            return self;
        }

        /// Enqueue `job` for a worker to pick up. Never blocks the caller.
        pub fn push(self: *Self, job: *Job) std.mem.Allocator.Error!void {
            const node = try self.allocator.create(Node);
            node.* = .{ .job = job };
            self.lock();
            if (self.tail) |t| {
                t.next = node;
                self.tail = node;
            } else {
                self.head = node;
                self.tail = node;
            }
            self.unlock();
        }

        fn pop(self: *Self) ?*Node {
            self.lock();
            defer self.unlock();
            const n = self.head orelse return null;
            self.head = n.next;
            if (self.head == null) self.tail = null;
            return n;
        }

        fn workerLoop(self: *Self) void {
            // Empty-queue backoff: yield a few times (cheap, low-latency —
            // covers the common case of a job landing microseconds later),
            // then fall back to short sleeps so an idle pool of `worker_count`
            // threads doesn't sit there burning CPU on pure spin. Resets the
            // moment a job shows up, so latency under real load is unaffected.
            var empty_polls: u32 = 0;
            while (true) {
                if (self.pop()) |node| {
                    empty_polls = 0;
                    runJob(node.job);
                    self.allocator.destroy(node);
                } else if (empty_polls < 100) {
                    empty_polls += 1;
                    std.Thread.yield() catch {};
                } else {
                    std.Thread.sleep(std.time.ns_per_ms);
                }
            }
        }

        fn lock(self: *Self) void {
            while (self.lock_flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.atomic.spinLoopHint();
            }
        }

        fn unlock(self: *Self) void {
            self.lock_flag.store(false, .release);
        }
    };
}
