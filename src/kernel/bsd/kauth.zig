/// BSD Authorization (kauth) — kernel authorization framework.
/// Provides hooks for file system, process, and socket authorization.

const log = @import("../../../lib/log.zig");
const SpinLock = @import("../../../lib/spinlock.zig").SpinLock;

pub const MAX_AUTHENTICATORS: usize = 16;
pub const MAX_AUTH_SCOPES: usize = 16;

/// Authorization scope types
pub const AuthScope = enum(u32) {
    system_generic = 0,
    fileop = 1,
    vnode = 2,
    socket = 3,
    process = 4,
    proc_pid = 5,
    iokit_user_client = 6,
    filesystem = 7,
};

/// Authorization result
pub const AuthResult = enum(u32) {
    DENY = 0,
    ALLOW = 1,
    DEFER = 2,
};

/// Authorizer callback
pub const AuthCallback = *const fn (id: u32, arg: u32) AuthResult;

/// Authenticator entry
pub const Authenticator = struct {
    scope: AuthScope,
    callback: ?AuthCallback,
    active: bool,
};

var authenticators: [MAX_AUTHENTICATORS]Authenticator = undefined;
var auth_count: usize = 0;
var auth_lock: SpinLock = .{};

pub fn init() void {
    auth_count = 0;
    for (&authenticators) |*a| a.* = .{ .scope = .system_generic, .callback = null, .active = false };
    log.info("BSD kauth subsystem initialized", .{});
}

pub fn registerAuthenticator(scope: AuthScope, callback: ?AuthCallback) ?u32 {
    auth_lock.acquire();
    defer auth_lock.release();

    if (auth_count >= MAX_AUTHENTICATORS) return null;

    const id = @as(u32, @intCast(auth_count));
    authenticators[auth_count] = .{
        .scope = scope,
        .callback = callback,
        .active = true,
    };
    auth_count += 1;
    return id;
}

pub fn unregisterAuthenticator(id: u32) void {
    auth_lock.acquire();
    defer auth_lock.release();

    if (id >= MAX_AUTHENTICATORS) return;
    authenticators[id].active = false;
    authenticators[id].callback = null;
}

pub fn authorize(scope: AuthScope, arg: u32) AuthResult {
    auth_lock.acquire();
    defer auth_lock.release();

    for (authenticators[0..auth_count]) |auth| {
        if (!auth.active) continue;
        if (auth.scope != scope) continue;
        if (auth.callback) |cb| {
            const result = cb(0, arg);
            if (result != .DEFER) return result;
        }
    }
    return .ALLOW;
}

// ── VNode authorization hooks ──────────────────────────────

pub fn vnodeCheckAccess(path: [*]const u8, mode: u32, cred: u32) AuthResult {
    _ = path;
    _ = mode;
    _ = cred;
    return authorize(.vnode, 0);
}

pub fn vnodeCheckOpen(path: [*]const u8, oflag: u32, cred: u32) AuthResult {
    _ = path;
    _ = oflag;
    _ = cred;
    return authorize(.vnode, 1);
}

pub fn vnodeCheckDelete(path: [*]const u8, cred: u32) AuthResult {
    _ = path;
    _ = cred;
    return authorize(.vnode, 2);
}

// ── Socket authorization hooks ─────────────────────────────

pub fn socketCheckBind(sock_id: u32, port: u32, cred: u32) AuthResult {
    _ = sock_id;
    _ = port;
    _ = cred;
    return authorize(.socket, 0);
}

pub fn socketCheckConnect(sock_id: u32, cred: u32) AuthResult {
    _ = sock_id;
    _ = cred;
    return authorize(.socket, 1);
}

// ── Process authorization hooks ───────────────────────────

pub fn processCheckExec(pid: u32, path: [*]const u8, cred: u32) AuthResult {
    _ = pid;
    _ = path;
    _ = cred;
    return authorize(.process, 0);
}

pub fn processCheckSignal(pid: u32, sig: u32, cred: u32) AuthResult {
    _ = pid;
    _ = sig;
    _ = cred;
    return authorize(.process, 1);
}
