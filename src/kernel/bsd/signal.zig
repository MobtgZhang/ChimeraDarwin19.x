/// POSIX Signal Handling — signal delivery, masking, and action management.
/// Numbers follow Darwin/macOS conventions.

const log = @import("../../lib/log.zig");

pub const NSIG: usize = 32;

pub const Signal = enum(u8) {
    SIGHUP = 1,
    SIGINT = 2,
    SIGQUIT = 3,
    SIGILL = 4,
    SIGTRAP = 5,
    SIGABRT = 6,
    SIGEMT = 7,
    SIGFPE = 8,
    SIGKILL = 9,
    SIGBUS = 10,
    SIGSEGV = 11,
    SIGSYS = 12,
    SIGPIPE = 13,
    SIGALRM = 14,
    SIGTERM = 15,
    SIGURG = 16,
    SIGSTOP = 17,
    SIGTSTP = 18,
    SIGCONT = 19,
    SIGCHLD = 20,
    SIGTTIN = 21,
    SIGTTOU = 22,
    SIGIO = 23,
    SIGXCPU = 24,
    SIGXFSZ = 25,
    SIGVTALRM = 26,
    SIGPROF = 27,
    SIGWINCH = 28,
    SIGINFO = 29,
    SIGUSR1 = 30,
    SIGUSR2 = 31,
    _,
};

pub const SigAction = enum(u8) {
    default,
    ignore,
    handler,
};

pub const SA_SIGINFO: u32 = 0x0040;
pub const SA_RESTART: u32 = 0x0002;
pub const SA_NOCLDSTOP: u32 = 0x0008;
pub const SA_NODEFER: u32 = 0x0010;
pub const SA_RESETHAND: u32 = 0x0004;
pub const SA_ONSTACK: u32 = 0x0001;
pub const SA_SEVTCLR: u32 = 0x0080;

pub const SignalDisposition = struct {
    action: SigAction,
    handler: ?*const fn (u8) void,
    sigaction_handler: ?*const fn (sig: u32, info: *SigInfo, ctx: *u8) void,
    flags: u32,

    pub fn initFlags() SignalDisposition {
        return .{
            .action = .default,
            .handler = null,
            .sigaction_handler = null,
            .flags = 0,
        };
    }
};

pub const SigInfo = extern struct {
    si_signo: i32,
    si_errno: i32,
    si_code: i32,
    si_addr: u64,
    si_value: u64,
    si_pid: u32,
    si_uid: u32,
};

pub const SI_USER: i32 = 0;
pub const SI_KERNEL: i32 = 0x80;
pub const ILL_ILLOPC: i32 = 1;
pub const FPE_INTDIV: i32 = 1;
pub const SEGV_MAPERR: i32 = 1;
pub const BUS_ADRERR: i32 = 1;
pub const TRAP_BRKPT: i32 = 1;
pub const TRAP_TRACE: i32 = 2;
pub const CLD_EXITED: i32 = 1;
pub const CLD_KILLED: i32 = 2;
pub const CLD_DUMPED: i32 = 3;
pub const CLD_STOPPED: i32 = 5;
pub const CLD_CONTINUED: i32 = 6;

pub const SignalSet = packed struct(u32) {
    bits: u32 = 0,

    pub fn add(self: *SignalSet, sig: u8) void {
        if (sig == 0 or sig >= NSIG) return;
        self.bits |= @as(u32, 1) << @intCast(sig);
    }

    pub fn remove(self: *SignalSet, sig: u8) void {
        if (sig == 0 or sig >= NSIG) return;
        self.bits &= ~(@as(u32, 1) << @intCast(sig));
    }

    pub fn contains(self: SignalSet, sig: u8) bool {
        if (sig == 0 or sig >= NSIG) return false;
        return self.bits & (@as(u32, 1) << @intCast(sig)) != 0;
    }

    pub fn isEmpty(self: SignalSet) bool {
        return self.bits == 0;
    }

    pub fn firstPending(self: SignalSet) ?u8 {
        if (self.bits == 0) return null;
        var i: u8 = 1;
        while (i < NSIG) : (i += 1) {
            if (self.bits & (@as(u32, 1) << @intCast(i)) != 0) return i;
        }
        return null;
    }

    pub fn empty() SignalSet {
        return .{ .bits = 0 };
    }

    pub fn full() SignalSet {
        return .{ .bits = 0xFFFF_FFFE };
    }

    pub fn fill(self: *SignalSet) void {
        self.bits = 0xFFFF_FFFE;
    }
};

