/// IOKit Power Management — implements power state management and IOPMrootDomain.
/// Provides power management services for IOKit drivers.

const log = @import("../../lib/log.zig");
const SpinLock = @import("../../lib/spinlock.zig").SpinLock;

pub const MAX_POWER_STATES: usize = 8;
pub const MAX_POWER_DOMAINS: usize = 32;

/// Power state definition
pub const IOPowerState = struct {
    state_number: u32,
    capabilities: u32,
    output_power_characteristics: u32,
    input_power_requirements: u32,
    static_power: u32,
    gravity_power: u32,
    min_power: u32,
    max_power: u32,
};

/// Power domain
pub const IOPowerDomain = struct {
    id: u32,
    name: [32]u8,
    name_len: usize,
    parent: u32,
    state_count: u32,
    states: [MAX_POWER_STATES]IOPowerState,
    current_state: u32,
    active: bool,

    pub fn getName(self: *const IOPowerDomain) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// PM root domain
pub const IOPMrootDomain = struct {
    id: u32,
    power_state: u32,
    supported_states: u32,
    capabilities: u32,
    interest: u32,
    driver_connection_id: u32,
    active: bool,
};

const MAX_POWER_DOMAINS: usize = 32;
var domains: [MAX_POWER_DOMAINS]IOPowerDomain = undefined;
var domain_count: usize = 0;
var root_domain: ?*IOPMrootDomain = null;
var pm_lock: SpinLock = .{};

pub fn init() void {
    domain_count = 0;
    for (&domains) |*d| d.* = .{
        .id = 0,
        .name = [_]u8{0} ** 32,
        .name_len = 0,
        .parent = 0,
        .state_count = 0,
        .states = undefined,
        .current_state = 0,
        .active = false,
    };
    root_domain = null;
    log.info("IOKit Power Management initialized", .{});
}

pub fn createRootDomain() ?u32 {
    pm_lock.acquire();
    defer pm_lock.release();

    if (domain_count >= MAX_POWER_DOMAINS) return null;

    var domain = &domains[domain_count];
    domain.* = .{
        .id = @intCast(domain_count),
        .name = [_]u8{0} ** 32,
        .name_len = 9,
        .parent = 0,
        .state_count = 2,
        .states = undefined,
        .current_state = 0,
        .active = true,
    };
    @memcpy(domain.name[0..9], "RootDomain");

    domain.states[0] = .{
        .state_number = 0,
        .capabilities = 0,
        .output_power_characteristics = 0,
        .input_power_requirements = 0,
        .static_power = 0,
        .gravity_power = 0,
        .min_power = 0,
        .max_power = 0,
    };
    domain.states[1] = .{
        .state_number = 1,
        .capabilities = 0,
        .output_power_characteristics = 0,
        .input_power_requirements = 0,
        .static_power = 100,
        .gravity_power = 50,
        .min_power = 10,
        .max_power = 200,
    };

    const id = @as(u32, @intCast(domain_count));
    domain_count += 1;

    root_domain = @ptrFromInt(@intFromPtr(domain));
    log.debug("IOPMrootDomain created", .{});
    return id;
}

pub fn getRootDomain() ?*IOPMrootDomain {
    return root_domain;
}

pub fn createPowerDomain(parent_id: u32, name: []const u8) ?u32 {
    pm_lock.acquire();
    defer pm_lock.release();

    if (domain_count >= MAX_POWER_DOMAINS) return null;

    var domain = &domains[domain_count];
    domain.* = .{
        .id = @intCast(domain_count),
        .name = [_]u8{0} ** 32,
        .name_len = @min(name.len, 32),
        .parent = parent_id,
        .state_count = 1,
        .states = undefined,
        .current_state = 0,
        .active = true,
    };
    @memcpy(domain.name[0..domain.name_len], name[0..domain.name_len]);

    const id = @as(u32, @intCast(domain_count));
    domain_count += 1;
    return id;
}

pub fn setPowerDomainState(domain_id: u32, state: u32) u32 {
    pm_lock.acquire();
    defer pm_lock.release();

    if (domain_id >= MAX_POWER_DOMAINS) return 1;
    var domain = &domains[domain_id];
    if (!domain.active) return 1;

    if (state >= domain.state_count) return 1;
    domain.current_state = state;
    return 0;
}

pub fn getPowerDomainState(domain_id: u32) u32 {
    if (domain_id >= MAX_POWER_DOMAINS) return 0;
    if (!domains[domain_id].active) return 0;
    return domains[domain_id].current_state;
}
