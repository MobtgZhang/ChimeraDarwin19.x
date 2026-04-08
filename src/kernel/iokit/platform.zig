/// IOKit Platform — platform expert and ACPI/设备树 integration.
/// Provides device tree traversal and platform-specific device registration.

const log = @import("../../lib/log.zig");
const registry = @import("registry.zig");

pub const MAX_PLATFORMS: usize = 16;

pub const PlatformType = enum(u32) {
    generic = 0,
    acpi = 1,
    device_tree = 2,
};

pub const PlatformExpert = struct {
    id: u32,
    platform_type: PlatformType,
    root_node: ?*registry.IORegNode,
    active: bool,

    pub fn getRoot(self: *const PlatformExpert) ?*registry.IORegNode {
        return self.root_node;
    }
};

var platforms: [MAX_PLATFORMS]PlatformExpert = undefined;
var platform_count: usize = 0;

pub fn init() void {
    platform_count = 0;
    for (&platforms) |*p| p.active = false;
    log.info("IOKit Platform subsystem initialized", .{});
}

pub fn createPlatform(pType: PlatformType) ?u32 {
    if (platform_count >= MAX_PLATFORMS) return null;

    const id = @as(u32, @intCast(platform_count));
    platforms[platform_count] = .{
        .id = id,
        .platform_type = pType,
        .root_node = null,
        .active = true,
    };
    platform_count += 1;
    return id;
}

pub fn lookupPlatform(id: u32) ?*PlatformExpert {
    if (id >= MAX_PLATFORMS) return null;
    if (!platforms[id].active) return null;
    return &platforms[id];
}

pub fn createACPIPlatform() ?u32 {
    const id = createPlatform(.acpi) orelse return null;

    const root = registry.allocNode("IOPlatformExpertDevice", "ACPI") orelse return null;
    _ = root.setProperty("IOClass", "IOPlatformExpertDevice");
    _ = root.setProperty("IOProviderClass", "IOResources");

    var platform = lookupPlatform(id).?;
    platform.root_node = root;

    if (registry.getRoot()) |reg_root| {
        reg_root.addChild(root);
    }

    log.debug("ACPI Platform Expert created", .{});
    return id;
}

pub fn createDeviceTreePlatform() ?u32 {
    const id = createPlatform(.device_tree) orelse return null;

    const root = registry.allocNode("IOPlatformExpertDevice", "DeviceTree") orelse return null;
    _ = root.setProperty("IOClass", "IOPlatformExpertDevice");

    var platform = lookupPlatform(id).?;
    platform.root_node = root;

    if (registry.getRoot()) |reg_root| {
        reg_root.addChild(root);
    }

    log.debug("Device Tree Platform Expert created", .{});
    return id;
}

pub fn getOrCreatePlatform() u32 {
    if (platform_count > 0) {
        return 0;
    }
    return createACPIPlatform() orelse 0;
}

pub fn addACPIChildDevice(parent_id: u32, name: []const u8) ?*registry.IORegNode {
    const platform = lookupPlatform(parent_id) orelse return null;
    const parent = platform.root_node orelse return null;

    const child = registry.allocNode(name, name) orelse return null;
    parent.addChild(child);

    log.debug("ACPI child device added: '{s}'", .{name});
    return child;
}