pub const SignalState = struct {
    actions: [NSIG]SignalDisposition,
    pending: SignalSet,
    blocked: SignalSet,
    sigaltstack_used: bool,

    pub fn init() SignalState {
        var s: SignalState = undefined;
        for (&s.actions) |*a| {
            a.* = SignalDisposition.initFlags();
        }
        s.pending = SignalSet.empty();
        s.blocked = SignalSet.empty();
        s.sigaltstack_used = false;
        return s;
    }

    pub fn setAction(self: *SignalState, sig: u8, action: SigAction, handler: ?*const fn (u8) void, flags: u32) bool {
        if (sig == 0 or sig >= NSIG) return false;
        if (sig == @intFromEnum(Signal.SIGKILL) or sig == @intFromEnum(Signal.SIGSTOP))
            return false;
        self.actions[sig] = .{ .action = action, .handler = handler, .sigaction_handler = null, .flags = flags };
        return true;
    }

    pub fn setSigaction(self: *SignalState, sig: u8, handler: *const fn (u32, *SigInfo, *u8) void, flags: u32) bool {
        if (sig == 0 or sig >= NSIG) return false;
        if (sig == @intFromEnum(Signal.SIGKILL) or sig == @intFromEnum(Signal.SIGSTOP))
            return false;
        self.actions[sig] = .{ .action = .handler, .handler = null, .sigaction_handler = handler, .flags = flags | SA_SIGINFO };
        return true;
    }

    pub fn postSignal(self: *SignalState, sig: u8) void {
        if (sig == 0 or sig >= NSIG) return;
        self.pending.add(sig);
    }

    pub fn dequeueSignal(self: *SignalState) ?u8 {
        const deliverable = SignalSet{ .bits = self.pending.bits & ~self.blocked.bits };
        const sig = deliverable.firstPending() orelse return null;
        self.pending.remove(sig);
        return sig;
    }

    pub fn deliverPending(self: *SignalState) void {
        while (self.dequeueSignal()) |sig| {
            const disp = self.actions[sig];
            switch (disp.action) {
                .ignore => {},
                .handler => {
                    if (disp.handler) |h| h(sig);
                },
                .default => defaultAction(sig),
            }
        }
    }

    pub fn deliverSiginfo(self: *SignalState, sig: u32, info: *SigInfo, ctx: *u8) void {
        if (sig == 0 or sig >= NSIG) return;
        const disp = self.actions[@as(u8, @intCast(sig))];
        if (disp.sigaction_handler) |h| {
            h(sig, info, ctx);
        } else if (disp.handler) |h| {
            h(@as(u8, @intCast(sig)));
        } else {
            defaultAction(@as(u8, @intCast(sig)));
        }
    }

    pub fn setMask(self: *SignalState, how: u32, new_mask: SignalSet) void {
        switch (how) {
            0 => self.blocked.bits = new_mask.bits,
            1 => self.blocked.bits |= new_mask.bits,
            2 => self.blocked.bits &= ~new_mask.bits,
            3 => self.blocked.bits = (self.blocked.bits & ~new_mask.bits) | (self.blocked.bits & new_mask.bits),
            else => {},
        }
    }

    pub fn getMask(self: *const SignalState) SignalSet {
        return self.blocked;
    }
};

pub fn sigaltstack(ss: ?*const SigAltStack, old_ss: ?*SigAltStack) i32 {
    if (old_ss) |oss| {
        oss.ss_sp = 0;
        oss.ss_size = 0;
        oss.ss_flags = 0;
    }
    _ = ss;
    return 0;
}

pub const SigAltStack = struct {
    ss_sp: u64,
    ss_size: u64,
    ss_flags: u32,

    pub const SS_DISABLE: u32 = 0x0004;
    pub const SS_ONSTACK: u32 = 0x0001;
};

pub fn sigwaitinfo(mask: SignalSet, info: *SigInfo) i32 {
    _ = mask;
    _ = info;
    return 0;
}

pub fn sigtimedwait(mask: SignalSet, info: *SigInfo, timeout: *const TimeSpec) i32 {
    _ = mask;
    _ = info;
    _ = timeout;
    return 0;
}

pub const TimeSpec = struct {
    tv_sec: i64,
    tv_nsec: i64,
};

fn defaultAction(sig: u8) void {
    switch (sig) {
        @intFromEnum(Signal.SIGCHLD),
        @intFromEnum(Signal.SIGURG),
        @intFromEnum(Signal.SIGWINCH),
        @intFromEnum(Signal.SIGINFO),
        => {},

        @intFromEnum(Signal.SIGSTOP),
        @intFromEnum(Signal.SIGTSTP),
        @intFromEnum(Signal.SIGTTIN),
        @intFromEnum(Signal.SIGTTOU),
        => {
            log.debug("Signal {}: stop (stub)", .{sig});
        },

        @intFromEnum(Signal.SIGCONT) => {
            log.debug("Signal {}: continue (stub)", .{sig});
        },

        else => {
            log.info("Signal {}: terminate (default)", .{sig});
        },
    }
}
