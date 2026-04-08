/// IOService — base class for all I/O Kit drivers.
/// Each service has a lifecycle: init → probe → start → stop → free.
/// Services register with the IORegistry and match against provider nodes.

const log = @import("../../lib/log.zig");
const registry = @import("registry.zig");

pub const ServiceState = enum(u8) {
    inactive,
    registered,
    matched,
    started,
    stopped,
};

pub const IOServiceOps = struct {
    probe: ?*const fn (service: *IOService, provider: *registry.IORegNode) i32,
    start: ?*const fn (service: *IOService, provider: *registry.IORegNode) bool,
    stop: ?*const fn (service: *IOService) void,
    message: ?*const fn (service: *IOService, msg_type: u32, arg: u64) i32,
};

pub const MAX_SERVICES: usize = 64;

pub const IOService = struct {
    id: u32,
    name: [64]u8,
    name_len: usize,
    state: ServiceState,
    ops: IOServiceOps,
    provider_class: [64]u8,
    provider_class_len: usize,
    reg_node: ?*registry.IORegNode,
    active: bool,
    ref_count: u32,

    pub fn getName(self: *const IOService) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn getProviderClass(self: *const IOService) []const u8 {
        return self.provider_class[0..self.provider_class_len];
    }

    pub fn retain(self: *IOService) void {
        self.ref_count += 1;
    }

    pub fn release(self: *IOService) void {
        if (self.ref_count > 0) {
            self.ref_count -= 1;
        }
    }
};

var services: [MAX_SERVICES]IOService = undefined;
var service_count: usize = 0;

pub fn init() void {
    service_count = 0;
    for (&services) |*s| s.active = false;
    log.info("IOService subsystem initialized", .{});
}

pub fn registerService(
    name: []const u8,
    provider_class: []const u8,
    ops: IOServiceOps,
) ?*IOService {
    if (service_count >= MAX_SERVICES) return null;
    var s = &services[service_count];
    s.* = .{
        .id = @intCast(service_count),
        .name = [_]u8{0} ** 64,
        .name_len = @min(name.len, 64),
        .state = .registered,
        .ops = ops,
        .provider_class = [_]u8{0} ** 64,
        .provider_class_len = @min(provider_class.len, 64),
        .reg_node = null,
        .active = true,
        .ref_count = 1,
    };
    @memcpy(s.name[0..s.name_len], name[0..s.name_len]);
    @memcpy(s.provider_class[0..s.provider_class_len], provider_class[0..s.provider_class_len]);

    s.reg_node = registry.allocNode(name, name);
    if (s.reg_node) |rn| {
        if (registry.getRoot()) |root| {
            root.addChild(rn);
        }
    }

    service_count += 1;
    log.debug("IOService registered: '{s}' (provider: '{s}')", .{
        s.getName(), s.getProviderClass(),
    });
    return s;
}

pub fn matchServices() void {
    for (0..service_count) |i| {
        var s = &services[i];
        if (!s.active or s.state != .registered) continue;

        const provider = registry.findByClass(s.getProviderClass()) orelse continue;

        if (s.ops.probe) |probe_fn| {
            const score = probe_fn(s, provider);
            if (score <= 0) continue;
        }
        s.state = .matched;

        if (s.ops.start) |start_fn| {
            if (start_fn(s, provider)) {
                s.state = .started;
                log.info("IOService '{s}' started on '{s}'", .{
                    s.getName(), provider.getName(),
                });
            } else {
                s.state = .registered;
            }
        }
    }
}

pub fn stopService(s: *IOService) void {
    if (s.state != .started) return;
    if (s.ops.stop) |stop_fn| stop_fn(s);
    s.state = .stopped;
}

pub fn lookupService(name: []const u8) ?*IOService {
    for (0..service_count) |i| {
        if (!services[i].active) continue;
        if (strEql(services[i].name[0..services[i].name_len], name))
            return &services[i];
    }
    return null;
}

pub fn stopAllServices() void {
    for (0..service_count) |i| {
        stopService(&services[i]);
    }
}

// ── IOServiceOpen/Close ──────────────────────────────────

pub const IOServiceOpenArgs = struct {
    service: *IOService,
    connect_type: u32,
    user_client_type: [*]const u8,
};

pub const IOServiceCloseArgs = struct {
    service: *IOService,
};

pub fn serviceOpen(args: IOServiceOpenArgs) ?u32 {
    const s = args.service;
    if (s.state != .started) return null;

    log.debug("IOServiceOpen: '{s}' connect_type={}", .{ s.getName(), args.connect_type });
    return s.retain();
}

pub fn serviceClose(args: IOServiceCloseArgs) void {
    const s = args.service;
    s.release();
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (ca != cb) return false;
    return true;
}
